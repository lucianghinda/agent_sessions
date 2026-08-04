# frozen_string_literal: true

module AgentSessions
  module Adapters
    class Cursor < Base
      agent :cursor
      label "Cursor CLI"
      documented false
      verified_on "2026-07-21"

      # No env override. XDG_CONFIG_HOME was assumed here and disproved on
      # 2026-08-04: with it set, Cursor still stored under ~/.cursor, so honouring
      # it reported an installed agent as missing. Verified on macOS only.
      base_dir default: "~/.cursor"

      store :chats, dir: "chats", glob: "*/*/store.db", format: :sqlite
      store :acp_sessions, dir: "acp-sessions", format: :json, optional: true

      warning "chat payloads use an undocumented blob encoding; " \
              "reads are metadata-only until it is decoded"
      warning "no environment override is known for Cursor; XDG_CONFIG_HOME is not honoured"
    end
  end
end
