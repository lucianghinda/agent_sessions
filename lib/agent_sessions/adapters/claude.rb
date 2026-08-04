# frozen_string_literal: true

module AgentSessions
  module Adapters
    class Claude < Base
      agent :claude
      label "Claude Code"
      documented true
      verified_on "2026-07-21"

      base_dir default: "~/.claude", env: "CLAUDE_CONFIG_DIR"

      store :projects, dir: "projects", glob: "*/*.jsonl", format: :jsonl
      store :history, path: "history.jsonl", format: :jsonl, optional: true

      DEFAULT_CLEANUP_PERIOD_DAYS = 30

      def retention
        settings.fetch("cleanupPeriodDays", DEFAULT_CLEANUP_PERIOD_DAYS)
      end

      def retention_source
        settings.key?("cleanupPeriodDays") ? :setting : :default
      end

      def warnings
        list = super
        if env_active?("CLAUDE_CODE_SKIP_PROMPT_HISTORY")
          list << "CLAUDE_CODE_SKIP_PROMPT_HISTORY is set: history.jsonl is not being written"
        end
        list
      end

      private

      def settings
        @settings ||= read_json(File.join(base_dir, "settings.json"))
      end
    end
  end
end
