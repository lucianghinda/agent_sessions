# frozen_string_literal: true

module AgentSessions
  module Adapters
    class Codex < Base
      agent :codex
      label "Codex CLI"
      documented false
      verified_on "2026-07-21"
      fidelity :full

      base_dir default: "~/.codex", env: "CODEX_HOME"

      store :sessions, dir: "sessions", glob: "*/*/*/rollout-*.jsonl", format: :jsonl
      store :history, path: "history.jsonl", format: :jsonl, optional: true
      store :index, path: "session_index.jsonl", format: :jsonl, optional: true

      warning "the [history] config section governs history.jsonl only; " \
              "persistence = \"none\" does not stop rollout files"

      # rollout-<YYYY-MM-DDTHH-MM-SS>-<uuid>.jsonl (verified 2026-08-05 against
      # 360 real session files on this machine — every one matched). The
      # timestamp uses the local clock and dashes where ISO 8601 has colons.
      FILENAME = /\Arollout-(\d{4})-(\d{2})-(\d{2})T(\d{2})-(\d{2})-(\d{2})-(.+)\.jsonl\z/

      def session_id_from(path)
        FILENAME.match(File.basename(path))&.captures&.last || super
      end

      def started_at_for(path, stat)
        parts = FILENAME.match(File.basename(path))&.captures or return super

        Time.new(*parts.first(6).map(&:to_i))
      end

      # Line 1 is session_meta; the cwd lives in its payload (design doc
      # section 6 and 8.2, verified 2026-08-05 — 360/360 real files carry a
      # usable session_meta/payload/cwd on line 1). limit: 3 is slack against
      # that guarantee, not a fit to any observed multi-line case: it tolerates
      # a truncated or blank first line without paying for an unbounded scan.
      #
      # The predicate requires more than scan_jsonl_for_key's key-presence
      # check can: real sessions on this machine also carry a "payload" key on
      # later, non-session_meta records (turn_context observed 2026-08-05)
      # whose payload itself carries "cwd" — a presence-only scan would stop
      # at whichever comes first, right only by coincidence. Requiring
      # type == "session_meta" pins the read to the one documented source of
      # truth (design doc 8.2), and requiring a Hash payload with a String cwd
      # stops a malformed record (payload not a Hash, or cwd not a String)
      # from permanently shadowing a later, usable session_meta or reaching
      # project_paths' .uniq.sort with the wrong type.
      def project_path_for(path)
        scan_jsonl_for_key(path, "payload", limit: 3) do |record|
          record["type"] == "session_meta" &&
            record["payload"].is_a?(Hash) &&
            record["payload"]["cwd"].is_a?(String)
        end&.dig("payload", "cwd")
      end
    end
  end
end
