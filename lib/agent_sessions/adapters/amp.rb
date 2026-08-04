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
      store :secrets, path: "secrets.json", format: :json, optional: true

      warning "the server holds the canonical copy; local threads may be a partial mirror"
    end
  end
end
