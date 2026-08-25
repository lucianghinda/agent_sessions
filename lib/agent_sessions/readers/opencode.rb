# frozen_string_literal: true

module AgentSessions
  module Readers
    # opencode sessions, read from the shared SQLite database the adapter
    # already enumerates. Written against a real store on this machine
    # (2026-08-24): 365 sessions, whose message and part rows settled every
    # mapping below — this is the first reader whose "corpus" is a database
    # rather than files.
    #
    # A "record" here is synthetic: one message row's parsed `data` plus every
    # part row belonging to it, as {"message" => ..., "parts" => [...]}. That
    # composite IS the raw a Message carries — rule 1 needs the parts included,
    # because the content lives in them, not in the message row.
    class Opencode < Base
      # Conversation content. text and reasoning map 1:1; a `tool` part holds
      # BOTH the call and its result in one row (state.input / state.output),
      # so it becomes two Parts — the assistant's act and the tool answering —
      # rather than flattening one of them away.
      CONTENT_PARTS = %w[text reasoning tool].freeze

      # State, not conversation, skipped in silence — the same judgement
      # Claude's session-state records get. Observed counts in the real store:
      # step-start 4,391, step-finish 4,380 (consumed for usage below), patch
      # 569 (files a step touched), file 25 (attachments), agent 1, compaction
      # 1 (surfaced through `compactions`, not as a message).
      STATE_PARTS = %w[step-start step-finish patch file agent compaction snapshot].freeze

      # Session totals, summed per message. No dedup is needed: one row is one
      # API response, and the sum was verified against the store's own
      # per-session rollup columns — 9,727,437 input / 94,266 output /
      # 22,184,157 cache-read, exactly equal both ways on the real store.
      def usage
        total = nil
        each_record do |record, _row_number|
          usage = usage_from(record)
          next unless usage

          total = total ? total + usage : usage
        end
        total
      end

      private

      # Message rows for this session, oldest first. time_created is epoch
      # millis; id is the tiebreak so two messages written in the same
      # millisecond keep a stable order. Parts are fetched per message rather
      # than per session: a session's tool outputs can be arbitrarily large,
      # and rule 3 (never assume it fits in memory) applies to a database
      # exactly as it does to a 2.6 GB file.
      #
      # A failure to read the DATABASE warns and yields nothing — one
      # unreadable session must not take down a sweep — unlike the adapter,
      # which raises UnreadableStore because enumeration has nothing partial
      # to return. A missing sqlite3 gem still raises: that is the caller's
      # environment, not this session's data.
      def each_record
        require_sqlite!
        db = nil
        row_number = 0
        begin
          db = Sqlite.open_readonly(session.path)
          db.execute("SELECT id, data FROM message WHERE session_id = ? ORDER BY time_created, id",
                     [session.id]) do |(id, data)|
            row_number += 1
            message = parse_row(data, "message #{id}") or next
            yield({ "message" => message, "parts" => parts_rows(db, id) }, row_number)
          end
        rescue SQLite3::Exception => e
          warn_about("#{session.path} could not be read (#{e.class.name.split("::").last})")
        ensure
          db&.close
        end
      end

      def parts_rows(db, message_id)
        db.execute("SELECT id, data FROM part WHERE message_id = ? ORDER BY time_created, id",
                   [message_id]).filter_map { |(id, data)| parse_row(data, "part #{id}") }
      end

      def parse_row(data, label)
        record = JSON.parse(data)
        return record if record.is_a?(Hash)

        warn_about("#{label} is not a JSON object; skipped")
      rescue JSON::ParserError, TypeError
        warn_about("#{label} does not hold valid JSON; skipped")
      end

      def message_for(record, row_number)
        data = record["message"]
        role = data["role"]
        unless %w[user assistant].include?(role)
          warn_about("message #{row_number}: unrecognized role #{role.inspect}")
          return build(record, :unknown)
        end

        build(record, role.to_sym)
      end

      def build(record, role)
        data = record["message"]
        Message.new(role: role, at: epoch_ms(data.dig("time", "created")),
                    parts: content_parts(record), raw: record,
                    usage: usage_from(record), model: model_from(data))
      end

      def content_parts(record)
        record["parts"].flat_map do |part|
          type = part["type"]
          next [] if STATE_PARTS.include?(type)

          case type
          when "text" then [Part.new(type: :text, text: part["text"].to_s)]
          when "reasoning" then [Part.new(type: :thinking, text: part["text"].to_s)]
          when "tool" then tool_parts(part)
          # A subagent spawn: {prompt, description, agent, model, command} —
          # found by running this reader over all 365 real sessions and
          # reading its one warning. The assistant's act of delegating, so
          # :tool_use like Claude's Task; the child's turns are its own
          # session row (parent_id), never inlined here.
          when "subtask"
            [Part.new(type: :tool_use, name: part["agent"] || "subtask", text: part["prompt"].to_s)]
          else
            warn_about("unrecognized part type #{type.inspect}")
            [Part.new(type: :unknown, text: part["text"])]
          end
        end
      end

      # state.input is a Hash (the tool's arguments), state.output a String.
      # The result Part appears only when the state carries an output — a
      # pending or errored call answered nothing, and an empty result would
      # claim it did.
      def tool_parts(part)
        state = part["state"]
        state = {} unless state.is_a?(Hash)
        parts = [Part.new(type: :tool_use, name: part["tool"], call_id: part["callID"],
                          text: stringify(state["input"]))]
        parts << Part.new(type: :tool_result, call_id: part["callID"],
                          text: state["output"].to_s) if state.key?("output")
        parts
      end

      # An assistant row carries its own tokens and cost (every one of the
      # 4,000+ assistant rows in the real store does). The step-finish
      # fallback covers the schema generation tokentelemetry observed, where
      # only parts carried tokens; the two sources are per-message equal where
      # both exist (verified: 10,557/221/489 both ways on a real message), so
      # preferring the message row can never double-count.
      def usage_from(record)
        data = record["message"]
        tokens = data["tokens"]
        return tokens_usage(tokens, data["cost"]) if tokens.is_a?(Hash)

        step_usage(record["parts"])
      end

      def tokens_usage(tokens, cost)
        mapped = Usage.new(input: count_from(tokens["input"]),
                           output: count_from(tokens["output"]),
                           reasoning: count_from(tokens["reasoning"]),
                           cache_read: count_from(tokens.dig("cache", "read")),
                           cache_creation: count_from(tokens.dig("cache", "write")),
                           cost: cost_from(cost))
        mapped.to_h.each_value.any? ? mapped : nil
      end

      def step_usage(parts)
        total = nil
        parts.each do |part|
          next unless part["type"] == "step-finish" && part["tokens"].is_a?(Hash)

          usage = tokens_usage(part["tokens"], part["cost"])
          next unless usage

          total = total ? total + usage : usage
        end
        total
      end

      def model_from(data)
        model = data["modelID"] # an assistant row's spelling
        model = data.dig("model", "modelID") unless model.is_a?(String) # a user row's
        model.is_a?(String) ? model : nil
      end

      # {"type":"compaction","auto":false} is the whole record observed — no
      # count of what it replaced, so replaced_count is nil rather than a zero
      # that would read as "stood in for nothing".
      def compaction_for(record)
        part = record["parts"].find { |candidate| candidate["type"] == "compaction" }
        return nil unless part

        Compaction.new(at: epoch_ms(record["message"].dig("time", "created")),
                       replaced_count: nil, raw: part)
      end

      def stringify(value)
        value.is_a?(String) || value.nil? ? value.to_s : JSON.generate(value)
      end

      # Epoch millis to Time, with the adapter's session_time guards: a
      # non-Numeric is nil, and a huge-but-real Integer that overflows to
      # Infinity once divided must not reach Time.at.
      def epoch_ms(millis)
        return nil unless millis.is_a?(Numeric)

        seconds = millis / 1000.0
        Time.at(seconds) if seconds.finite?
      end

      def require_sqlite!
        require "sqlite3"
      rescue LoadError
        raise MissingDependency,
              "opencode messages live in opencode.db (SQLite); add the sqlite3 gem to read them"
      end
    end
  end
end
