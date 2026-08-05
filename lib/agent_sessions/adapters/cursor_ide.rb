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

      # Layer 2 runs on Base defaults: id is the transcript filename, the
      # projects/<name> segment is a bare name (not a decodable path), and no
      # reader exists, so fidelity stays :unsupported.
      #
      # Gated on primary_layer.exists?, the same shape pi's and Amp's reports
      # use: this is a "here is what breaks, please act on it" warning, not a
      # permanent property of the format, so the plan's rule sends it only to
      # someone who can do something about it — a user whose declared store
      # actually exists. It will not fire on this machine: the only real
      # Cursor install found here (2026-08-05, design doc 8.3) has no
      # ~/.cursor/projects at all, only argv.json, extensions/, and
      # shouldUpdate — which is exactly the case this warning is FOR, not a
      # reason to drop the gate. What breaks: the declared store is a Layer 1
      # location error, not just an empty one — real Cursor IDE agent
      # sessions live in a different file this adapter does not read. How a
      # user notices: `sessions`/`projects` report nothing for an agent they
      # know they used. What to send back: nothing — this is already tracked
      # (design doc 8.3, plan follow-up 7) for a 0.3 fix that reads
      # ~/Library/Application Support/Cursor/User/globalStorage/state.vscdb
      # instead; the SQLite schema there is undocumented and seen on one
      # machine only, which is why it waits on Task 8's sqlite3 machinery
      # rather than shipping in 0.2 as a guess.
      def warnings
        list = super
        if primary_layer.exists?
          list << "the declared store (~/.cursor/projects/<name>/agent-transcripts) is not where " \
                  "Cursor IDE agent sessions actually live on the machine this was verified on; the " \
                  "real ones were found in ~/Library/Application Support/Cursor/User/globalStorage/" \
                  "state.vscdb (table cursorDiskKV, keys composerData:<uuid>) — repointing this " \
                  "adapter there is deferred to a future release, so `sessions` and `projects` will " \
                  "under-report for this agent until then"
        end
        list
      end
    end
  end
end
