# frozen_string_literal: true

module AgentSessions
  module Adapters
    class Cursor < Base
      agent :cursor
      label "Cursor CLI"
      documented false
      verified_on "2026-07-21"

      # env_join "cursor" (no leading dot) follows XDG convention;
      # verify against a real XDG setup — the vendor does not document this.
      base_dir default: "~/.cursor", env: "XDG_CONFIG_HOME", env_join: "cursor"

      store :chats, dir: "chats", glob: "*/*/store.db", format: :sqlite
      store :acp_sessions, dir: "acp-sessions", format: :json, optional: true

      warning "chat payloads use an undocumented blob encoding; " \
              "reads are metadata-only until it is decoded"
    end
  end
end
