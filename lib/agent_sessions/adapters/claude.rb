# frozen_string_literal: true

module AgentSessions
  module Adapters
    class Claude < Base
      agent :claude
      label "Claude Code"
      documented true
      verified_on "2026-07-21"
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
      # Verified against real project directories on 2026-08-05:
      # /Users/luciang/.codex -> -Users-luciang--codex
      def encode_project(dir)
        dir.gsub(/[^a-zA-Z0-9]/, "-")
      end

      # cwd is NOT on line 1 — real sessions open with leafUuid/mode/permissionMode
      # records and the first cwd appeared at line 4 (verified 2026-08-05). The
      # bounded scan keeps this a few-KB read on multi-GB files.
      def project_path_for(path)
        scan_jsonl_for_key(path, "cwd", limit: 25)&.fetch("cwd", nil)
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
