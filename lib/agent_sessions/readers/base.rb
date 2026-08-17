# frozen_string_literal: true

module AgentSessions
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

      # Whether this agent records which turn each turn followed. False here:
      # most stores are an append-only list and a tree would have to be invented.
      def branching? = false

      # The conversation as roots and their continuations, for an agent that
      # records parent links. Unlike every other method here this cannot stream
      # — a tree is not knowable until the last record is read — so it holds one
      # session's messages at once and says so rather than pretending otherwise.
      #
      # Raises rather than returning an empty list or nil for a store with no
      # parent links, for the reason AgentSessions.read raises: "this format
      # does not record that" must never read as "this session has none".
      def tree
        unless branching?
          raise UnsupportedFormat,
                "#{session.agent} does not record parent links; its messages are a flat list"
        end

        build_tree
      end

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
      def each_record
        line_number = 0
        oversized_at = nil

        File.foreach(session.path, "\n", MAX_RECORD_BYTES) do |chunk|
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
        warn_about("#{session.path} could not be read (#{e.class.name.split("::").last})")
      end

      def parse(chunk, line_number)
        record = JSON.parse(chunk)
        return record if record.is_a?(Hash)

        warn_about("line #{line_number} is not a JSON object; skipped")
      rescue JSON::ParserError, EncodingError
        warn_about("line #{line_number} is not valid JSON; skipped")
      end

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
