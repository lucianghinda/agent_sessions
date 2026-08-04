# frozen_string_literal: true

module AgentSessions
  module Adapters
    class Codex < Base
      agent :codex
      label "Codex CLI"
      documented false
      verified_on "2026-07-21"

      base_dir default: "~/.codex", env: "CODEX_HOME"

      store :sessions, dir: "sessions", glob: "*/*/*/rollout-*.jsonl", format: :jsonl
      store :history, path: "history.jsonl", format: :jsonl, optional: true
      store :index, path: "session_index.jsonl", format: :jsonl, optional: true

      warning "the [history] config section governs history.jsonl only; " \
              "persistence = \"none\" does not stop rollout files"
    end
  end
end
