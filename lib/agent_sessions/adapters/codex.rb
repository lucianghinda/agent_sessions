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
      # started_at_for's comment says what "local" costs elsewhere. The uuid
      # group is pinned to its actual shape (8-4-4-4-12 hex), not (.+): greedy
      # against \.jsonl\z, (.+) would swallow a sync tool's or backup's
      # " (conflicted copy)" suffix into what looks like a canonical id rather
      # than falling back to the basename, where such a copy is at least
      # visibly non-canonical.
      FILENAME = /\Arollout-(\d{4})-(\d{2})-(\d{2})T(\d{2})-(\d{2})-(\d{2})-(\h{8}-\h{4}-\h{4}-\h{4}-\h{12})\.jsonl\z/

      def session_id_from(path)
        captures = FILENAME.match(File.basename(path))&.captures or return super

        captures.last
      end

      # The digit groups accept 00-99 each, which Time.new does not: month 13,
      # minute 60, and similar out-of-range values raise ArgumentError rather
      # than being normalized. That is file DATA, not an adapter bug, so it
      # must not cross the line build_session draws between the two (a raising
      # hook is meant to surface as a programming error) — one such filename
      # among many good ones would otherwise take sessions, project_paths, and
      # sessions_for_project down to zero for every agent, not just Codex.
      #
      # Local, not UTC: session_meta's own "timestamp" field is UTC and agrees
      # with this to within 1s across all 360 real files here, but a machine
      # whose TZ changed, or a store copied from another machine, would make
      # this off by the offset delta while Claude's birthtime-based
      # started_at stays an absolute instant. Harmless today because Task 10
      # sorts sessions by updated_at, not started_at.
      def started_at_for(path, stat)
        parts = FILENAME.match(File.basename(path))&.captures or return super

        Time.new(*parts.first(6).map(&:to_i))
      rescue ArgumentError # the digits matched but do not form a real date
        super
      end

      # Line 1 is session_meta; the cwd lives in its payload (design doc
      # section 6 and 8.2, verified 2026-08-05 — 360/360 real files carry a
      # usable session_meta/payload/cwd on line 1). limit: 3 is slack against
      # that guarantee, not a fit to any observed multi-line case: it tolerates
      # a truncated or blank first line without paying for an unbounded scan.
      # "3" counts iterations of File.foreach(path, "\n", MAX_LINE_BYTES), not
      # lines: a >1MB record is chunked and each chunk is one iteration, so
      # this is really 3MB of read headroom, not "3 records." A future adapter
      # copying this pattern with limit: 1 would lose that tolerance entirely.
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
