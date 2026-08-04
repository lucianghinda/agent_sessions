# frozen_string_literal: true

module AgentSessions
  module Adapters
    class Amp < Base
      agent :amp
      label "Amp CLI"
      documented :partly
      verified_on "2026-07-21"

      base_dir default: "~/.local/share/amp", env: "XDG_DATA_HOME", env_join: "amp"

      store :threads, dir: "threads", glob: "T-*.json", format: :json
      # Design doc 8.4: Amp's local layout drifts between machines, so every path
      # except threads/ and secrets.json is treated as drift when missing. These two
      # are the stable ones, so their absence is a real failure, not layout drift.
      store :secrets, path: "secrets.json", format: :json

      warning "the server holds the canonical copy; local threads may be a partial mirror"
    end
  end
end
