# frozen_string_literal: true

module AgentSessions
  module Readers
    # Qwen Code chat files. PROVISIONAL, like the adapter: written against
    # tokentelemetry's parser of this format, not against real Qwen output.
    #
    # The record shape is Anthropic's — type user/assistant, message.content
    # as an array of typed parts, message.usage with the same five spellings
    # Claude uses. This is deliberately NOT a subclass of Readers::Claude
    # despite that overlap: Claude's reader also carries Claude Code's sidecar
    # machinery (spilled tool output, subagent transcripts, uuid/parentUuid
    # branching), none of which is known to exist here, and inheriting would
    # mean disabling each one and then re-checking every future Claude change
    # against an agent nobody can test. Two readers with two evidence bases
    # will drift honestly; one reader pretending to serve both will drift
    # silently.
    class Qwen < Base
      CONTENT_PARTS = { "text" => :text, "thinking" => :thinking, "tool_use" => :tool_use,
                        "tool_result" => :tool_result, "image" => :image }.freeze

      # Session totals, deduplicated by message.id the way Claude's are: the
      # same API response can stream into one record per content block, and
      # both agents speak the same wire format. Unverified for Qwen — if its
      # writer does not repeat ids, this dedup is simply a no-op.
      def usage
        seen = {}
        total = nil
        each_record do |record, _line_number|
          usage = usage_from(record)
          next unless usage

          id = record.dig("message", "id")
          next if id && seen[id]

          seen[id] = true if id
          total = total ? total + usage : usage
        end
        total
      end

      private

      def message_for(record, line_number)
        type = record["type"]
        return nil if type == "summary"

        unless %w[user assistant].include?(type)
          warn_about("line #{line_number}: unrecognized record type #{type.inspect}")
          return build(record, :unknown, [Part.new(type: :unknown)])
        end

        build(record, type.to_sym, content_parts(record, line_number))
      end

      # content is an array of parts, or a bare String saying the same thing
      # shorter — both spellings appear in this wire format.
      def content_parts(record, line_number)
        content = record.dig("message", "content")
        return [Part.new(type: :text, text: content)] if content.is_a?(String)

        Array(content).map { |item| part_for(item, line_number) }
      end

      def part_for(item, line_number)
        return Part.new(type: :unknown) unless item.is_a?(Hash)

        case CONTENT_PARTS[item["type"]]
        when :text then Part.new(type: :text, text: item["text"].to_s)
        when :thinking then Part.new(type: :thinking, text: item["thinking"].to_s)
        when :image then Part.new(type: :image)
        when :tool_use
          Part.new(type: :tool_use, name: item["name"], call_id: item["id"],
                   text: stringify(item["input"]))
        when :tool_result
          Part.new(type: :tool_result, call_id: item["tool_use_id"],
                   text: flatten_result(item["content"]))
        else
          warn_about("line #{line_number}: unrecognized content part #{item["type"].inspect}")
          Part.new(type: :unknown, text: item["text"])
        end
      end

      def flatten_result(content)
        return content if content.is_a?(String)

        Array(content).filter_map { |item| item["text"] if item.is_a?(Hash) && item["type"] == "text" }.join
      end

      def build(record, role, parts)
        model = record.dig("message", "model")
        Message.new(role: role, at: time_from(record["timestamp"]), parts: parts, raw: record,
                    usage: usage_from(record), model: model.is_a?(String) ? model : nil)
      end

      # The Anthropic spelling, where input_tokens is already disjoint from
      # the cache counts — so unlike Gemini's and Codex's, nothing is
      # subtracted here. ephemeral_1h_input_tokens is a cache-creation count
      # at a different TTL; it is added to cache_creation rather than given a
      # bucket of its own, because this gem's Usage does not model TTL and
      # dropping it would under-report what was written to cache.
      def usage_from(record)
        usage = record.dig("message", "usage")
        return nil unless usage.is_a?(Hash)

        creation = count_from(usage["cache_creation_input_tokens"])
        hourly = count_from(usage.dig("cache_creation", "ephemeral_1h_input_tokens"))
        mapped = Usage.new(input: count_from(usage["input_tokens"]),
                           output: count_from(usage["output_tokens"]),
                           cache_read: count_from(usage["cache_read_input_tokens"]),
                           cache_creation: creation || hourly ? creation.to_i + hourly.to_i : nil)
        mapped.to_h.each_value.any? ? mapped : nil
      end

      def stringify(value)
        value.is_a?(String) || value.nil? ? value.to_s : JSON.generate(value)
      end
    end
  end
end
