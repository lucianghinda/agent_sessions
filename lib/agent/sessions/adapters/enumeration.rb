# frozen_string_literal: true

module Agent
  module Sessions
        module Adapters
          # Layer 2: turning a resolved store into sessions. Split out of Base once it
          # held three concerns at 460 lines, and before Layer 3 readers add a fourth.
          #
          # Mixed into Base rather than included per adapter, so every adapter keeps
          # inheriting all of this and overriding the hooks it needs — the extraction
          # is a move, not a change in how an adapter is written.
          #
          # What this half needs from Layer 1 is deliberately small, and worth keeping
          # small: `primary_layer` (the store to enumerate and the format to stamp on
          # each session) and the class-level DSL readers `agent_name` and
          # `fidelity_value`. Nothing here resolves a path, reads an env override, or
          # touches @env. A method that needs to do any of those belongs in Base.
          module Enumeration
            # Caps how many bytes one iteration of a JSONL scan may pull into memory.
            # "One line" is not a bounded quantity on disk: a record carrying a pasted
            # file or a base64 image is routinely tens of MB, and a truncated file may
            # hold no newline at all. An over-long line arrives as chunks of this size,
            # which fail to parse and are skipped, so the scan gives up rather than
            # reading a 2.6 GB file into a single String.
            MAX_LINE_BYTES = 1_000_000

            # Lazily enumerates the primary store. Each consumed session costs one stat
            # plus filename parsing — never a content read. project_path is the exception
            # and pays for itself on first access.
            #
            # A store the gem has no layout for is refused rather than reported empty:
            # Location#enumerable? exists precisely so "nothing here to enumerate" and
            # "enumerated, found none" stay distinguishable, and silently returning no
            # sessions is this gem's worst failure mode.
            def sessions
              unless primary_layer.enumerable?
                raise Error, "#{self.class.agent_name} store #{primary_layer.kind} at " \
                             "#{primary_layer.path} has no known layout to enumerate"
              end

              enumerate(primary_layer.files)
            end

            # Match by RECORDED cwd, exact, per session (design doc section 7,
            # revised 2026-08-05 — the third design for this method, kept honest
            # here because the next reader deserves to know why it is not "cheap").
            # The first two designs were built and disproved against a real store,
            # not in theory:
            #
            #   1. Directory-name matching (the original design) assumed a
            #      session's parent directory equals encode(its own recorded cwd).
            #      A project rename breaks that: the agent keeps writing under the
            #      OLD encoded directory, so two directories can hold live sessions
            #      for the SAME current cwd, and name-only matching silently
            #      dropped the stale one — false negatives, the failure mode this
            #      gem treats as worst (decision 11).
            #
            #   2. One-read-per-directory sampling (the first fix for #1) assumed
            #      sessions within a directory share a cwd, to keep the match
            #      sublinear. Reading a real renamed project's stale directory
            #      disproved that: two of its three sessions had been resumed after
            #      the rename and recorded the NEW cwd; the third was never resumed
            #      and still recorded the OLD one. Sampling one session and
            #      applying its verdict to the whole directory is wrong in BOTH
            #      directions on the same store — it invented a false positive
            #      here, and a different glob order would just as easily have
            #      reproduced #1's false negative for that same directory.
            #      Approximate cwd resolution doesn't make the error smaller; it
            #      just moves where it lands.
            #
            # Measured cost of reading every session instead of sampling: 0.17 ms
            # per session (68 real Claude sessions, full sweep, 0.012s total) — 0.7s
            # extrapolated to a 4,000-session store. That is what the sampling
            # complexity was buying, and it is not a trade worth making: the
            # enumerator is already lazy, so a caller taking first(n) never pays
            # for sessions it never asked about, and even the worst case (every
            # session checked, no match) stays under a second on a store two
            # orders of magnitude larger than anything observed.
            #
            # A session whose own cwd cannot be read (the scan gave up, the file is
            # unreadable, the adapter declares no reader) falls back to comparing
            # ITS OWN directory's name against the encoding, when the adapter
            # declares one — this is the only thing encode_project still buys: it
            # keeps a session with an unreadable header from becoming invisible,
            # without resolving an unknown project for every other session that
            # happens to share its directory.
            def sessions_for_project(dir)
              dir = File.expand_path(dir)
              encoded = encode_project(dir)
              sessions.select do |session|
                # expand_path does not resolve symlinks, so a cwd recorded as
                # /private/tmp/x will not match a caller's /tmp/x on macOS.
                # Deliberate: realpath would cost a stat per comparison to fix a
                # rare mismatch.
                cwd = session.project_path
                next cwd == dir unless cwd.nil?

                encoded && project_dir_name(session.path) == encoded
              end
            end

            # Distinct recorded project paths, sorted. This is the read-everything
            # direction (design doc section 7): the encodings cannot be reversed, so the
            # recorded cwd inside each file is the only reliable source. Sessions whose
            # project cannot be determined are excluded, not returned as nil.
            #
            # Sorted rather than left in glob order because a stable order is what makes
            # `projects` output diffable and `du --by project` deterministic — and
            # adapters answering from a database would otherwise impose their own.
            def project_paths
              sessions.filter_map(&:project_path).uniq.force.sort
            end

            # --- Layer 2 hooks, overridable per adapter ---

            def session_id_from(path)
              File.basename(path, ".*")
            end

            # nil means this adapter has no directory-name fallback rule. Used only
            # by sessions_for_project, and only for a session whose own recorded
            # cwd could not be read. When overridden: dir arrives pre-expanded here
            # from sessions_for_project (File.expand_path), which is the
            # precondition an override may rely on — a direct caller must pass an
            # absolute, expanded path itself, or the encoding is nonsense ("app",
            # "~/app", and a trailing slash all encode differently from the
            # canonical form real project directories were named from).
            def encode_project(_dir) = nil

            # The directory whose name the encoding must match, when
            # sessions_for_project falls back to it. Overridable: not every store
            # puts the encoded project directly above the session file — cursor_ide
            # nests projects/<name>/agent-transcripts/*, where the immediate parent
            # is agent-transcripts and matching it would find nothing, silently.
            def project_dir_name(path) = File.basename(File.dirname(path))

            # nil means the project is unknown for this session. Adapters override
            # with a bounded read of their own metadata; Base cannot guess.
            def project_path_for(_path) = nil

            # Both time hooks take the stat the enumerator already holds, so a session
            # still costs one syscall. path is passed for adapters that answer from a
            # sibling metadata file instead.
            #
            # nil beats a wrong guess when the filesystem cannot answer at all — and it
            # says so through ENOSYS/EPERM from statx as often as NotImplementedError.
            def started_at_for(_path, stat)
              stat.birthtime
            rescue NotImplementedError, SystemCallError
              nil
            end

            def updated_at_for(_path, stat) = stat.mtime

            # Bytes this session occupies on disk. The transcript alone for a store
            # that keeps one file per session; an adapter whose agent writes sidecar
            # files beside the transcript overrides this and adds them. Like the two
            # time hooks it takes the stat the enumerator already holds, so the
            # common case still costs nothing beyond the syscall already made.
            #
            # An override runs EAGERLY for every session, so it carries build_session's
            # constraint: it must not raise on an unreadable path, or one bad sidecar
            # takes down the whole listing rather than its own row.
            def bytes_for(_path, stat) = stat.size

            private

            # Turns paths into sessions, lazily. Extracted so an adapter whose agent
            # writes sessions to more than one store can enumerate the others without
            # copying `sessions`' guard clause — see Codex, which chains its archived
            # store onto this. The glob behind `paths` has already run; what stays
            # lazy is the stat and the hooks, which is where the per-session cost is.
            def enumerate(paths)
              paths.lazy.filter_map { |path| build_session(path) }
            end

            # nil drops the session from the enumeration. A file that vanished between
            # the glob and its stat is one fewer session, not an error: enumeration is
            # lazy, so that window spans the whole listing, and agents rotate and
            # compact these logs while a caller is still reading them.
            #
            # The rescue covers the stat and nothing else. Wrapping the hooks too would
            # mean an adapter whose started_at_for raised EACCES silently returned zero
            # sessions — a misdeclared adapter erasing a listing rather than failing.
            # A hook that raises is a programming error and surfaces, matching `all`.
            #
            # SystemCallError, not just ENOENT/EACCES, for the same reason
            # started_at_for's own rescue already widened past those two (see its
            # comment) and read_json's did too: the FILE this stats can itself be a
            # symlink loop (ELOOP) or TCC-denied (EPERM on macOS), not only vanished
            # or permission-denied in the two ways originally listed.
            def build_session(path)
              stat = File.stat(path)
            rescue SystemCallError
              nil
            else
              Session.new(
                agent: self.class.agent_name,
                id: session_id_from(path),
                path: path,
                started_at: started_at_for(path, stat),
                updated_at: updated_at_for(path, stat),
                bytes: bytes_for(path, stat),
                format: primary_layer.format,
                fidelity: self.class.fidelity_value
              ) { project_path_for(path) }
            end

            # Streams a JSONL file looking for a record carrying `key`. Bounded twice
            # over — `limit` caps the iterations, MAX_LINE_BYTES caps each read — so the
            # worst case is a few tens of MB even for a file with no newlines in it.
            # Tolerant of the non-JSON lines and non-object records real logs contain:
            # a scan that gives up is worth more here than one that raises.
            #
            # Presence of `key` alone is not "found": a record can carry it with a
            # null or wrong-typed value, which would otherwise stop the scan and
            # permanently shadow a later, usable record — or hand a caller a Hash
            # where it expected a String, which is exactly what turns project_paths'
            # .uniq.sort into an ArgumentError from one malformed record. An optional
            # block is the value check, evaluated only once presence already holds;
            # it defaults to accepting whatever presence accepted, so a caller with
            # no block sees no behavior change.
            def scan_jsonl_for_key(path, key, limit: 25)
              File.foreach(path, "\n", MAX_LINE_BYTES).with_index do |line, index|
                break if index >= limit

                begin
                  record = JSON.parse(line)
                rescue JSON::ParserError, EncodingError
                  next
                end
                next unless record.is_a?(Hash) && record.key?(key)
                next if block_given? && !yield(record)

                return record
              end
              nil
            # SystemCallError, matching read_json and build_session. The enumerated
            # Errno list this replaced missed EPERM, which is what macOS returns for a
            # TCC-protected path rather than EACCES, and ELOOP. The exposure here is
            # narrower than read_json's — build_session stats the session file first and
            # drops it on any SystemCallError, so a file that fails outright never
            # reaches this — but a file that stats cleanly and then fails on read does,
            # and the three rescues disagreeing on which errnos count is the kind of
            # inconsistency that becomes a bug the moment one of them moves.
            rescue SystemCallError
              nil
            end
          end
        end
  end
end
