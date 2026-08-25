# frozen_string_literal: true

module Agent
  module Sessions
        module Readers
          # Amp threads. Written against the one real thread available (2026-08-14):
          # 24 messages, content parts tool_use 14, tool_result 14, text 2, thinking 1.
          # One thread is thin evidence beside Codex's 415 files, and this reader says
          # so through partial? rather than pretending otherwise.
          #
          # Two things make Amp unlike the JSONL readers:
          #
          # A thread is ONE JSON document, so it cannot be streamed a record at a
          # time. Reading any of it means holding all of it, which is the gem's one
          # unbounded read (0.2 follow-up 8). each_record below is where that bound
          # finally lives.
          #
          # And its tool results are spelled its own way — toolUseID rather than
          # tool_use_id, the payload under run.result rather than content. A mapper
          # copied from Claude's would produce empty tool results and no warning,
          # which is why each reader maps its own agent rather than sharing one.
          class Amp < Base
            # 150x the observed thread. A cap has to exist because nothing about a
            # thread file announces its size before it is opened, and JSON.parse of a
            # 200 MB document costs several times that in live objects. Refused and
            # reported beats NoMemoryError, and beats silence either way.
            MAX_DOCUMENT_BYTES = 32_000_000

            CONTENT_PARTS = { "text" => :text, "thinking" => :thinking,
                              "tool_use" => :tool_use, "tool_result" => :tool_result,
                              "image" => :image }.freeze

            ROLES = { "user" => :user, "assistant" => :assistant,
                      "system" => :system, "tool" => :tool }.freeze

            # The server holds the canonical copy; a local thread may be a mirror of
            # part of the conversation. The adapter carries the same warning.
            def partial? = true

            private

            # Overrides the line-oriented reader wholesale: there are no lines here.
            # Yields each message of the document with its index, so everything above
            # this method works unchanged.
            def each_record
              size = File.size(session.path)
              if size > MAX_DOCUMENT_BYTES
                return warn_about("thread document is too large to read " \
                                  "(#{size} bytes, over #{MAX_DOCUMENT_BYTES}); skipped")
              end

              document = JSON.parse(File.read(session.path))
              messages = document.is_a?(Hash) ? document["messages"] : nil
              return warn_about("thread document has no messages array; nothing to read") unless messages.is_a?(Array)

              messages.each_with_index { |record, index| yield record, index + 1 if record.is_a?(Hash) }
            rescue JSON::ParserError, EncodingError
              warn_about("thread document is not valid JSON; nothing to read")
            rescue SystemCallError => e
              warn_about("#{session.path} could not be read (#{e.class.name.split("::").last})")
            end

            def message_for(record, index)
              parts = Array(record["content"]).map { |item| part_for(item, index) }
              Message.new(role: role_for(record["role"], index), at: sent_at(record),
                          parts: parts, raw: record)
            end

            def part_for(item, index)
              return Part.new(type: :unknown) unless item.is_a?(Hash)

              case CONTENT_PARTS[item["type"]]
              when :text then Part.new(type: :text, text: item["text"].to_s)
              when :thinking then Part.new(type: :thinking, text: item["thinking"].to_s)
              when :image then Part.new(type: :image)
              when :tool_use
                Part.new(type: :tool_use, name: item["name"], call_id: item["id"],
                         text: stringify(item["input"]))
              when :tool_result
                Part.new(type: :tool_result, call_id: item["toolUseID"], text: tool_result_text(item))
              else
                warn_about("message #{index}: unrecognized content part #{item["type"].inspect}")
                Part.new(type: :unknown, text: item["text"])
              end
            end

            # A tool call that failed carries run.error and no run.result — 2 of the
            # 14 tool results in the one real thread. Reading only run.result rendered
            # those as empty text, which reads as "the tool returned nothing" rather
            # than "the tool failed, and here is why". The status stays in raw.
            def tool_result_text(item)
              run = item["run"]
              return "" unless run.is_a?(Hash)
              return stringify(run["result"]) if run.key?("result")

              error = run["error"]
              return "" unless error
              return error["message"] if error.is_a?(Hash) && error["message"].is_a?(String)

              stringify(error)
            end

            def role_for(role, index)
              ROLES.fetch(role) do
                warn_about("message #{index}: unrecognized role #{role.inspect}")
                :unknown
              end
            end

            # Epoch milliseconds, not seconds and not a string. nil where the thread
            # records no time, rather than a guess derived from the file.
            #
            # Split into whole seconds and a millisecond remainder rather than divided
            # by 1000.0: a Float cannot hold .503 exactly, so the divided form built a
            # Time whose subsecond was 2109735/4194304 and compared unequal to the
            # instant it was meant to be.
            def sent_at(record)
              millis = record.dig("meta", "sentAt")
              return nil unless millis.is_a?(Integer)

              Time.at(millis / 1000, millis % 1000, :millisecond).utc
            end

            def stringify(value)
              value.is_a?(String) || value.nil? ? value.to_s : JSON.generate(value)
            end
          end
        end
  end
end
