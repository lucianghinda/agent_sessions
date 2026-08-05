# frozen_string_literal: true

require_relative "test_helper"
require "sqlite3"

class OpencodeAdapterTest < Minitest::Test
  include AdapterConformance

  def adapter_class = AgentSessions::Adapters::Opencode

  # A real database, not an empty file: Layer 2 queries it. Only the columns the
  # adapter SELECTs are declared; the real table has more (verified 2026-08-05).
  def build_fixture(home)
    build_db(home, [["ses_fixture01", "/Users/you/app", 1_752_484_323_000, 1_752_490_000_000]])
  end

  def build_db(home, rows)
    path = File.join(home, ".local", "share", "opencode", "opencode.db")
    FileUtils.mkdir_p(File.dirname(path))
    db = SQLite3::Database.new(path)
    db.execute(<<~SQL)
      CREATE TABLE session (
        id TEXT PRIMARY KEY, directory TEXT NOT NULL,
        time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL
      )
    SQL
    rows.each { |row| db.execute("INSERT INTO session VALUES (?, ?, ?, ?)", row) }
    path
  ensure
    db&.close
  end

  # No NOT NULL, no declared type: a permissive schema for rows shaped the way
  # a DIFFERENT sqlite3 build than the one this test process links against
  # could still produce — an older SQLite's ALTER TABLE ADD COLUMN NOT NULL
  # quirk leaving existing rows NULL despite the constraint, or a value that
  # already overflowed to Infinity at INSERT time under REAL affinity
  # (confirmed directly: INSERT INTO t VALUES (10**400) stores Infinity, not
  # an error, even under this test's own 3.53.2 library). The reader (the
  # adapter) cannot assume the writer enforced what its own schema declares,
  # so these tests build rows the declared schema in build_db would normally
  # prevent, on purpose.
  def build_malformed_db(home, rows)
    path = File.join(home, ".local", "share", "opencode", "opencode.db")
    FileUtils.mkdir_p(File.dirname(path))
    db = SQLite3::Database.new(path)
    db.execute("CREATE TABLE session (id TEXT PRIMARY KEY, directory, time_created, time_updated)")
    rows.each { |row| db.execute("INSERT INTO session VALUES (?, ?, ?, ?)", row) }
    path
  ensure
    db&.close
  end

  def expected_session_id = "ses_fixture01"
  def expected_project_path = "/Users/you/app"

  def expected_default_path(home) = File.join(home, ".local", "share", "opencode", "opencode.db")

  def override_env = { "XDG_DATA_HOME" => "/xdg/data" }
  def expected_override_path = "/xdg/data/opencode/opencode.db"

  def test_database_is_sqlite_format
    with_home do |_home, env|
      assert_equal :sqlite, AgentSessions.locate(:opencode, env: env).format
    end
  end

  def test_legacy_storage_tree_is_a_separate_optional_layer
    with_home do |_home, env|
      store = AgentSessions.locate(:opencode, env: env)
      legacy = store.layers.find { |l| l.kind == :legacy }
      refute_nil legacy
      assert_equal :json, legacy.format
    end
  end

  def test_sessions_carry_db_timestamps_and_no_bytes
    with_home do |home, env|
      build_fixture(home)
      session = AgentSessions::Adapters::Opencode.new(env: env).sessions.first
      assert_equal Time.at(1_752_484_323_000 / 1000.0), session.started_at
      assert_equal Time.at(1_752_490_000_000 / 1000.0), session.updated_at
      assert_nil session.bytes # rows in a shared database have no file size
      assert_equal :full, session.fidelity
    end
  end

  def test_for_project_filters_in_sql
    with_home do |home, env|
      build_db(home, [["ses_a", "/Users/you/app", 1, 2], ["ses_b", "/Users/you/other", 3, 4]])
      found = AgentSessions::Adapters::Opencode.new(env: env).sessions_for_project("/Users/you/app").force
      assert_equal ["ses_a"], found.map(&:id)
    end
  end

  def test_project_paths_are_distinct_directories
    with_home do |home, env|
      build_db(home, [["ses_a", "/Users/you/app", 1, 2], ["ses_b", "/Users/you/app", 3, 4],
                      ["ses_c", "/Users/you/other", 5, 6]])
      assert_equal ["/Users/you/app", "/Users/you/other"],
                   AgentSessions::Adapters::Opencode.new(env: env).project_paths
    end
  end

  def test_a_corrupt_database_raises_unreadable_store
    with_home do |home, env|
      write("not a database", home, ".local", "share", "opencode", "opencode.db")
      assert_raises(AgentSessions::UnreadableStore) do
        AgentSessions::Adapters::Opencode.new(env: env).sessions.force
      end
    end
  end

  def test_absence_never_requires_sqlite
    with_home do |_home, env|
      assert_empty AgentSessions::Adapters::Opencode.new(env: env).sessions.force
    end
  end

  # --- Malformed-shape guards -------------------------------------------------
  # Mirrors Cursor's own section by the same name (rules 1 and 2): NOT NULL and
  # INTEGER/TEXT affinity are declarations a writer is expected to honor, not
  # guarantees this reader gets to assume. One fixture per case, same as
  # Cursor's, because session_time and build_db_session's directory guard are
  # both centralized rather than duplicated per caller.

  def test_a_non_numeric_created_at_falls_back_to_nil_without_crashing_the_listing
    with_home do |home, env|
      build_malformed_db(home, [["ses_bad", "/Users/you/app", "not-a-number", 2]])
      sessions = AgentSessions::Adapters::Opencode.new(env: env).sessions.force
      assert_equal 1, sessions.size, "expected the listing to survive a non-numeric time_created"
      assert_nil sessions.first.started_at
    end
  end

  # 10**400 already overflows to Float::INFINITY at SQLite's own INSERT time
  # (REAL affinity, confirmed directly), a different route than Cursor's
  # createdAtMs bignum (which stays an exact Integer until Ruby's own
  # `/ 1000.0` overflows it) — same crash, caught by the same finite? guard.
  # silence_warnings wraps the bind step: binding a 400-digit Integer through
  # the sqlite3 gem narrates "Integer out of Float range" under Ruby's -w,
  # the same overflow this test targets, at a different point than Cursor's
  # identical silence_warnings (JSON's own Float() call) — informative once,
  # noise on every subsequent run once the guard it exists to prove is in
  # place. Mirrors Cursor's comment on its own two callers.
  def test_a_timestamp_that_already_overflowed_to_infinity_does_not_crash
    with_home do |home, env|
      silence_warnings { build_malformed_db(home, [["ses_huge", "/Users/you/app", 10**400, 2]]) }
      sessions = AgentSessions::Adapters::Opencode.new(env: env).sessions.force
      assert_equal 1, sessions.size, "expected the listing to survive an already-Infinity time_created"
      assert_nil sessions.first.started_at
    end
  end

  def test_a_null_directory_yields_a_nil_project_path_and_is_excluded_from_project_paths
    with_home do |home, env|
      build_malformed_db(home, [["ses_null_dir", nil, 1, 2], ["ses_ok", "/Users/you/app", 3, 4]])
      adapter = AgentSessions::Adapters::Opencode.new(env: env)
      sessions = adapter.sessions.force
      assert_equal 2, sessions.size, "expected the listing to survive a NULL directory"
      null_dir_session = sessions.find { |s| s.id == "ses_null_dir" }
      assert_nil null_dir_session.project_path
      assert_equal ["/Users/you/app"], adapter.project_paths
    end
  end

  private

  def silence_warnings
    original = $VERBOSE
    $VERBOSE = nil
    yield
  ensure
    $VERBOSE = original
  end
end
