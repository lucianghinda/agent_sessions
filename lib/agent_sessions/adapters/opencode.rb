# frozen_string_literal: true

module AgentSessions
  module Adapters
    class Opencode < Base
      agent :opencode
      label "opencode"
      documented :partly
      verified_on "2026-07-21"

      base_dir default: "~/.local/share/opencode", env: "XDG_DATA_HOME", env_join: "opencode"

      store :database, path: "opencode.db", format: :sqlite
      store :legacy, dir: "storage", format: :json, optional: true

      warning "pre-v1.2.0 storage/ tree may remain on disk after migration; " \
              "counting it alongside opencode.db double-counts sessions"
    end
  end
end
