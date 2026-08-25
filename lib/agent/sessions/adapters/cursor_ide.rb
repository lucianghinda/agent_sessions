# frozen_string_literal: true

module Agent
  module Sessions
        module Adapters
          # Cursor's IDE agent (Composer). Repointed 2026-08-24 at the store the
          # 0.2 adapter's own warning named as the real one, now that it has been
          # opened rather than inferred: ~/Library/Application Support/Cursor/User/
          # globalStorage/state.vscdb, table cursorDiskKV, keys composerData:<uuid>
          # — 6 real rows on the machine this was written on. The 0.2 declaration
          # (~/.cursor/projects/*/agent-transcripts/*) does not exist there at all,
          # so this adapter reported nothing for an agent that had sessions.
          #
          # What is verified: the file, the table, the key prefix, and the record's
          # own composerId/createdAt. What is NOT: anything about the conversation
          # itself — all six records on this machine carry "conversation": [], so
          # the shape of a turn has never been seen here. fidelity stays :metadata
          # and no reader exists, which is the honest report: this adapter can say
          # a session happened and when, and must not pretend to say what was said.
          class CursorIde < Base
            agent :cursor_ide
            label "Cursor IDE"
            documented false
            verified_on "2026-08-24"
            fidelity :metadata

            homedir :cursor_ide, join: "User/globalStorage"

            store :database, path: "state.vscdb", format: :sqlite

            warning "the IDE composer store does not sync with the CLI chat store"
            warning "session content is not read: every composerData record seen carried an " \
                    "empty conversation, so the turn format remains unverified"

            KEY_PREFIX = "composerData:"

            # Rows, not files, so Base's glob enumeration is replaced the way
            # opencode's is — including the existence check FIRST, so a machine
            # without Cursor never needs the sqlite3 gem at all.
            #
            # value is parsed for createdAt alone. It is the whole composer document
            # (context, capabilities, code blocks), which is why `bytes` stays nil:
            # a row in a shared database has no file size of its own, and the
            # database's size belongs to all 7 rows together.
            def sessions
              db_path = primary_layer.path
              return [].lazy unless File.exist?(db_path)

              Enumerator.new do |yielder|
                each_composer_row(db_path) do |key, value|
                  yielder << build_row_session(db_path, key, value)
                end
              end.lazy
            end

            # Cursor's composer records do not name a project. context.fileSelections
            # holds paths of files ATTACHED to a turn — on this machine, a settings
            # file from an unrelated directory — and a workspace root inferred from
            # one attachment would be a guess dressed as a fact. nil is the honest
            # answer, and `projects` reporting nothing for this agent is correct
            # rather than empty-looking.
            def project_path_for(_path) = nil

            def project_paths = []

            def sessions_for_project(_dir) = [].lazy

            private

            def build_row_session(db_path, key, value)
              created = parse_created_at(value)
              Session.new(
                agent: self.class.agent_name, id: key.delete_prefix(KEY_PREFIX), path: db_path,
                project_path: nil, started_at: created,
                updated_at: created || db_mtime(db_path), bytes: nil,
                format: primary_layer.format, fidelity: self.class.fidelity_value
              )
            end

            # createdAt is epoch milliseconds (1776161422165 in real rows). The
            # guards are opencode's, for the identical failures: a non-Numeric value
            # is nil rather than a wrong time, and a huge-but-real Integer that
            # overflows to Infinity once divided must never reach Time.at, which
            # raises FloatDomainError and would take the whole listing down.
            def parse_created_at(value)
              millis = read_json_value(value)["createdAt"]
              return nil unless millis.is_a?(Numeric)

              seconds = millis / 1000.0
              Time.at(seconds) if seconds.finite?
            end

            def read_json_value(value)
              parsed = JSON.parse(value.to_s)
              parsed.is_a?(Hash) ? parsed : {}
            rescue JSON::ParserError, TypeError
              {}
            end

            # updated_at may never be nil (the cross-adapter invariant `since` and
            # every sort rely on), and a composer record carries no updated
            # timestamp at all — only createdAt. The database file's own mtime is
            # not this session's time, but it is a true upper bound on when anything
            # in the store last changed, and it is reached only when createdAt is
            # missing or malformed.
            def db_mtime(db_path)
              @db_mtime ||= begin
                File.mtime(db_path)
              rescue SystemCallError
                Time.now
              end
            end

            def each_composer_row(db_path, &block)
              require_sqlite!
              db = nil
              begin
                db = Sqlite.open_readonly(db_path)
                db.execute("SELECT key, value FROM cursorDiskKV WHERE key LIKE ?", ["#{KEY_PREFIX}%"], &block)
              rescue SQLite3::Exception => e
                raise UnreadableStore, "#{db_path}: #{e.message}"
              ensure
                db&.close
              end
            end

            def require_sqlite!
              require "sqlite3"
            rescue LoadError
              raise MissingDependency,
                    "Cursor IDE sessions live in state.vscdb (SQLite); add the sqlite3 gem to enumerate them"
            end
          end
        end
  end
end
