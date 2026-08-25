# frozen_string_literal: true

module Agent
  module Sessions
        module Adapters
          class Claude < Base
            agent :claude
            label "Claude Code"
            documented true
            verified_on "2026-08-05"
            fidelity :full

            base_dir default: "~/.claude", env: "CLAUDE_CONFIG_DIR"

            store :projects, dir: "projects", glob: "*/*.jsonl", format: :jsonl
            store :history, path: "history.jsonl", format: :jsonl, optional: true

            def self.reader_class = Readers::Claude

            DEFAULT_CLEANUP_PERIOD_DAYS = 30

            def retention
              configured_retention || DEFAULT_CLEANUP_PERIOD_DAYS
            end

            def retention_source
              configured_retention ? :setting : :default
            end

            def warnings
              list = super
              if env_active?("CLAUDE_CODE_SKIP_PROMPT_HISTORY")
                list << "CLAUDE_CODE_SKIP_PROMPT_HISTORY is set: history.jsonl is not being written"
              end
              list
            end

            # Every non-alphanumeric character becomes "-" (design doc section 7).
            # dir must already be absolute and expanded — sessions_for_project
            # guarantees that; a direct caller passing "app", "~/app", or a
            # trailing slash gets a nonsense encoding (see Base#encode_project).
            # Verified against real project directories on 2026-08-05:
            # /Users/dev/.local -> -Users-dev--local
            def encode_project(dir)
              dir.gsub(/[^a-zA-Z0-9]/, "-")
            end

            # cwd is NOT on line 1. Real sessions open with a kebab-case preamble
            # (ai-title, agent-name, mode, permission-mode) followed by a
            # variable-length run of file-history-snapshot records — that run is
            # what pushes the first cwd-bearing record out further on some files,
            # and nothing bounds its length. Observed on this machine on 2026-08-05:
            # line 3 (19 files), line 4 (48 files), line 9 (1 file, a longer
            # snapshot run). limit: 25 is ~2.8x that observed maximum — headroom
            # for the variable-length run, not a tight fit to the common case — and
            # keeps this a few-KB read even on multi-GB files.
            #
            # The block guards against a record that carries "cwd" but not usably:
            # null shadows a later valid record, and a wrong type (Integer, Hash)
            # would otherwise reach project_paths' .uniq.sort and raise there.
            # scan_jsonl_for_key already guarantees the key is present once the
            # block accepts, so a plain fetch (no default) is safe.
            def project_path_for(path)
              scan_jsonl_for_key(path, "cwd", limit: 25) { |record| record["cwd"].is_a?(String) }&.fetch("cwd")
            end

            # Claude Code writes a directory beside each transcript, named after the
            # session id with the extension dropped: subagents/ holds the transcripts
            # of agents this session spawned, tool-results/ holds tool output too
            # large to inline. Those bytes are this session's, and until they were
            # counted `du` reported 122.1 MB for a store `audit` reported 173.0 MB
            # for — 71% — because audit sums the store directory whole while du sums
            # sessions. Two commands, one directory, a 29% disagreement.
            #
            # Measured over 128 real sessions on 2026-08-10: 0.002 ms per session
            # when there is no sidecar (one stat, the common case on a fresh install)
            # and 0.080 ms when there is. That is under half what project_path's
            # content read costs, and unlike project_path this cannot be deferred —
            # bytes is eager, and a lazily-corrected byte total would leave `list`
            # printing one number while `du` summed another.
            def bytes_for(path, stat)
              stat.size + sidecar_bytes(path)
            end

            private

            # Not File.basename: the sidecar sits beside the transcript, so only the
            # extension comes off. A path with no extension leaves the name unchanged
            # and File.directory? then answers false for the transcript itself.
            #
            # SystemCallError, not a narrower list, and rescued rather than raised
            # for the reason Base#bytes_for's comment gives: this runs eagerly for
            # every session, so an unreadable sidecar must cost its own byte total
            # and nothing else. Missing bytes beat a missing session.
            def sidecar_bytes(path)
              sidecar = path.delete_suffix(File.extname(path))
              # readable? as well as directory?: Dir.glob answers [] for a directory
              # it cannot open, but warns while doing it under -w, which is how the
              # test suite runs. It does not cover an unreadable directory NESTED in
              # a readable sidecar — the rescue below is what covers that.
              return 0 unless File.directory?(sidecar) && File.readable?(sidecar)

              # FNM_DOTMATCH for Audit#bytes_under's reason: a total that quietly
              # omits dotfiles is worse than no total at all.
              Dir.glob(File.join(escape_glob(sidecar), "**", "*"), File::FNM_DOTMATCH).sum do |entry|
                File.file?(entry) ? File.size(entry) : 0
              end
            rescue SystemCallError
              0
            end

            def settings
              @settings ||= read_json(File.join(base_dir, "settings.json"))
            end

            def configured_retention
              value = settings["cleanupPeriodDays"]
              value if value.is_a?(Integer) && !value.negative?
            end
          end
        end
  end
end
