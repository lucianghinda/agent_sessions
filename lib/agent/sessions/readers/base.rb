# frozen_string_literal: true

module Agent
  module Sessions
        module Readers
          # Layer 3: turning one session file into messages. Subclasses supply the
          # mapping; everything about *how the file is read* lives here, because the
          # three rules that make this layer survivable (design doc §5) are properties
          # of the reading, not of any one agent's format:
          #
          #   1. raw is never dropped.
          #   2. Unknown records become :unknown parts and warnings, never exceptions.
          #   3. Reading streams. No code path may assume a file fits in memory.
          #
          # Rule 3 is why this does not use File.foreach without a chunk size. A
          # truncated log can hold no newline at all, and "read one line" would then
          # mean "read 2.6 GB into a String" — the file the article that started this
          # gem found on a real machine.
          class Base
            # Chunk size, and so the largest record that can be read whole. Measured
            # against 415 real Codex rollout files (128,987 records, 2026-08-12): 14
            # records exceed 1 MB and the largest is 2.41 MB, so Layer 2's
            # MAX_LINE_BYTES of 1 MB would silently drop real messages. 8 MB is ~3.3x
            # the observed maximum. A record beyond it is reported, never dropped in
            # silence, because a missing message is this gem's worst failure mode.
            MAX_RECORD_BYTES = 8_000_000

            attr_reader :session

            def initialize(session, include_events: false)
              @session = session
              @include_events = include_events
              @warnings = []
            end

            def fidelity = session.fidelity

            # True where the local file is not the whole story — Amp, whose server
            # holds the canonical copy. Overridden there, false everywhere else.
            def partial? = false

            # Populated as records are read, so this answers for whatever has been
            # consumed so far. uniq because a second pass over the same file would
            # otherwise repeat every warning it already reported.
            def warnings = @warnings.uniq

            # Streams. Yields each message as it is parsed; a caller that breaks after
            # one has read one record, not the file.
            def each_message
              return enum_for(:each_message) unless block_given?

              each_record do |record, line_number|
                message = message_for(record, line_number)
                yield message if message
              end
            end

            # Eager, for sessions small enough to hold. The design doc offers both and
            # names this the convenience: `messages` is what a script wants, and
            # `each_message` is what a 2.6 GB file requires.
            def messages = each_message.to_a

            # Streams, exactly as each_message does. A group is a RUN of
            # neighbouring records sharing one round-trip id, not every record
            # sharing that id wherever it sits in the file — collecting scattered
            # records cannot stream, and rule 3 says no code path here may assume
            # a file fits in memory.
            #
            # So an id that reappears after its run closed opens a NEW round trip
            # rather than reopening the old one. That is ORDINARY for Claude, not
            # an anomaly: Claude Code writes each tool_result immediately after
            # the tool_use it answers, while every content block of the one API
            # response keeps the same message.id, so a response making two tool
            # calls has its records split by the result in between. Measured over
            # the 60 most recent real Claude transcripts on this machine
            # (2026-09-10): 3,315 distinct message.ids, 261 of them (7.9%) split
            # across more than one run, in 33 of the 60 files; 759 of the splits
            # are a tool_result record, 66 a last-prompt, 12 a file-history-delta.
            #
            # Hence the warning fires only where NOTHING answered a tool between
            # the two runs — the case that is genuinely unexplained and would mean
            # the format drifted. Warning on the benign split would put four or
            # five lines under every real session's loop view, which teaches a
            # caller that these warnings are noise.
            def each_round_trip
              return enum_for(:each_round_trip) unless block_given?

              open_messages = []
              open_id       = nil
              closed_ids    = {}
              answers_seen  = 0
              index         = 0

              each_message do |message|
                id = round_trip_id_for(message.raw)

                if id && id == open_id
                  open_messages << message
                  answers_seen += 1 if answers_a_tool?(message)
                  next
                end

                if open_messages.any?
                  index += 1
                  yield build_round_trip(index, open_messages, open_id)
                end
                # What this id's run closed at, counted in tool answers seen so
                # far. Comparing that count against the count now is what
                # separates "a tool result split one response" from "this id came
                # back for a reason nothing here explains".
                closed_ids[open_id] = answers_seen if open_id

                if id && closed_ids[id] == answers_seen
                  warn_about("round-trip id #{id} reappears after its run closed with no tool answered " \
                             "in between; grouped as a new round trip")
                end

                open_messages = [message]
                open_id       = id
                answers_seen += 1 if answers_a_tool?(message)
              end

              yield build_round_trip(index + 1, open_messages, open_id) if open_messages.any?
            end

            def round_trips = each_round_trip.to_a

            # False here: most stores are an append-only list of records and no
            # format names which of them belong to one model response.
            def round_trips_recorded? = false

            # Whether this agent records which turn each turn followed. False here:
            # most stores are an append-only list and a tree would have to be invented.
            def branching? = false

            # The conversation as roots and their continuations, for an agent that
            # records parent links. Unlike every other method here this cannot stream
            # — a tree is not knowable until the last record is read — so it holds one
            # session's messages at once and says so rather than pretending otherwise.
            #
            # Raises rather than returning an empty list or nil for a store with no
            # parent links, for the reason Agent::Sessions.read raises: "this format
            # does not record that" must never read as "this session has none".
            def tree
              unless branching?
                raise UnsupportedFormat,
                      "#{session.agent} does not record parent links; its messages are a flat list"
              end

              build_tree
            end

            # This session's token totals as a Usage, or nil where the format does
            # not record them (Amp) or this reader has not learned where they live.
            # nil, not an empty Usage: "this store does not say" must never read as
            # "this session cost nothing" — the same rule tree() enforces by raising.
            #
            # Each reader that overrides this also decides its own summation rule,
            # because that rule is format knowledge: Claude repeats one API
            # response's usage across several records (94 of 124 message ids in one
            # real transcript), Codex writes a running total where only the last
            # record counts. A base-class sum would get both wrong.
            def usage = nil

            # Boundaries where the agent replaced earlier turns with a summary. Its
            # own pass: a caller asking only for compactions should not have to
            # materialize every message to get them.
            def compactions
              found = []
              each_record { |record, _line| (boundary = compaction_for(record)) && found << boundary }
              found
            end

            private

            attr_reader :include_events

            # nil means "this record is not a message" — a header, a turn context, a
            # compaction boundary. Subclasses override.
            def message_for(_record, _line_number) = nil

            # This record's own id and the id of the record it followed. nil from
            # either means the record takes no part in the tree. A branching reader
            # overrides both; the tree algorithm itself stays here, so an agent only
            # has to say where its links live, never how to assemble them.
            def node_id_for(_record) = nil
            def parent_id_for(_record) = nil

            # nil means "this format records no round-trip id". Same shape of
            # hook as node_id_for/parent_id_for: an agent says WHERE its id
            # lives, never how the grouping is assembled.
            def round_trip_id_for(_record) = nil

            # Whether this message is a tool answering a call. Used only to tell a
            # benign split of one response's records from an unexplained one.
            def answers_a_tool?(message) = message.parts.any? { |part| part.type == :tool_result }

            def build_round_trip(index, messages, id)
              RoundTrip.new(index: index, messages: messages, usage: usage_for(messages), recorded: !id.nil?)
            end

            # NEVER a sum. Claude repeats one API response's usage byte-for-byte
            # on each record of that response (94 of 124 message ids in one real
            # transcript), so summing the group would report roughly double what
            # the vendor billed.
            def usage_for(messages)
              found = messages.filter_map(&:usage)
              return nil if found.empty?
              return found.first if found.uniq.size == 1

              warn_about("round trip records disagree on usage; reporting the first")
              found.first
            end

            # Two passes over one session. The first records every uuid-bearing
            # record's parent and which of them became messages; the second links
            # each message to the nearest ANCESTOR that is also a message.
            #
            # That second part is the whole difficulty. Records that are not turns sit
            # in the same parent chain — 5,006 of 25,633 in the real Claude corpus are
            # attachments and system records — so a message's recorded parent is
            # frequently not a message. Walking up until one is found keeps the tree
            # holding exactly the messages `messages` reports, no more and no fewer,
            # and makes include_events change what is in the tree without changing
            # whether it is well formed.
            def build_tree
              order = []
              parents = {}
              messages = {}

              each_record do |record, line_number|
                id = node_id_for(record)
                next unless id

                order << id
                parents[id] = parent_id_for(record)
                message = message_for(record, line_number)
                messages[id] = message if message
              end

              link_tree(order, parents, messages)
            end

            def link_tree(order, parents, messages)
              children = Hash.new { |hash, key| hash[key] = [] }
              roots = []

              order.each do |id|
                next unless messages.key?(id)

                ancestor = nearest_message_ancestor(parents, messages, id)
                ancestor ? children[ancestor] << id : roots << id
              end

              # Built in reverse file order so a parent is always assembled after the
              # children it needs, without recursion — a linear session of several
              # thousand turns would otherwise be several thousand stack frames deep.
              built = {}
              order.reverse_each do |id|
                next unless messages.key?(id)

                built[id] = Node.new(message: messages[id], children: children[id].map { |child| built[child] }.compact)
              end

              roots.map { |id| built[id] }.compact
            end

            # Walks up the recorded chain until it reaches a record that became a
            # message, or runs out. A cycle would spin here, so ids already visited
            # end the walk: nothing in the real corpus contains one, and a malformed
            # file must not hang a reader.
            def nearest_message_ancestor(parents, messages, id)
              seen = { id => true }
              current = parents[id]
              while current && !messages.key?(current)
                break if seen[current]

                seen[current] = true
                current = parents[current]
              end
              current && messages.key?(current) ? current : nil
            end

            # nil means "not a compaction". Subclasses that have them override.
            def compaction_for(_record) = nil

            def warn_about(message)
              @warnings << message
              nil
            end

            # Yields one parsed record per complete line, with its 1-based line
            # number. Three things can go wrong and none of them may raise:
            #
            #   the file is unreadable      -> one warning, no records
            #   a line is not JSON          -> one warning naming the line, skipped
            #   a record exceeds the cap    -> one warning naming the line, skipped
            #
            # The oversized case is detected structurally rather than by measuring:
            # File.foreach with a chunk size hands back a chunk that does NOT end in a
            # newline when the record is longer than the cap, and the following chunks
            # are its continuation. A chunk shorter than the cap without a newline is
            # simply the last line of a file that does not end in one.
            # The file this reader streams. session.path for every agent that keeps
            # its conversation in the file Layer 2 enumerated — which is all of them
            # but Grok, whose session is a DIRECTORY: Layer 2 points at its
            # summary.json while the turns are in chat_history.jsonl beside it.
            # A hook here rather than an each_record override there, because the
            # rest of the streaming (the chunk cap, the oversized report, the
            # per-line warnings) is exactly what such a reader still wants.
            def record_path = session.path

            def each_record
              line_number = 0
              oversized_at = nil

              File.foreach(record_path, "\n", MAX_RECORD_BYTES) do |chunk|
                complete = chunk.end_with?("\n") || chunk.bytesize < MAX_RECORD_BYTES

                unless complete
                  oversized_at ||= line_number + 1
                  next
                end

                if oversized_at
                  warn_about("record at line #{oversized_at} is too large to read " \
                             "(over #{MAX_RECORD_BYTES} bytes); skipped")
                  oversized_at = nil
                  line_number += 1
                  next
                end

                line_number += 1
                record = parse(chunk, line_number)
                yield record, line_number if record
              end

              warn_about("record at line #{oversized_at} is too large to read " \
                         "(over #{MAX_RECORD_BYTES} bytes); skipped") if oversized_at
            rescue SystemCallError => e
              warn_about("#{record_path} could not be read (#{e.class.name.split("::").last})")
            end

            def parse(chunk, line_number)
              record = JSON.parse(chunk)
              return record if record.is_a?(Hash)

              warn_about("line #{line_number} is not a JSON object; skipped")
            rescue JSON::ParserError, EncodingError
              warn_about("line #{line_number} is not valid JSON; skipped")
            end

            # A token count is a whole number or absent. The type check is rule 2's
            # container check applied to numbers: a format that writes "1234" as a
            # String, or null, or a float where a count belongs, yields nil here
            # rather than a value that would poison a sum three callers later.
            def count_from(value) = value.is_a?(Integer) ? value : nil

            # Cost arrives as a Float (or an Integer zero) where an agent reports
            # it at all. Same guard, wider type: a cost is money, not a count, and
            # 0 is a real answer — a subscription session genuinely costs $0
            # marginal — so only a non-number is absent.
            def cost_from(value) = value.is_a?(Numeric) ? value : nil

            # Agents write ISO 8601 with a Z suffix. nil beats a wrong guess: a
            # timestamp that cannot be parsed is missing, not epoch zero.
            def time_from(value)
              return nil unless value.is_a?(String)

              Time.iso8601(value)
            rescue ArgumentError
              nil
            end
          end
        end
  end
end
