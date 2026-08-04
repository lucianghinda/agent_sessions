# frozen_string_literal: true

module AgentSessions
  module Adapters
    class CursorIde < Base
      agent :cursor_ide
      label "Cursor IDE"
      documented false
      verified_on "2026-07-21"

      # env_join "cursor" (no leading dot) follows XDG convention;
      # verify against a real XDG setup — the vendor does not document this.
      base_dir default: "~/.cursor", env: "XDG_CONFIG_HOME", env_join: "cursor"

      store :transcripts, dir: "projects", glob: "*/agent-transcripts/*", format: :unknown

      warning "the IDE transcript store does not sync with the CLI chat store"
    end
  end
end
