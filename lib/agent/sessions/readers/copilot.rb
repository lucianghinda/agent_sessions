# frozen_string_literal: true

module Agent
  module Sessions
        module Readers
          # GitHub Copilot CLI turns, from the SQLite store the adapter enumerates.
          #
          # The SCHEMA is verified (schema_version 3 on this machine, 2026-08-24):
          # turns holds id, session_id, turn_index, user_message, assistant_response,
          # timestamp. The CONTENT is not — the one real session here has zero turn
          # rows, so no turn has ever been read. The column names are unambiguous
          # enough to map without guessing at structure, which is why this reader
          # exists at all rather than waiting; what it cannot promise is that a real
          # turn holds plain text in those columns rather than, say, JSON.
          #
          # fidelity is :messages, not :full — one row is a whole exchange, so the
          # tool calls and reasoning that happened inside it are not recoverable
          # from this table. What a caller gets is what was said, not how.
          class Copilot < Base
            # One row is a user turn AND the assistant's reply, so each row yields
            # two messages. They share a raw record: rule 1 keeps the row intact,
            # and splitting it into two half-rows would misreport what was stored.
            def each_message
              return enum_for(:each_message) unless block_given?

              each_record do |record, _index|
                user = record["user_message"]
                yield build(record, :user, user) if usable?(user)
                reply = record["assistant_response"]
                yield build(record, :assistant, reply) if usable?(reply)
              end
            end

            # No token or cost column exists anywhere in this schema — not on
            # sessions, not on turns. nil is the format speaking, and must not be
            # mistaken for a session that cost nothing.
            def usage = nil

            private

            def usable?(value) = value.is_a?(String) && !value.empty?

            def build(record, role, text)
              Message.new(role: role, at: time_from(record["timestamp"]), parts: [Part.new(type: :text, text: text)],
                          raw: record, usage: nil, model: nil)
            end

            # Rows ordered by turn_index, the column that exists precisely to say
            # what order they happened in; id is the tiebreak so a store with
            # repeated indices still reads deterministically.
            def each_record
              require_sqlite!
              db = nil
              index = 0
              begin
                db = Sqlite.open_readonly(session.path)
                db.execute("SELECT user_message, assistant_response, timestamp, turn_index " \
                           "FROM turns WHERE session_id = ? ORDER BY turn_index, id", [session.id]) do |row|
                  index += 1
                  user, reply, timestamp, turn_index = row
                  yield({ "user_message" => user, "assistant_response" => reply,
                          "timestamp" => timestamp, "turn_index" => turn_index }, index)
                end
              rescue SQLite3::Exception => e
                warn_about("#{session.path} could not be read (#{e.class.name.split("::").last})")
              ensure
                db&.close
              end
            end

            def require_sqlite!
              require "sqlite3"
            rescue LoadError
              raise MissingDependency,
                    "Copilot CLI turns live in session-store.db (SQLite); add the sqlite3 gem to read them"
            end
          end
        end
  end
end
