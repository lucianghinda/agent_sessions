# frozen_string_literal: true

module AgentSessions
  module Adapters
    # GitHub Copilot CLI. Verified against a real store on this machine
    # (2026-08-24): ~/.copilot/session-store.db, schema_version 3, one session.
    #
    # This store has MOVED since tokentelemetry's parser was written against
    # it: that reads ~/.copilot/session-state/<id>/events.jsonl, and no such
    # file exists here. The session-state/<id>/ directory does still exist as
    # a companion (workspace.yaml, checkpoints/, files/, research/), but the
    # session record itself is now a row in SQLite. An adapter following the
    # older spec would report nothing on a current install — the failure this
    # gem's `verified_on` dates exist to make visible.
    class Copilot < Base
      agent :copilot
      label "GitHub Copilot CLI"
      documented false
      verified_on "2026-08-24"
      fidelity :messages

      def self.reader_class = Readers::Copilot

      base_dir default: "~/.copilot"

      store :database, path: "session-store.db", format: :sqlite
      store :session_state, dir: "session-state", format: :json, optional: true

      warning "token usage is not recorded in this store: the sessions and turns tables carry " \
              "no token or cost columns, so `usage` is nil for every Copilot session"

      # created_at/updated_at are ISO 8601 strings here, not the epoch
      # milliseconds opencode and Cursor use — verified against a real row
      # ("2026-05-26T04:36:01.288Z").
      SESSION_COLUMNS = "id, cwd, created_at, updated_at"

      def sessions
        db_path = primary_layer.path
        return [].lazy unless File.exist?(db_path)

        Enumerator.new do |yielder|
          each_session_row(db_path, "SELECT #{SESSION_COLUMNS} FROM sessions") do |row|
            yielder << build_row_session(db_path, row)
          end
        end.lazy
      end

      # cwd is a real column holding a real absolute path, so filtering is a
      # WHERE clause rather than a read-and-compare loop.
      def sessions_for_project(dir)
        dir = File.expand_path(dir)
        db_path = primary_layer.path
        return [].lazy unless File.exist?(db_path)

        Enumerator.new do |yielder|
          each_session_row(db_path, "SELECT #{SESSION_COLUMNS} FROM sessions WHERE cwd = ?", [dir]) do |row|
            yielder << build_row_session(db_path, row)
          end
        end.lazy
      end

      def project_paths
        db_path = primary_layer.path
        return [] unless File.exist?(db_path)

        paths = []
        each_session_row(db_path, "SELECT DISTINCT cwd FROM sessions ORDER BY cwd") do |row|
          paths << row.first if row.first.is_a?(String)
        end
        paths.uniq
      end

      private

      def build_row_session(db_path, row)
        id, cwd, created, updated = row
        Session.new(
          agent: self.class.agent_name, id: id, path: db_path,
          project_path: cwd.is_a?(String) ? cwd : nil,
          started_at: parse_time(created),
          updated_at: parse_time(updated) || parse_time(created) || db_mtime(db_path),
          bytes: nil, # a row in a shared database has no file size of its own
          format: primary_layer.format, fidelity: self.class.fidelity_value
        )
      end

      def parse_time(value)
        return nil unless value.is_a?(String)

        Time.iso8601(value)
      rescue ArgumentError
        nil
      end

      # updated_at is never nil across adapters; see opencode's db_mtime for
      # the full reasoning. Reached only when both timestamps are unusable.
      def db_mtime(db_path)
        @db_mtime ||= begin
          File.mtime(db_path)
        rescue SystemCallError
          Time.now
        end
      end

      def each_session_row(db_path, sql, params = [], &block)
        require_sqlite!
        db = nil
        begin
          db = Sqlite.open_readonly(db_path)
          db.execute(sql, params, &block)
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
              "Copilot CLI sessions live in session-store.db (SQLite); add the sqlite3 gem to enumerate them"
      end
    end
  end
end
