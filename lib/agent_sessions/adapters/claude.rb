# frozen_string_literal: true

module AgentSessions
  module Adapters
    class Claude < Base
      agent :claude
      label "Claude Code"
      documented true
      verified_on "2026-08-05"
      fidelity :full

      base_dir default: "~/.claude", env: "CLAUDE_CONFIG_DIR"

      store :projects, dir: "projects", glob: "*/*.jsonl", format: :jsonl
      store :history, path: "history.jsonl", format: :jsonl, optional: true

      DEFAULT_CLEANUP_PERIOD_DAYS = 30

      def retention
        configured_retention || DEFAULT_CLEANUP_PERIOD_DAYS
      end

      def retention_source
        configured_retention ? :setting : :default
      end

      def warnings
        list = super
        if env_active?("CLAUDE_CODE_SKIP_PROMPT_HISTORY")
          list << "CLAUDE_CODE_SKIP_PROMPT_HISTORY is set: history.jsonl is not being written"
        end
        list
      end

      # Every non-alphanumeric character becomes "-" (design doc section 7).
      # dir must already be absolute and expanded — sessions_for_project
      # guarantees that; a direct caller passing "app", "~/app", or a
      # trailing slash gets a nonsense encoding (see Base#encode_project).
      # Verified against real project directories on 2026-08-05:
      # /Users/dev/.local -> -Users-dev--local
      def encode_project(dir)
        dir.gsub(/[^a-zA-Z0-9]/, "-")
      end

      # cwd is NOT on line 1. Real sessions open with a kebab-case preamble
      # (ai-title, agent-name, mode, permission-mode) followed by a
      # variable-length run of file-history-snapshot records — that run is
      # what pushes the first cwd-bearing record out further on some files,
      # and nothing bounds its length. Observed on this machine on 2026-08-05:
      # line 3 (19 files), line 4 (48 files), line 9 (1 file, a longer
      # snapshot run). limit: 25 is ~2.8x that observed maximum — headroom
      # for the variable-length run, not a tight fit to the common case — and
      # keeps this a few-KB read even on multi-GB files.
      #
      # The block guards against a record that carries "cwd" but not usably:
      # null shadows a later valid record, and a wrong type (Integer, Hash)
      # would otherwise reach project_paths' .uniq.sort and raise there.
      # scan_jsonl_for_key already guarantees the key is present once the
      # block accepts, so a plain fetch (no default) is safe.
      def project_path_for(path)
        scan_jsonl_for_key(path, "cwd", limit: 25) { |record| record["cwd"].is_a?(String) }&.fetch("cwd")
      end

      private

      def settings
        @settings ||= read_json(File.join(base_dir, "settings.json"))
      end

      def configured_retention
        value = settings["cleanupPeriodDays"]
        value if value.is_a?(Integer) && !value.negative?
      end
    end
  end
end
