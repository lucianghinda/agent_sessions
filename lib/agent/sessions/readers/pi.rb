# frozen_string_literal: true

module Agent
  module Sessions
        module Readers
          # pi session files. PROVISIONAL in a way no other reader is: this machine
          # holds nine real pi project directories and zero session files inside
          # them (2026-08-24), so every mapping below is written against
          # tokentelemetry's working parser of the same format
          # (resources/tokentelemetry, backend/main.py, _scan_pi_sessions) rather
          # than a corpus of pi's own output. That is observation of running code,
          # not of data — one step better than the design doc's prose, one step
          # short of every other reader's evidence. Where the two could disagree,
          # rule 2 already decides the outcome: a shape this reader has not seen
          # becomes an :unknown part and a warning, never an exception, and raw
          # carries what really happened.
          #
          # The format per that parser: a header record {"type":"session", id, cwd,
          # timestamp}, then typed records — "model_change" (provider, modelId) and
          # "message" ({role, model, content[], usage}). usage spells its keys
          # camelCase (cacheRead, cacheWrite) and carries agent-computed cost.
          class Pi < Base
            # The header and settings records are session state, not conversation —
            # the same judgement Codex's session_meta gets. model_change is state
            # too: the model a LATER message used is on that message.
            NON_MESSAGE_TYPES = %w[session model_change].freeze

            ROLES = { "user" => :user, "assistant" => :assistant }.freeze

            # Session totals, summed per message record. No dedup: nothing observed
            # or reported suggests pi repeats one response across records the way
            # Claude does — but nothing proves it either, so if pi totals ever read
            # roughly double a provider's bill, this is where to look.
            def usage
              total = nil
              each_record do |record, _line_number|
                usage = usage_from(record)
                next unless usage

                total = total ? total + usage : usage
              end
              total
            end

            private

            def message_for(record, line_number)
              type = record["type"]
              return nil if NON_MESSAGE_TYPES.include?(type)

              unless type == "message" && record["message"].is_a?(Hash)
                warn_about("line #{line_number}: unrecognized record type #{type.inspect}")
                return Message.new(role: :unknown, at: time_from(record["timestamp"]),
                                   parts: [Part.new(type: :unknown)], raw: record)
              end

              data = record["message"]
              Message.new(role: role_for(data["role"], line_number),
                          at: time_from(record["timestamp"]),
                          parts: content_parts(data, line_number), raw: record,
                          usage: usage_from(record), model: model_from(data))
            end

            def role_for(role, line_number)
              ROLES.fetch(role) do
                warn_about("line #{line_number}: unrecognized role #{role.inspect}")
                :unknown
              end
            end

            # content carries text and toolCall items per the reference parser. A
            # toolCall's inner keys are the least-verified mapping in this file —
            # name/id/arguments are the spellings pi's TypeScript types suggest, and
            # every one is fetched nil-safe so a different spelling degrades to an
            # emptier Part, never to a crash. raw holds the truth either way.
            def content_parts(data, line_number)
              Array(data["content"]).map do |item|
                next Part.new(type: :unknown) unless item.is_a?(Hash)

                case item["type"]
                when "text" then Part.new(type: :text, text: item["text"].to_s)
                when "thinking" then Part.new(type: :thinking, text: item["thinking"].to_s)
                when "toolCall"
                  Part.new(type: :tool_use, name: item["name"], call_id: item["id"],
                           text: stringify(item["arguments"] || item["input"]))
                when "toolResult"
                  Part.new(type: :tool_result, call_id: item["toolCallId"] || item["id"],
                           text: item["output"].is_a?(String) ? item["output"] : item["text"])
                else
                  warn_about("line #{line_number}: unrecognized content part #{item["type"].inspect}")
                  Part.new(type: :unknown, text: item["text"])
                end
              end
            end

            # usage keys observed by the reference parser: input, output, cacheRead,
            # cacheWrite, reasoning, totalTokens, cost. totalTokens is deliberately
            # unmapped — it restates the others, and any bucket it landed in would
            # double-count. Whether input already excludes cacheRead the way the
            # field names suggest (Anthropic-style disjoint spelling) is UNVERIFIED;
            # if pi turns out to count inclusively the way Codex does, the fix is a
            # subtraction here, not in any caller.
            def usage_from(record)
              usage = record.dig("message", "usage")
              return nil unless usage.is_a?(Hash)

              cost = usage["cost"]
              cost = cost["total"] if cost.is_a?(Hash)
              mapped = Usage.new(input: count_from(usage["input"]),
                                 output: count_from(usage["output"]),
                                 cache_read: count_from(usage["cacheRead"]),
                                 cache_creation: count_from(usage["cacheWrite"]),
                                 reasoning: count_from(usage["reasoning"]),
                                 cost: cost_from(cost))
              mapped.to_h.each_value.any? ? mapped : nil
            end

            def model_from(data)
              model = data["model"]
              model.is_a?(String) ? model : nil
            end

            def stringify(value)
              value.is_a?(String) || value.nil? ? value.to_s : JSON.generate(value)
            end
          end
        end
  end
end
