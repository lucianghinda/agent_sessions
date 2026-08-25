# frozen_string_literal: true

require_relative "test_helper"
require "sqlite3"

# Shapes from the real store on this machine (2026-08-24): schema_version 3,
# one session row with a real cwd, an empty turns table. This store has MOVED
# since tokentelemetry's parser was written against it — that reads
# session-state/<id>/events.jsonl, which does not exist on a current install.
class CopilotAdapterTest < Minitest::Test
  include AdapterConformance

  def adapter_class = AgentSessions::Adapters::Copilot

  def build_fixture(home)
    build_db(home, [[SESSION, "/Users/you/app", CREATED, UPDATED]])
  end

  def expected_default_path(home) = File.join(home, ".copilot", "session-store.db")

  def override_env = nil

  def expected_session_id = SESSION
  def expected_project_path = "/Users/you/app"

  # ISO 8601 strings, not the epoch milliseconds opencode and Cursor use.
  def test_timestamps_are_parsed_as_iso8601
    with_home do |home, env|
      build_fixture(home)
      session = AgentSessions.sessions(:copilot, env: env).first
      # Compared against the parsed value, not a Time.utc with float seconds:
      # 1.288 becomes a Rational there and does not compare equal to the
      # millisecond Time.iso8601 produces.
      assert_equal Time.iso8601(CREATED), session.started_at
      assert_equal Time.iso8601(UPDATED), session.updated_at
      assert_equal 2026, session.started_at.utc.year
      assert_nil session.bytes, "a row in a shared database has no file size of its own"
    end
  end

  def test_an_unparseable_timestamp_still_leaves_an_updated_at
    with_home do |home, env|
      build_db(home, [[SESSION, "/Users/you/app", "not a time", "also not a time"]])
      session = AgentSessions.sessions(:copilot, env: env).first
      assert_nil session.started_at
      refute_nil session.updated_at
    end
  end

  def test_the_store_is_a_single_sqlite_file
    with_home do |_home, env|
      store = AgentSessions.locate(:copilot, env: env)
      assert_equal :sqlite, store.format
      assert_predicate store.effective, :single_file
    end
  end

  # No token or cost column exists anywhere in this schema, so the adapter
  # says so rather than letting a caller read nil as zero.
  def test_absent_token_usage_is_declared
    with_home do |_home, env|
      assert(AgentSessions.locate(:copilot, env: env).warnings.any? { |w| w.include?("token usage") })
    end
  end

  def test_a_reader_over_an_empty_turns_table_yields_nothing_without_warning
    with_home do |home, env|
      build_fixture(home)
      reader = AgentSessions.read(AgentSessions.sessions(:copilot, env: env).first)
      assert_empty reader.messages
      assert_empty reader.warnings
      assert_nil reader.usage
    end
  end

  # One turns row is a whole exchange — the user's message and the reply — so
  # it becomes two messages sharing one raw record.
  def test_one_turn_row_becomes_a_user_and_an_assistant_message
    with_home do |home, env|
      build_fixture(home)
      insert_turn(home, turn_index: 0, user: "hello", reply: "hi there")
      reader = AgentSessions.read(AgentSessions.sessions(:copilot, env: env).first)
      assert_equal %i[user assistant], reader.messages.map(&:role)
      assert_equal ["hello", "hi there"], reader.messages.map(&:text)
      assert_equal reader.messages.first.raw, reader.messages.last.raw
    end
  end

  def test_turns_are_ordered_by_turn_index
    with_home do |home, env|
      build_fixture(home)
      insert_turn(home, turn_index: 1, user: "second", reply: nil)
      insert_turn(home, turn_index: 0, user: "first", reply: nil)
      reader = AgentSessions.read(AgentSessions.sessions(:copilot, env: env).first)
      assert_equal %w[first second], reader.messages.map(&:text)
    end
  end

  # A turn still running has no reply yet; an empty assistant message would
  # claim it answered.
  def test_a_turn_without_a_reply_yields_only_the_user_message
    with_home do |home, env|
      build_fixture(home)
      insert_turn(home, turn_index: 0, user: "hello", reply: "")
      reader = AgentSessions.read(AgentSessions.sessions(:copilot, env: env).first)
      assert_equal [:user], reader.messages.map(&:role)
    end
  end

  private

  SESSION = "c7d32f3c-deca-4fb5-8377-a909aa3ecc30"
  CREATED = "2026-05-26T04:36:01.288Z"
  UPDATED = "2026-05-26T04:36:07.680Z"

  def db_path(home) = File.join(home, ".copilot", "session-store.db")

  def build_db(home, rows)
    path = db_path(home)
    FileUtils.mkdir_p(File.dirname(path))
    db = SQLite3::Database.new(path)
    db.execute("CREATE TABLE sessions (id TEXT PRIMARY KEY, cwd TEXT, repository TEXT, " \
               "host_type TEXT, branch TEXT, summary TEXT, created_at TEXT, updated_at TEXT)")
    db.execute("CREATE TABLE turns (id INTEGER PRIMARY KEY, session_id TEXT, turn_index INTEGER, " \
               "user_message TEXT, assistant_response TEXT, timestamp TEXT)")
    rows.each do |id, cwd, created, updated|
      db.execute("INSERT INTO sessions (id, cwd, created_at, updated_at) VALUES (?, ?, ?, ?)",
                 [id, cwd, created, updated])
    end
    path
  ensure
    db&.close
  end

  def insert_turn(home, turn_index:, user:, reply:)
    db = SQLite3::Database.new(db_path(home))
    db.execute("INSERT INTO turns (session_id, turn_index, user_message, assistant_response, timestamp) " \
               "VALUES (?, ?, ?, ?, ?)", [SESSION, turn_index, user, reply, CREATED])
  ensure
    db&.close
  end
end
