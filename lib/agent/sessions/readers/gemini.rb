# frozen_string_literal: true

module Agent
  module Sessions
        module Readers
          # Gemini CLI chat files. Written against a real store on this machine
          # (2026-08-24): 12 sessions, 121 records — user 20, gemini 97, info 4.
          #
          # A chat is one JSON document, not JSONL, so it is read whole under a cap
          # the way Amp's thread is. The cap is the reason this does not simply
          # JSON.parse the file: the largest real chat here is 103 KB, but nothing
          # in the format bounds it, and an unbounded read is the failure the base
          # reader's chunked streaming exists to prevent.
          class Gemini < Base
            # Amp's bound, for the same reason: a whole document must fit in memory
            # to be parsed at all, so the only protection available is refusing to
            # read one that is absurdly large.
            MAX_DOCUMENT_BYTES = 32_000_000

            # "gemini" is the assistant. "info" is the CLI talking to the user
            # ("Update successful! The new version will be used on your next run."),
            # which is neither turn — context the operator saw, the same judgement
            # Claude's system records get, so it arrives with include_events.
            ROLES = { "user" => :user, "gemini" => :assistant }.freeze

            # The document's own header, exposed because Layer 2's session id is the
            # filename (the trailing hex in it is shared between sessions) while the
            # agent's own sessionId lives in here.
            def header
              document.reject { |key, _| key == "messages" }
            end

            # Session totals, summed per message — the counts are per API call, not
            # a running total (verified: the real series falls as well as rises,
            # 64138 then 8069 then 8265, which no cumulative counter does).
            def usage
              total = nil
              each_record do |record, _index|
                usage = usage_from(record)
                next unless usage

                total = total ? total + usage : usage
              end
              total
            end

            private

            # Overridden wholesale, like Amp's: the unit here is an element of the
            # document's messages array, not a line of the file.
            def each_record
              Array(document["messages"]).each_with_index do |record, index|
                next unless record.is_a?(Hash)

                yield record, index + 1
              end
            end

            def document
              @document ||= begin
                size = File.size(session.path)
                if size > MAX_DOCUMENT_BYTES
                  warn_about("#{session.path} is larger than #{MAX_DOCUMENT_BYTES} bytes; not read")
                  {}
                else
                  parsed = JSON.parse(File.read(session.path))
                  parsed.is_a?(Hash) ? parsed : warn_about("#{session.path} is not a JSON object") || {}
                end
              rescue SystemCallError
                warn_about("#{session.path} could not be read") || {}
              rescue JSON::ParserError
                warn_about("#{session.path} does not hold valid JSON") || {}
              end
            end

            def message_for(record, index)
              type = record["type"]
              return event_message(record) if type == "info"

              role = ROLES[type]
              unless role
                warn_about("message #{index}: unrecognized type #{type.inspect}")
                return build(record, :unknown, [Part.new(type: :unknown, text: record["content"])])
              end

              build(record, role, content_parts(record))
            end

            # content is a plain String; thoughts and toolCalls sit beside it rather
            # than inside a parts array, so the document's shape is flattened into
            # this gem's vocabulary here rather than mapped one-to-one.
            #
            # A thought is {subject, description}: the subject alone reads as a
            # heading with no body, so both are kept, joined — losing the
            # description would make :thinking parts look empty.
            def content_parts(record)
              parts = []
              Array(record["thoughts"]).each do |thought|
                next unless thought.is_a?(Hash)

                parts << Part.new(type: :thinking, text: [thought["subject"], thought["description"]]
                                  .compact.join(": "))
              end
              content = record["content"]
              parts << Part.new(type: :text, text: content.to_s) if content.is_a?(String) && !content.empty?
              parts.concat(tool_parts(record))
              parts
            end

            # One toolCalls entry holds both the call and its result — the same
            # shape opencode's `tool` part has — so it becomes two Parts. The result
            # appears only when the entry carries one: an entry still running
            # answered nothing, and an empty result would claim it did.
            def tool_parts(record)
              Array(record["toolCalls"]).flat_map do |call|
                next [] unless call.is_a?(Hash)

                parts = [Part.new(type: :tool_use, name: call["name"], call_id: call["id"],
                                  text: stringify(call["args"]))]
                parts << Part.new(type: :tool_result, call_id: call["id"],
                                  text: stringify(call["result"])) if call.key?("result")
                parts
              end
            end

            def event_message(record)
              return nil unless include_events

              build(record, :system, [Part.new(type: :text, text: record["content"].to_s)])
            end

            def build(record, role, parts)
              model = record["model"]
              Message.new(role: role, at: time_from(record["timestamp"]), parts: parts, raw: record,
                          usage: usage_from(record), model: model.is_a?(String) ? model : nil)
            end

            # tokens: {input, output, cached, thoughts, tool, total}.
            #
            # `cached` is INSIDE `input`, not beside it — verified arithmetically
            # across every one of the 97 real token records: total equals
            # input + output + thoughts + tool, with cached never added, so a cached
            # count is part of the input it accompanies. Subtracted here for the
            # same reason Codex's cached_input_tokens is, so Usage#input means one
            # thing across agents. Clamped at zero: a negative token count would
            # mean the two fields disagree, and a wrong zero beats a negative.
            #
            # `total` is deliberately unmapped (it restates the others), and so is
            # `tool` — this gem's Usage has no bucket for tokens spent inside a
            # tool, and folding them into output would misreport what the model
            # generated. Both stay reachable in raw.
            def usage_from(record)
              tokens = record["tokens"]
              return nil unless tokens.is_a?(Hash)

              input = count_from(tokens["input"])
              cached = count_from(tokens["cached"])
              mapped = Usage.new(input: input && cached ? [input - cached, 0].max : input,
                                 output: count_from(tokens["output"]),
                                 cache_read: cached,
                                 reasoning: count_from(tokens["thoughts"]))
              mapped.to_h.each_value.any? ? mapped : nil
            end

            def stringify(value)
              value.is_a?(String) || value.nil? ? value.to_s : JSON.generate(value)
            end
          end
        end
  end
end
