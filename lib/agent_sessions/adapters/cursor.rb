# frozen_string_literal: true

module AgentSessions
  module Adapters
    class Cursor < Base
      agent :cursor
      label "Cursor CLI"
      documented false
      verified_on "2026-07-21"
      fidelity :metadata

      # No env override. XDG_CONFIG_HOME was assumed here and disproved on
      # 2026-08-04: with it set, Cursor still stored under ~/.cursor, so honouring
      # it reported an installed agent as missing. Verified on macOS only.
      base_dir default: "~/.cursor"

      store :chats, dir: "chats", glob: "*/*/store.db", format: :sqlite
      store :acp_sessions, dir: "acp-sessions", format: :json, optional: true

      warning "chat payloads use an undocumented blob encoding; " \
              "reads are metadata-only until it is decoded"
      warning "no environment override is known for Cursor; XDG_CONFIG_HOME is not honoured"

      # chats/<chat-id>/<uuid>/store.db — two nested ids (design doc 16 Q5), so
      # the session id keeps both. The blob store is never opened here; the
      # sibling meta.json is the metadata source (8.3), with stat as fallback.
      #
      # Pure string manipulation on `path` — File.basename/File.dirname never
      # raise for any String input, so this hook cannot violate rule 3
      # (build_session lets a raising hook propagate) regardless of shape. A
      # path shallower than two segments is not reachable through this
      # store's OWN enumeration: the glob above is "*/*/store.db", and Dir.glob's
      # "*" never crosses a "/", so every path this adapter actually enumerates
      # is exactly two directories deep, by construction, not by convention
      # (see test_session_id_from_does_not_raise_for_a_shallow_path, which
      # calls this hook directly to pin the behaviour for a caller that
      # bypasses the glob).
      def session_id_from(path)
        uuid = File.basename(File.dirname(path))
        chat = File.basename(File.dirname(File.dirname(path)))
        "#{chat}/#{uuid}"
      end

      def started_at_for(path, stat)
        meta_time(path, "createdAtMs") || super
      end

      def updated_at_for(path, stat)
        meta_time(path, "updatedAtMs") || super
      end

      # cwd's presence in meta.json is not enough on its own (rule 1): the key
      # can hold a Hash, an Integer, anything JSON allows, and project_paths'
      # .uniq.sort raises on a non-String member. is_a?(String) is the guard,
      # not merely a style preference.
      def project_path_for(path)
        cwd = meta_for(path)["cwd"]
        cwd if cwd.is_a?(String)
      end

      private

      # Normalizes the container's TYPE, not just checked its presence (rule
      # 2): read_json already rescues a parse failure to {}, but a
      # meta.json that parses fine into something other than an object —
      # an array, a bare number, null — would otherwise reach ["cwd"] or
      # ["createdAtMs"] as a non-Hash receiver. Array#[] and Integer#[] both
      # raise TypeError for a String key; this is Amp's project_path_for bug
      # (design doc / task rules), one layer further down the same JSON tree.
      # Guarding once here, rather than at each of the three call sites
      # above, is what keeps meta_time and project_path_for simple `[]` reads
      # instead of three repeated type checks.
      #
      # Unbounded and per-instance, deliberately not fixed here: every
      # session's started_at_for/updated_at_for calls this EAGERLY (unlike
      # Session#project_path, whose resolver is released after first call —
      # see session.rb), so a full sweep (`sessions.force`, `project_paths`,
      # or a sessions_for_project miss that scans every session) retains one
      # parsed meta.json per chat for the adapter instance's whole lifetime.
      # Bounded takes (`.first(n)`, an early sessions_for_project match) cost
      # proportionally to what was actually consumed, matching the laziness
      # `sessions` promises elsewhere. What keeps this from being a real leak:
      # adapter instances are meant to be built fresh per resolution (Base's
      # own class comment) and dropped after, not held for a process's
      # lifetime the way a long-running server would; and meta.json is
      # documented as tiny (design doc 8.3, plan follow-up 8's contrast with
      # Amp's unbounded read_json). Revisit if either assumption stops
      # holding — a caller that keeps one adapter instance alive across many
      # full sweeps, or a store where meta.json stops being tiny.
      def meta_for(path)
        @meta ||= {}
        @meta[path] ||= begin
          data = read_json(File.join(File.dirname(path), "meta.json"))
          data.is_a?(Hash) ? data : {}
        end
      end

      # millis.is_a?(Numeric) alone is not enough: JSON has no Infinity/NaN
      # literal, but a finite-looking literal can still overflow to one.
      # createdAtMs: 1e400 parses to Float::INFINITY (verified — JSON.parse
      # accepts exponents past Float::MAX and Ruby overflows silently rather
      # than raising at parse time), and a plain integer literal hundreds of
      # digits long survives is_a?(Numeric) as an exact Integer but still
      # overflows to Infinity the moment `/ 1000.0` forces it through Float
      # (also verified). Either way Time.at(Float::INFINITY) raises
      # FloatDomainError, uncaught, which is rule 3's failure mode — one
      # adapter's bad timestamp taking down every agent's listing. The guard
      # therefore checks the DIVISION's result, not just the input: a merely
      # huge-but-finite value (an absurd but real millisecond count) is left
      # alone and produces an absurd-but-real Time, same as a negative one
      # produces a pre-1970 Time — neither raises, so neither is special-cased.
      def meta_time(path, key)
        millis = meta_for(path)[key]
        return nil unless millis.is_a?(Numeric)

        seconds = millis / 1000.0
        Time.at(seconds) if seconds.finite?
      end
    end
  end
end
