# frozen_string_literal: true

module AgentSessions
  module Adapters
    class Pi < Base
      agent :pi
      label "pi"
      documented true
      verified_on "2026-07-21"

      base_dir default: "~/.pi/agent", env: "PI_CODING_AGENT_DIR"

      store :sessions, dir: "sessions", glob: "--*--/*.jsonl", format: :jsonl,
                       env: "PI_CODING_AGENT_SESSION_DIR"
    end
  end
end
