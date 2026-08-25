# frozen_string_literal: true

module AgentSessions
  module Readers
    # Codex rollout files. Every mapping here was written against a real corpus
    # rather than from the format notes: 415 files, 128,987 records, inventoried
    # 2026-08-12. The distribution is the reason for several decisions below —
    # response_item 57%, event_msg 38%, turn_context 4%, session_meta 416,
    # world_state 182, inter_agent_communication_metadata 129, compacted 18.
    #
    # Codex was chosen as the first reader for exactly this reason. pi was the
    # planned reference implementation, but its store held no session files at
    # all on the machine available, so every claim about its content would have
    # been inference. A reference implementation has to be falsifiable.
    class Codex < Base
      # Known, and deliberately not messages: the session header, per-turn
      # configuration, and two state records Codex added in July 2026. Silence
      # here is a judgement, not an oversight — these are not conversation, and
      # warning about them would train a caller to ignore warnings.
      NON_MESSAGE_TYPES = %w[session_meta turn_context world_state
                             inter_agent_communication_metadata].freeze

      # "developer" is what Codex writes where the normalized vocabulary says
      # :system. It is 101 of 292 role-bearing records in the sample, so this is
      # the common path, not an edge case.
      ROLES = { "user" => :user, "assistant" => :assistant, "developer" => :system,
                "system" => :system, "tool" => :tool }.freeze

      # encrypted_content maps to :unknown deliberately, not for want of a
      # better bucket: 80 real content items are encrypted by the model and this
      # gem will never read them. Recognized-and-unreadable is a different thing
      # from unrecognized, and only the second deserves a warning — a warning
      # that fires on a permanent, understood condition is noise on every read.
      CONTENT_PARTS = { "input_text" => :text, "output_text" => :text, "text" => :text,
                        "summary_text" => :text, "input_image" => :image,
                        "output_image" => :image, "encrypted_content" => :unknown }.freeze

      # Every entry past the first three in each list came from running this
      # reader over all 415 files and reading its own warnings: a 25-file sample
      # showed none of them. Counts in that corpus: web_search_call 288,
      # ghost_snapshot 197, agent_message 129, tool_search_call and
      # tool_search_output 26 each, image_generation_call 1.
      TOOL_CALLS = %w[custom_tool_call function_call local_shell_call
                      web_search_call tool_search_call].freeze
      TOOL_OUTPUTS = %w[custom_tool_call_output function_call_output local_shell_call_output
                        tool_search_output].freeze

      # Internal state that happens to travel as a response_item. Skipped in
      # silence for the same reason turn_context is: it is not conversation, and
      # a warning a caller must learn to ignore is worse than no warning.
      NON_MESSAGE_ITEMS = %w[ghost_snapshot].freeze

      # Where a tool call keeps what it was called with. custom_tool_call uses
      # input, function_call uses arguments, web_search_call uses action, and
      # tool_search_call uses arguments as a Hash rather than a String.
      CALL_INPUTS = %w[input arguments action].freeze

      # And where an output keeps its result.
      CALL_OUTPUTS = %w[output tools].freeze

      # Session totals. Codex writes no usage on its messages; it writes
      # token_count event records whose info.total_token_usage is a RUNNING
      # TOTAL — verified against a real rollout on this machine (2026-08-24):
      # consecutive records report total 33,751 then 69,135 while their
      # last_token_usage differ, so the last record is the session and summing
      # would multiply-count every earlier turn.
      #
      # Two normalizations, both from that same file:
      #
      #   input_tokens INCLUDES cached_input_tokens (33,431 including 19,200
      #   in the sample) — the opposite of Claude's disjoint spelling — so the
      #   cached share is subtracted to make Usage#input mean one thing across
      #   agents. Clamped at zero: a count that went negative would mean the
      #   two fields disagree, and a wrong zero beats a negative token count.
      #
      #   cache_write_input_tokens maps to cache_creation. total_tokens is
      #   deliberately not mapped anywhere: it restates the other fields, and
      #   any bucket it landed in would be double-counted by a caller summing
      #   buckets.
      def usage
        info = nil
        each_record do |record, _line_number|
          next unless record["type"] == "event_msg"

          candidate = record.dig("payload", "info", "total_token_usage")
          info = candidate if record.dig("payload", "type") == "token_count" && candidate.is_a?(Hash)
        end
        return nil unless info

        input = count_from(info["input_tokens"])
        cached = count_from(info["cached_input_tokens"])
        mapped = Usage.new(input: input && cached ? [input - cached, 0].max : input,
                           output: count_from(info["output_tokens"]),
                           cache_read: cached,
                           cache_creation: count_from(info["cache_write_input_tokens"]),
                           reasoning: count_from(info["reasoning_output_tokens"]))
        # Same rule as Claude's usage_from: a token_count record whose every
        # field failed the count check answers nil, not an all-nil Usage.
        mapped.to_h.each_value.any? ? mapped : nil
      end

      private

      def message_for(record, line_number)
        type = record["type"]
        return nil if NON_MESSAGE_TYPES.include?(type) || type == "compacted"
        return event_message(record) if type == "event_msg"

        payload = record["payload"]
        unless type == "response_item" && payload.is_a?(Hash)
          return warn_about("line #{line_number}: unrecognized record type #{type.inspect}") ||
                 unknown_message(record)
        end

        item_message(record, payload, line_number)
      end

      def item_message(record, payload, line_number)
        case payload["type"]
        when "message" then text_message(record, payload, line_number)
        # Multi-agent traffic: author and recipient instead of role, but the
        # content array is a normal one. Conversation, so it is read as such.
        when "agent_message" then build(record, :assistant, content_parts(payload, line_number))
        when "reasoning" then reasoning_message(record, payload)
        when *TOOL_CALLS then tool_call_message(record, payload)
        when *TOOL_OUTPUTS then tool_output_message(record, payload)
        when *NON_MESSAGE_ITEMS then nil
        # The result is base64 and was 2.5 MB in the one real occurrence. It
        # stays in raw: inlining it would make holding the message cost
        # megabytes, and decoding pixels is not this layer's job.
        when "image_generation_call" then build(record, :assistant, [Part.new(type: :image)])
        else
          warn_about("line #{line_number}: unrecognized response_item type #{payload["type"].inspect}")
          unknown_message(record)
        end
      end

      def text_message(record, payload, line_number)
        build(record, role_for(payload["role"], line_number), content_parts(payload, line_number))
      end

      def content_parts(payload, line_number)
        Array(payload["content"]).map do |item|
          next Part.new(type: :unknown) unless item.is_a?(Hash)

          kind = CONTENT_PARTS[item["type"]]
          next Part.new(type: kind, text: %i[image unknown].include?(kind) ? nil : item["text"].to_s) if kind

          warn_about("line #{line_number}: unrecognized content part #{item["type"].inspect}")
          Part.new(type: :unknown, text: item["text"])
        end
      end

      # content is null on every reasoning record observed; the readable text is
      # in summary. encrypted_content holds the rest and this gem cannot decrypt
      # it, so exposing a :thinking part built from summary alone is the honest
      # maximum — claiming more would misreport fidelity.
      def reasoning_message(record, payload)
        parts = Array(payload["summary"]).filter_map do |item|
          Part.new(type: :thinking, text: item["text"].to_s) if item.is_a?(Hash)
        end
        build(record, :assistant, parts)
      end

      # The call is the assistant's act; the output is the tool answering.
      #
      # Not every call carries a name: web_search_call and tool_search_call
      # identify themselves only by record type, so the type minus its "_call"
      # suffix is the name. That is a derivation, not a guess — it produces
      # exactly the name the agent would use ("web_search", "tool_search").
      def tool_call_message(record, payload)
        name = payload["name"] || payload["type"].to_s.sub(/_call\z/, "")
        part = Part.new(type: :tool_use, name: name, call_id: payload["call_id"],
                        text: stringify(payload, CALL_INPUTS))
        build(record, :assistant, [part])
      end

      def tool_output_message(record, payload)
        part = Part.new(type: :tool_result, call_id: payload["call_id"],
                        text: stringify(payload, CALL_OUTPUTS))
        build(record, :tool, [part])
      end

      # A call's input is a String for some record types and a Hash for others
      # (tool_search_call's arguments, web_search_call's action). Serializing the
      # Hash keeps the value readable and lossless rather than rendering it as
      # Ruby's inspect output; raw still holds the original either way.
      def stringify(payload, keys)
        key = keys.find { |candidate| payload.key?(candidate) }
        value = key && payload[key]
        value.is_a?(String) || value.nil? ? value.to_s : JSON.generate(value)
      end

      # Opt-in only: event_msg is 38% of the corpus and is UI bookkeeping (token
      # counts, rate limits, task_started). Including it by default would inflate
      # every message count a caller made. No warning — the caller asked.
      def event_message(record)
        return nil unless include_events

        build(record, :system, [Part.new(type: :unknown, text: record.dig("payload", "type"))])
      end

      def unknown_message(record)
        build(record, :unknown, [Part.new(type: :unknown)])
      end

      def build(record, role, parts)
        Message.new(role: role, at: time_from(record["timestamp"]), parts: parts, raw: record)
      end

      def role_for(role, line_number)
        ROLES.fetch(role) do
          warn_about("line #{line_number}: unrecognized role #{role.inspect}")
          :unknown
        end
      end

      # replacement_history is a restatement of turns already yielded, so it is
      # counted, never replayed. A reader that expanded it would report the same
      # conversation twice — the miscount the design doc warns about, arriving
      # through the reader instead of through a naive line count.
      def compaction_for(record)
        return nil unless record["type"] == "compacted"

        history = record.dig("payload", "replacement_history")
        Compaction.new(at: time_from(record["timestamp"]),
                       replaced_count: history.is_a?(Array) ? history.size : 0,
                       raw: record)
      end
    end
  end
end
