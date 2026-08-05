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
      # Design doc 8.4: Amp's local layout drifts between machines, so threads/ is the
      # one path stable enough that its absence is a real failure. secrets.json is
      # declared but optional: it is a credentials file rather than a transcript store,
      # and it does not exist until `amp login` runs, so a missing one says the user has
      # not authenticated, not that this adapter's claim about the layout is wrong.
      # It stays a layer so `audit` can still report a plaintext token file inside a
      # sync folder, which is the check that actually matters for it.
      store :secrets, path: "secrets.json", format: :json, optional: true

      warning "the server holds the canonical copy; local threads may be a partial mirror"
    end
  end
end
