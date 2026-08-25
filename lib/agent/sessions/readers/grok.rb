# frozen_string_literal: true

module Agent
  module Sessions
        module Readers
          # Grok Build sessions. PROVISIONAL, like the adapter: written against
          # tokentelemetry's parser of this format, not against real Grok output.
          #
          # Two things make this reader unlike every other one here. The session it
          # is handed points at summary.json, while the conversation is in
          # chat_history.jsonl beside it — so the streaming base reads a SIBLING
          # file. And billed usage is not in the session directory at all: it lives
          # in ~/.grok/logs/unified.jsonl, one row per request across every session,
          # keyed by session id. A rotated log means no usage, which is why `usage`
          # answers nil rather than zero when the log is gone.
          class Grok < Base
            TRANSCRIPT = "chat_history.jsonl"
            UNIFIED_LOG = "unified.jsonl"

            # The row that records one completed request, per the reference parser.
            INFERENCE = "shell.turn.inference_done"

            ROLES = { "user" => :user, "assistant" => :assistant, "system" => :system,
                      "tool" => :tool }.freeze

            # The session's summary.json, exposed because it holds what Layer 2 does
            # not surface: generated_title, session_summary, current_model_id, the
            # git branch and commit the work happened on.
            def summary
              @summary ||= begin
                parsed = JSON.parse(File.read(session.path))
                parsed.is_a?(Hash) ? parsed : {}
              rescue SystemCallError, JSON::ParserError
                warn_about("#{session.path} could not be read")
                {}
              end
            end

            # Summed across this session's rows in the shared inference log.
            #
            # prompt_tokens INCLUDES cached_prompt_tokens (the reference parser
            # subtracts one from the other, as this gem does for Codex and Gemini),
            # so `input` is the difference and `cache_read` the cached share. The
            # cached count is clamped to the prompt first: a log row claiming more
            # cached than prompt would otherwise produce a negative input.
            def usage
              rows = 0
              input = output = cached = reasoning = 0
              each_log_row do |record|
                ctx = record["ctx"]
                next unless ctx.is_a?(Hash)

                prompt = count_from(ctx["prompt_tokens"]).to_i
                hit = [count_from(ctx["cached_prompt_tokens"]).to_i, prompt].min
                rows += 1
                input += prompt - hit
                cached += hit
                output += count_from(ctx["completion_tokens"]).to_i
                reasoning += count_from(ctx["reasoning_tokens"]).to_i
              end
              return nil if rows.zero?

              Usage.new(input: input, output: output, cache_read: cached, reasoning: reasoning)
            end

            private

            # The conversation, beside the summary Layer 2 pointed at. This is the
            # hook Readers::Base provides for exactly this case, so all of its
            # streaming and reporting still applies.
            def record_path = File.join(File.dirname(session.path), TRANSCRIPT)

            # <base>/sessions/<project>/<id>/summary.json → <base>/logs/unified.jsonl.
            # Four levels up rather than a stored root, because a Session carries a
            # path and nothing else about where its store began.
            def unified_log_path
              base = File.dirname(File.dirname(File.dirname(File.dirname(session.path))))
              File.join(base, "logs", UNIFIED_LOG)
            end

            # Streams the shared log, keeping only this session's completed
            # requests. The whole file is walked because rows for many sessions are
            # interleaved; the cheap string check comes before the JSON parse, since
            # most rows belong to other sessions or other event types.
            def each_log_row
              path = unified_log_path
              return unless File.exist?(path)

              File.foreach(path, "\n", MAX_RECORD_BYTES) do |chunk|
                next unless chunk.include?(INFERENCE) && chunk.include?(session.id)

                record = begin
                  JSON.parse(chunk)
                rescue JSON::ParserError, EncodingError
                  next
                end
                next unless record.is_a?(Hash) && record["msg"] == INFERENCE && record["sid"] == session.id

                yield record
              end
            rescue SystemCallError
              warn_about("#{path} could not be read; token usage is unavailable for this session")
            end

            def message_for(record, line_number)
              role = ROLES[record["role"]]
              unless role
                warn_about("line #{line_number}: unrecognized role #{record["role"].inspect}")
                return Message.new(role: :unknown, at: time_from(record["timestamp"]),
                                   parts: [Part.new(type: :unknown)], raw: record)
              end

              Message.new(role: role, at: time_from(record["timestamp"]), parts: content_parts(record),
                          raw: record, usage: nil, model: model_for(record))
            end

            # content is a String, or an array of typed blocks of which only text is
            # mapped by the reference parser — anything else stays in raw rather
            # than being guessed at.
            def content_parts(record)
              content = record["content"]
              return [Part.new(type: :text, text: content)] if content.is_a?(String)

              Array(content).filter_map do |block|
                next unless block.is_a?(Hash)

                case block["type"]
                when "text" then Part.new(type: :text, text: block["text"].to_s)
                when "tool_use", "tool_call"
                  Part.new(type: :tool_use, name: block["name"], call_id: block["id"],
                           text: stringify(block["input"] || block["arguments"]))
                when "tool_result"
                  Part.new(type: :tool_result, call_id: block["tool_use_id"] || block["id"],
                           text: stringify(block["content"] || block["output"]))
                when "thinking", "reasoning"
                  Part.new(type: :thinking, text: (block["thinking"] || block["text"]).to_s)
                end
              end
            end

            # Per-message model where one is recorded, falling back to the session's
            # current model from summary.json — which is what it says it is, the
            # model in force now, so it is a fallback and never an override.
            def model_for(record)
              model = record["model"] || summary["current_model_id"]
              model.is_a?(String) ? model : nil
            end

            def stringify(value)
              value.is_a?(String) || value.nil? ? value.to_s : JSON.generate(value)
            end
          end
        end
  end
end
