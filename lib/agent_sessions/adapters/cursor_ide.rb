# frozen_string_literal: true

module AgentSessions
  module Adapters
    class CursorIde < Base
      agent :cursor_ide
      label "Cursor IDE"
      documented false
      verified_on "2026-07-21"

      # No env override. XDG_CONFIG_HOME was assumed here and disproved on
      # 2026-08-04: with it set, Cursor still stored under ~/.cursor, so honouring
      # it reported an installed agent as missing. Verified on macOS only.
      base_dir default: "~/.cursor"

      store :transcripts, dir: "projects", glob: "*/agent-transcripts/*", format: :unknown

      warning "the IDE transcript store does not sync with the CLI chat store"
      warning "no environment override is known for Cursor; XDG_CONFIG_HOME is not honoured"
    end
  end
end
