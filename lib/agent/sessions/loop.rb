# frozen_string_literal: true

module Agent
  module Sessions
          # One session read as an agent loop: round trips, the tool calls paired
          # across them, who spoke at each step, and how the loop ended.
          #
          # `recorded` is false for an empty session — nothing was recorded, and
          # "absence must never read as presence" is this gem's standing rule
          # (RoundTrip carries the same rule for one group).
          #
          # `warnings` is the reader's warnings first, then this object's own, so
          # the order is deterministic regardless of what the reader happened to
          # find.
          Loop = Data.define(:session, :round_trips, :tool_calls, :speakers, :ending, :recorded, :warnings) do
            # The exact sentence for each ending, so the Loop and whatever renders
            # it say the same words.
            ENDINGS = {
              answered: "the model answered without asking for a tool",
              stopped_in_the_loop: "a tool was asked for and nothing answered it",
              not_a_model_record: "the session stops on a record the model did not write",
              empty: "no round trips were recorded"
            }.freeze

            # Always true: no store on disk records WHY a session stopped — the
            # on-disk transcript holds no stop reason and no turn count, because
            # those live in the streamed output of a non-interactive run, not in
            # the session file. So the ending is always deduced, and must always
            # be labelled as such rather than presented as a recorded fact.
            def ending_inferred? = true

            def ending_detail = ENDINGS.fetch(ending)

            class << self
              # Reads the WHOLE session and says so by returning one built object
              # rather than streaming — it cannot stream, because a tool result
              # can arrive many records after the call it answers, and a
              # streaming pass cannot look forward to find it.
              # Readers::Base#tree carries the same shape of honesty for the same
              # reason.
              def for(reader)
                warnings = []
                trips = reader.round_trips
                speakers = {}
                trips.each { |trip| speakers[trip.index] = speaker_of(trip, warnings) }
                calls = pair(trips, warnings)
                new(session: reader.session, round_trips: trips, tool_calls: calls, speakers: speakers,
                    ending: ending_for(trips, speakers), recorded: trips.any? && trips.all?(&:recorded),
                    warnings: reader.warnings + warnings)
              end

              private

              # The speaker is read from the roles AND the parts together, never
              # the role alone — Claude files a tool result as a `user` message,
              # so a person's prompt and the harness answering a tool look
              # identical by role. A message carrying tool results is the
              # harness whatever role it carries.
              def speaker_of(round_trip, warnings)
                roles = round_trip.roles
                return :model   if roles.include?(:assistant)
                return :harness if roles.include?(:tool)
                return :event   if roles.include?(:system)
                return :unknown if roles.include?(:unknown)

                parts   = round_trip.parts
                results = parts.select { |part| part.type == :tool_result }
                return :person if results.empty?

                warnings << "round trip #{round_trip.index} mixes a tool result with other parts" if results.size < parts.size
                :harness
              end

              # Pairs each call with the result that answers it, by call id —
              # never by position, since two calls can be in flight at once and
              # position would match the wrong one.
              #
              # Gemini and opencode record a call and its result in ONE message,
              # so there answered_in == asked_in; the same call-id pairing covers
              # it without a special case.
              def pair(round_trips, warnings)
                results = {}
                round_trips.each do |trip|
                  trip.parts.each do |part|
                    next unless part.type == :tool_result && part.call_id # a nil call_id cannot be paired and must not collide with another nil

                    results[part.call_id] = [trip.index, part]
                  end
                end

                calls = round_trips.flat_map do |trip|
                  trip.calls.map do |part|
                    # results.delete returns nil when absent, and destructuring nil
                    # gives both index and answer as nil — that is intended, and is
                    # exactly an unanswered call.
                    pair = part.call_id ? results.delete(part.call_id) : nil
                    index, answer = pair
                    ToolCall.new(name: part.name.to_s, call_id: part.call_id,
                                 input_bytes: part.text.to_s.bytesize,
                                 result_bytes: answer && answer.text.to_s.bytesize,
                                 asked_in: trip.index, answered_in: index)
                  end
                end

                results.each_key { |id| warnings << "tool result #{id} answers no call" }
                calls
              end

              def ending_for(round_trips, speakers)
                return :empty if round_trips.empty?

                last = round_trips.last
                return :not_a_model_record unless speakers[last.index] == :model
                return :stopped_in_the_loop if last.calls.any?

                :answered
              end
            end
          end
  end
end
