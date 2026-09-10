# frozen_string_literal: true

module Agent
  module Sessions
          # Renders one Loop for a human (#ascii, #markdown) or a machine (#to_h).
          #
          # Every rendering prints SIZES, never BODIES. A transcript can hold a
          # credential or a customer's data anywhere — even a shell command line
          # can carry a token — and this gem has no redaction before milestone
          # 0.5, so a truncated preview is not a safer middle ground; it is the
          # same leak with extra steps. A byte count and a tool name carry
          # enough signal to see what a loop did without carrying what it said.
          #
          # Every timestamp goes through #utc: two renderings of the same file
          # must be byte-identical no matter which machine or time zone reads
          # it, and a local time would make that false for a fact (the
          # recorded instant) that has not actually changed.
          #
          # The ending is always printed as inferred, because Loop#ending is
          # always a deduction — no on-disk transcript records WHY a session
          # stopped, since that fact lives in a non-interactive run's streamed
          # output, never in the file itself. Printing it as a plain fact would
          # claim information the file does not hold.
          class LoopView
            YOU_LANE = 2
            HARNESS_LANE = 15
            MODEL_LANE = 50

            # A label is a record TYPE name (hook_success, turn_duration), never
            # prose — but the field carrying it is a free String, so this shape
            # check is what actually keeps R9 (no bodies) true the day a format
            # starts putting a sentence there instead of a type name.
            LABEL_SHAPE = /\A[A-Za-z0-9_.:-]{1,64}\z/

            def initialize(loop_model)
              @loop = loop_model
            end

            def ascii
              lines = [
                "session #{@loop.session.uid}",
                "round trips: #{@loop.round_trips.size}  (grouping: #{grouping})",
                "tool calls: #{@loop.tool_calls.size}  (#{unanswered_count} unanswered)",
                "",
                ascii_header
              ]
              @loop.round_trips.each { |trip| lines.concat(ascii_round_trip(trip)) }
              lines << "" << "ending: #{@loop.ending} (inferred) — #{@loop.ending_detail}"
              if @loop.warnings.any?
                lines << "" << "warnings:"
                @loop.warnings.each { |warning| lines << "  - #{warning}" }
              end
              "#{lines.join("\n")}\n"
            end

            def markdown
              lines = ["# session #{@loop.session.uid}", "",
                       "- round trips: #{@loop.round_trips.size} (grouping: #{grouping})",
                       "- tool calls: #{@loop.tool_calls.size} (#{unanswered_count} unanswered)",
                       "", "## Round trips", ""]
              @loop.round_trips.each { |trip| lines << markdown_round_trip(trip) }
              lines << "" << "## Tool calls" << ""
              lines.concat(markdown_tool_calls_table)
              lines << "" << "## Ending" << "" << "#{@loop.ending} (inferred) — #{@loop.ending_detail}"
              if @loop.warnings.any?
                lines << "" << "## Warnings" << ""
                @loop.warnings.each { |warning| lines << "- #{warning}" }
              end
              "#{lines.join("\n")}\n"
            end

            def to_h
              {
                session: { agent: @loop.session.agent, id: @loop.session.id, uid: @loop.session.uid },
                round_trips: @loop.round_trips.map { |trip| round_trip_h(trip) },
                tool_calls: @loop.tool_calls.map { |call| tool_call_h(call) },
                ending: { name: @loop.ending, detail: @loop.ending_detail, inferred: true },
                recorded: @loop.recorded,
                warnings: @loop.warnings
              }
            end

            private

            def lane(text, column) = (" " * column) + text

            # The only "size" a body may leak as: a count, never the bytes themselves.
            def size_of(part) = part.text.to_s.bytesize

            # UTC, never local: local time would make one recorded instant print
            # two different strings depending on which machine reads the file,
            # which breaks the determinism R8 requires.
            def utc(time) = time&.utc&.iso8601

            # Counts, never a bare "recorded"/"assumed". Loop#recorded is
            # round_trips.all?(&:recorded), so ONE assumed group collapses the
            # whole answer to false — and on Claude, the one format that does
            # name its groups, every user and harness turn carries no message.id
            # and is assumed by construction. A real session therefore reports
            # false while 54 of its 109 groups were in fact named by the store,
            # and printing that as the single word "assumed" tells the reader
            # this format records nothing. That is the confusion the gem's
            # standing rule forbids: "the store does not record this" must never
            # read the same as "the store recorded none here", in either
            # direction. So say how many, and let the two cases differ visibly.
            def grouping
              named = @loop.round_trips.count(&:recorded)
              return "no round trips" if @loop.round_trips.empty?
              return "all #{named} named by the store" if named == @loop.round_trips.size
              return "none named by the store; one round trip per message" if named.zero?

              "#{named} of #{@loop.round_trips.size} named by the store"
            end

            def unanswered_count = @loop.tool_calls.count { |call| !call.answered? }

            def ascii_header
              line = lane("YOU", YOU_LANE).ljust(HARNESS_LANE) + "HARNESS"
              line.ljust(MODEL_LANE) + "MODEL"
            end

            def ascii_round_trip(trip)
              case @loop.speakers[trip.index]
              when :person  then [ascii_person(trip)]
              when :model   then ascii_model(trip)
              when :harness then ascii_harness(trip)
              when :event   then [lane("#{trip.index} [event] #{event_labels(trip)}", HARNESS_LANE)]
              else               [lane("#{trip.index} [unrecognized record]", HARNESS_LANE)]
              end
            end

            def ascii_person(trip)
              bytes = trip.parts.sum { |part| size_of(part) }
              lane("#{trip.index} prompt  #{bytes} B", YOU_LANE)
            end

            def ascii_model(trip)
              lines = [lane("#{trip.index} == round trip ==>", HARNESS_LANE)]
              trip.parts.each { |part| lines << lane(part_line(part), MODEL_LANE) }
              lines << lane(usage_line(trip.usage), MODEL_LANE) if trip.usage
              verdict = trip.calls.any? ? "tool_use: keep looping" : "no tool_use: exit"
              lines << lane("#{trip.index} <== #{verdict}", HARNESS_LANE)
            end

            def ascii_harness(trip)
              trip.parts.select { |part| part.type == :tool_result }.map do |part|
                lane("#{trip.index} <- tool_result  #{tool_name_for(part.call_id)}  #{size_of(part)} B  " \
                     "(#{part.call_id || "no call id"})", HARNESS_LANE)
              end
            end

            # T4: how ONE content part is shown, inside any round trip that
            # prints its parts one by one. tool_use gets its name plus the size
            # of what it asked for; text/thinking/tool_result get a bare size;
            # image/unknown get only their type name, because the gem never
            # loads those payloads and so has no size worth calling meaningful.
            def part_line(part)
              case part.type
              when :tool_use    then "tool_use  #{part.name}  #{size_of(part)} B"
              when :tool_result then "tool_result  #{size_of(part)} B"
              when :text        then "text  #{size_of(part)} B"
              when :thinking    then "thinking  #{size_of(part)} B"
              else part.type.to_s
              end
            end

            def usage_line(usage) = "usage #{usage_fields(usage).join(" ")}"

            def usage_fields(usage)
              { "in" => usage.input, "out" => usage.output, "cache_read" => usage.cache_read,
                "cache_creation" => usage.cache_creation, "reasoning" => usage.reasoning }
                .reject { |_, value| value.nil? }
                .map { |key, value| "#{key}=#{value}" }
            end

            # `?` here means exactly what it means everywhere else in this gem:
            # the fact is not knowable from what was recorded, never zero.
            def tool_name_for(call_id)
              return "?" if call_id.nil?

              @loop.tool_calls.find { |call| call.call_id == call_id }&.name || "?"
            end

            # R11: a part's text prints as a label only when it is label-shaped
            # (a record TYPE name); anything else — including a stray sentence a
            # future format might put in this free-String field — prints the
            # part's own type name instead, so R9 (no bodies) cannot be broken
            # by a format that starts putting prose where a type name belongs.
            def event_labels(trip)
              trip.parts.map { |part| label_shaped?(part.text) ? part.text : part.type.to_s }.join(", ")
            end

            def label_shaped?(text) = text.is_a?(String) && LABEL_SHAPE.match?(text)

            def markdown_round_trip(trip)
              speaker = @loop.speakers[trip.index]
              parts = speaker == :event ? event_labels(trip) : markdown_parts(trip)
              entry = "#{trip.index}. **#{speaker}** — #{parts}"
              at = utc(trip.at)
              entry += " — at #{at}" if at
              entry += " — #{usage_line(trip.usage)}" if trip.usage
              entry
            end

            def markdown_parts(trip)
              return "(no parts)" if trip.parts.empty?

              trip.parts.map { |part| part_line(part) }.join("; ")
            end

            def markdown_tool_calls_table
              [
                "| tool | call id | input | result | asked in | answered in |",
                "|---|---|---|---|---|---|",
                *@loop.tool_calls.map { |call| markdown_tool_call_row(call) }
              ]
            end

            def markdown_tool_call_row(call)
              # An unanswered call must read as "no answer recorded", never
              # "0 B" — the same distinction ToolCall#result_bytes itself draws,
              # repeated here because nil-to-string interpolation would
              # otherwise silently print an empty cell instead of saying so.
              result = call.answered? ? "#{call.result_bytes} B" : "no answer recorded"
              "| #{call.name} | #{call.call_id || "no call id"} | #{call.input_bytes} B | #{result} | " \
                "#{call.asked_in} | #{call.answered_in || "-"} |"
            end

            def round_trip_h(trip)
              { index: trip.index, speaker: @loop.speakers[trip.index], recorded: trip.recorded,
                roles: trip.roles, at: utc(trip.at), model: trip.model, usage: trip.usage&.to_h,
                parts: trip.parts.map { |part| part_h(part) } }
            end

            # name is populated for :tool_use alone (the tool's own name); every
            # other type — including :image/:unknown — carries nil, since a
            # size is not a body but any other free-text field on the part
            # would be.
            def part_h(part) = { type: part.type, name: part.type == :tool_use ? part.name : nil, bytes: size_of(part) }

            def tool_call_h(call)
              { name: call.name, call_id: call.call_id, input_bytes: call.input_bytes,
                result_bytes: call.result_bytes, asked_in: call.asked_in, answered_in: call.answered_in,
                answered: call.answered? }
            end
          end
  end
end
