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
          Loop = Data.define(:session, :round_trips, :speakers, :recorded, :warnings) do
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
                new(session: reader.session, round_trips: trips, speakers: speakers,
                    recorded: trips.any? && trips.all?(&:recorded),
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

            end
          end
  end
end
