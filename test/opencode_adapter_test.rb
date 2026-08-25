# frozen_string_literal: true

require_relative "test_helper"
require "sqlite3"

class OpencodeAdapterTest < Minitest::Test
  include AdapterConformance

  def adapter_class = Agent::Sessions::Adapters::Opencode

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
    build_raw_db(File.join(home, ".local", "share", "opencode", "opencode.db"), rows)
  end

  # Builds a session table at an EXACT path, rather than deriving one from a
  # HOME root the way build_db/build_malformed_db do — needed whenever the
  # fixture under test is the PATH itself (a directory named with a
  # percent-escape sequence, say), not the usual HOME-relative default
  # layout. Uses the same permissive, undeclared-type schema as
  # build_malformed_db, since every caller of this needs raw SQL literal
  # inserts (X'...' blobs) that a bound Ruby value could not produce.
  def build_raw_db(path, rows)
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
      assert_equal :sqlite, Agent::Sessions.locate(:opencode, env: env).format
    end
  end

  def test_legacy_storage_tree_is_a_separate_optional_layer
    with_home do |_home, env|
      store = Agent::Sessions.locate(:opencode, env: env)
      legacy = store.layers.find { |l| l.kind == :legacy }
      refute_nil legacy
      assert_equal :json, legacy.format
    end
  end

  def test_sessions_carry_db_timestamps_and_no_bytes
    with_home do |home, env|
      build_fixture(home)
      session = Agent::Sessions::Adapters::Opencode.new(env: env).sessions.first
      assert_equal Time.at(1_752_484_323_000 / 1000.0), session.started_at
      assert_equal Time.at(1_752_490_000_000 / 1000.0), session.updated_at
      assert_nil session.bytes # rows in a shared database have no file size
      assert_equal :full, session.fidelity
    end
  end

  def test_for_project_filters_in_sql
    with_home do |home, env|
      build_db(home, [["ses_a", "/Users/you/app", 1, 2], ["ses_b", "/Users/you/other", 3, 4]])
      found = Agent::Sessions::Adapters::Opencode.new(env: env).sessions_for_project("/Users/you/app").force
      assert_equal ["ses_a"], found.map(&:id)
    end
  end

  # Inserted out of alphabetical order on purpose: build_db's earlier fixture
  # (app, app, other) happened to already be sorted, so a mutation deleting
  # "ORDER BY directory" from the adapter's SQL would have survived — SQLite's
  # own scan order without ORDER BY still happened to match. Inserting "other"
  # first forces the assertion to depend on the ORDER BY actually running.
  def test_project_paths_are_distinct_directories
    with_home do |home, env|
      build_db(home, [["ses_c", "/Users/you/other", 5, 6], ["ses_a", "/Users/you/app", 1, 2],
                      ["ses_b", "/Users/you/app", 3, 4]])
      assert_equal ["/Users/you/app", "/Users/you/other"],
                   Agent::Sessions::Adapters::Opencode.new(env: env).project_paths
    end
  end

  # SQLite's DISTINCT treats a BLOB and a byte-identical TEXT value as
  # different rows (confirmed directly: typeof reports "text" vs "blob" for
  # the same bytes), even though the sqlite3 gem returns both to Ruby as
  # String — so without project_paths' own .uniq, this pair would surface as
  # two entries where Base's own `.uniq.sort` collapses the equivalent case
  # to one. X'...' is SQLite's blob literal syntax; unpack1("H*") computes the
  # matching hex directly from the text instead of hardcoding it.
  def test_project_paths_collapses_a_blob_and_text_row_with_identical_bytes
    with_home do |home, env|
      path = File.join(home, ".local", "share", "opencode", "opencode.db")
      build_raw_db(path, [["ses_text", "/Users/you/app", 1, 2]])
      db = SQLite3::Database.new(path)
      hex = "/Users/you/app".unpack1("H*")
      db.execute("INSERT INTO session VALUES ('ses_blob', X'#{hex}', 3, 4)")
      db.close

      assert_equal ["/Users/you/app"], Agent::Sessions::Adapters::Opencode.new(env: env).project_paths
    end
  end

  def test_a_corrupt_database_raises_unreadable_store
    with_home do |home, env|
      write("not a database", home, ".local", "share", "opencode", "opencode.db")
      assert_raises(Agent::Sessions::UnreadableStore) do
        Agent::Sessions::Adapters::Opencode.new(env: env).sessions.force
      end
    end
  end

  # Renamed from test_absence_never_requires_sqlite: that name promised more
  # than an in-process test can prove — require "sqlite3" at the top of this
  # file already loaded the library before any assertion here runs, so this
  # can only prove the three File.exist? guards return empty/no-raise, not
  # that sqlite3 was never required. The real claim is proven by a subprocess
  # below (test_absence_never_requires_sqlite_in_a_clean_process). What THIS
  # test catches instead: a mutation deleting the guard on sessions_for_project
  # or project_paths specifically — both survived the suite before this was
  # split out, because the guard on `sessions` alone happened to cover the one
  # existing assertion. That matters beyond opencode: Task 9's for_project
  # sweeps all seven adapters, and on a machine without opencode these guards
  # are the only thing standing between an absent agent and an UnreadableStore
  # raised while trying to enumerate a store that isn't there.
  def test_absence_returns_empty_or_no_sessions_from_every_public_method
    with_home do |_home, env|
      adapter = Agent::Sessions::Adapters::Opencode.new(env: env)
      assert_empty adapter.sessions.force
      assert_empty adapter.sessions_for_project("/Users/you/app").force
      assert_empty adapter.project_paths
    end
  end

  # --- Cross-process proofs ----------------------------------------------
  # require "sqlite3" at the top of this file means the SQLite3 constant is
  # already resolved for the rest of THIS process — mirrors test/no_network_
  # test.rb's own note that its equivalent $LOADED_FEATURES check "needs a
  # clean process". These two shell out to one, the way that test does not
  # need to (nothing else in the suite ever touches net/http, so no fixture
  # anywhere contaminates it the way build_fixture's own sqlite3 requirement
  # contaminates this file for opencode specifically).

  def run_in_subprocess(body)
    require "open3"
    lib_path = File.expand_path("../lib", __dir__)
    preamble = "$LOAD_PATH.unshift #{lib_path.inspect}\nrequire \"agent_sessions\"\n"
    Open3.capture2(RbConfig.ruby, "-e", preamble + body)
  end

  def test_absence_never_requires_sqlite_in_a_clean_process
    out, status = run_in_subprocess(<<~RUBY)
      require "tmpdir"
      Dir.mktmpdir do |home|
        sessions = Agent::Sessions::Adapters::Opencode.new(env: { "HOME" => home }).sessions.force
        raise "expected no sessions" unless sessions.empty?
        raise "sqlite3 was loaded" if $LOADED_FEATURES.any? { |f| f.include?("sqlite3") }
      end
      puts "OK"
    RUBY
    assert status.success?, "subprocess crashed: #{out}"
    assert_equal "OK", out.strip
  end

  # Also proves require_sqlite! is still OUTSIDE each_session_row's
  # begin/rescue: if it were moved inside (a real mutation tried during
  # review), the SQLite3 constant would never have been defined in this
  # fresh process, and Ruby resolving `rescue SQLite3::Exception` while
  # unwinding the raised MissingDependency would itself raise
  # "NameError: uninitialized constant ...::SQLite3" instead — confirmed
  # directly by making that exact change and rerunning this body. Likewise
  # catches deleting the `rescue LoadError` branch entirely, which would let
  # a bare LoadError escape instead of MissingDependency. Both mutations
  # print something other than MISSING_DEPENDENCY below.
  def test_a_missing_sqlite3_gem_raises_missing_dependency_not_load_error_or_name_error
    out, status = run_in_subprocess(<<~RUBY)
      module Kernel
        alias_method :__real_require, :require
        def require(name)
          raise LoadError, "cannot load such file -- sqlite3" if name == "sqlite3"
          __real_require(name)
        end
      end

      require "tmpdir"
      require "fileutils"
      Dir.mktmpdir do |home|
        db_path = File.join(home, ".local", "share", "opencode", "opencode.db")
        FileUtils.mkdir_p(File.dirname(db_path))
        File.write(db_path, "") # existence is all require_sqlite! needs to be reached
        begin
          Agent::Sessions::Adapters::Opencode.new(env: { "HOME" => home }).sessions.force
          puts "NO_RAISE"
        rescue Agent::Sessions::MissingDependency
          puts "MISSING_DEPENDENCY"
        rescue Exception => e
          puts "\#{e.class}: \#{e.message}"
        end
      end
    RUBY
    assert status.success?, "subprocess crashed: #{out}"
    assert_equal "MISSING_DEPENDENCY", out.strip
  end

  # --- Design doc section 10 promise 1 (never write) ----------------------
  # The real no-writes check (SHA-256 of opencode.db/-wal/-shm before and
  # after a full read, against the real 359-session database on the
  # verifying machine) cannot live in this suite — it needs a real opencode
  # install. What CAN live here: proving the connection is genuinely
  # READONLY-flagged, not merely opened with a `?mode=ro` string that a typo
  # or a future edit could drop without any test noticing. Pushing a write
  # through the adapter's own each_session_row and asserting it surfaces as
  # UnreadableStore (not silently succeeding) is the three-line version of
  # that promise this suite can make good on.
  def test_the_connection_is_genuinely_read_only_not_just_by_convention
    with_home do |home, env|
      build_fixture(home)
      adapter = Agent::Sessions::Adapters::Opencode.new(env: env)
      db_path = Agent::Sessions.locate(:opencode, env: env).effective.path
      assert_raises(Agent::Sessions::UnreadableStore) do
        adapter.send(:each_session_row, db_path, "INSERT INTO session VALUES ('ses_x', '/y', 1, 2)")
      end
    end
  end

  # --- URI metacharacters in the resolved path -----------------------------
  # Reproduces the worst case found in review directly: a directory literally
  # named with a percent-escape sequence ("a%23b") gets that sequence DECODED
  # by SQLite's URI parser into a different path ("a#b") when interpolated
  # unescaped — so a decoy database sitting at the decoded path is read
  # instead, silently, with no exception. escape_uri_path is what stands
  # between db_path and being partial URI grammar.
  def test_a_path_containing_a_percent_encoded_looking_segment_reads_the_right_database
    with_home do |home, env|
      # base_dir with XDG_DATA_HOME set + env_join: "opencode" resolves to
      # <XDG_DATA_HOME>/opencode/opencode.db — build the real database at
      # exactly that path, under a directory literally named "a%23b".
      env = env.merge("XDG_DATA_HOME" => File.join(home, "a%23b"))
      real_db = build_raw_db(File.join(home, "a%23b", "opencode", "opencode.db"),
                              [["ses_real", "/Users/you/app", 1, 2]])

      # The path SQLite's URI parser would DECODE "a%23b" into: a literal "#".
      # A different, real database sitting there is the decoy this test
      # proves is NOT what gets read.
      build_raw_db(File.join(home, "a#b", "opencode", "opencode.db"),
                   [["ses_decoy", "/Users/you/evil", 9, 9]])

      assert_equal real_db, Agent::Sessions.locate(:opencode, env: env).effective.path
      sessions = Agent::Sessions::Adapters::Opencode.new(env: env).sessions.force
      assert_equal ["ses_real"], sessions.map(&:id)
    end
  end

  # --- updated_at's cross-adapter invariant (plan decision 5) -------------
  # "updated_at is never nil; started_at may be." Every file-based adapter
  # gets this for free from Base#updated_at_for = stat.mtime. opencode is the
  # first that can violate it: session_time can fail on time_updated alone,
  # or on both time_created and time_updated together, and Task 10's
  # sort_by(&:updated_at) has no rescue for a nil comparing against a Time —
  # one malformed row in the shared database would take the WHOLE cross-agent
  # listing down with an ArgumentError, not just this adapter's rows.

  def test_updated_at_falls_back_to_created_at_when_only_updated_is_malformed
    with_home do |home, env|
      build_malformed_db(home, [["ses_bad_updated", "/Users/you/app", 1_752_484_323_000, "not-a-number"]])
      session = Agent::Sessions::Adapters::Opencode.new(env: env).sessions.first
      assert_equal Time.at(1_752_484_323_000 / 1000.0), session.started_at
      assert_equal session.started_at, session.updated_at
      refute_nil session.updated_at
    end
  end

  def test_updated_at_falls_back_to_the_database_file_mtime_when_both_timestamps_are_malformed
    with_home do |home, env|
      db_path = build_malformed_db(home, [["ses_bad_both", "/Users/you/app", "nope", "nope"]])
      session = Agent::Sessions::Adapters::Opencode.new(env: env).sessions.first
      assert_nil session.started_at
      assert_equal File.mtime(db_path), session.updated_at
    end
  end

  # The invariant proven end-to-end: a listing with one thoroughly malformed
  # row still sorts by updated_at without raising — the exact operation
  # Task 10 performs, and the exact one a nil updated_at would break.
  def test_updated_at_is_never_nil_so_the_listing_always_sorts
    with_home do |home, env|
      build_malformed_db(home, [["ses_ok", "/Users/you/app", 1, 2],
                                 ["ses_bad_both", "/Users/you/other", "x", "y"]])
      sessions = Agent::Sessions::Adapters::Opencode.new(env: env).sessions.force
      assert(sessions.none? { |s| s.updated_at.nil? })
      sorted = sessions.sort_by(&:updated_at)
      assert_equal 2, sorted.size
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
      sessions = Agent::Sessions::Adapters::Opencode.new(env: env).sessions.force
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
      sessions = Agent::Sessions::Adapters::Opencode.new(env: env).sessions.force
      assert_equal 1, sessions.size, "expected the listing to survive an already-Infinity time_created"
      assert_nil sessions.first.started_at
    end
  end

  def test_a_null_directory_yields_a_nil_project_path_and_is_excluded_from_project_paths
    with_home do |home, env|
      build_malformed_db(home, [["ses_null_dir", nil, 1, 2], ["ses_ok", "/Users/you/app", 3, 4]])
      adapter = Agent::Sessions::Adapters::Opencode.new(env: env)
      sessions = adapter.sessions.force
      assert_equal 2, sessions.size, "expected the listing to survive a NULL directory"
      null_dir_session = sessions.find { |s| s.id == "ses_null_dir" }
      assert_nil null_dir_session.project_path
      assert_equal ["/Users/you/app"], adapter.project_paths
    end
  end

  # The NULL case above does not prove the is_a?(String) guard: SQL NULL already
  # arrives as Ruby nil, so the guard is a no-op for it. SQLite's storage classes
  # are per-value, not per-column, so a BLOB lands in `directory` as an
  # ASCII-8BIT String and a bare number lands as an Integer — the latter is what
  # would otherwise reach project_paths' sort and raise on comparison with a
  # String. This is the fixture that exercises the guard's real branch.
  def test_a_non_string_directory_is_excluded_rather_than_reaching_the_sort
    with_home do |home, env|
      build_malformed_db(home, [["ses_int_dir", 42, 1, 2], ["ses_ok", "/Users/you/app", 3, 4]])
      adapter = Agent::Sessions::Adapters::Opencode.new(env: env)
      sessions = adapter.sessions.force
      assert_equal 2, sessions.size, "expected the listing to survive a non-String directory"
      assert_nil sessions.find { |s| s.id == "ses_int_dir" }.project_path
      assert_equal ["/Users/you/app"], adapter.project_paths
    end
  end

  # --- store discovery (added 2026-08-24) ---
  #
  # Before this, only ~/.local/share/opencode was looked at, so a macOS user
  # whose store sits under Application Support got an empty result from an
  # agent they had used. The candidate list comes from tokentelemetry probing
  # the same store; only the default is verified on the machine this was
  # written on, which is why every other branch is exercised by a fixture.

  def test_the_macos_application_support_store_is_found
    skip "macOS-only candidate" unless Agent::Sessions::Adapters::Base.platform_for == :macos

    with_home do |home, env|
      path = File.join(home, "Library", "Application Support", "opencode", "opencode.db")
      build_raw_db(path, [["ses_mac", "/Users/you/app", 1, 2]])
      assert_equal ["ses_mac"], Agent::Sessions.sessions(:opencode, env: env).map(&:id).force
    end
  end

  def test_opencode_data_dir_outranks_every_hardcoded_candidate
    with_home do |home, env|
      build_db(home, [["ses_default", "/Users/you/app", 1, 2]])
      elsewhere = File.join(home, "elsewhere")
      build_raw_db(File.join(elsewhere, "opencode.db"), [["ses_env", "/Users/you/app", 1, 2]])
      found = Agent::Sessions.sessions(:opencode, env: env.merge("OPENCODE_DATA_DIR" => elsewhere))
      assert_equal ["ses_env"], found.map(&:id).force
    end
  end

  # A directory that exists but holds no database must not shadow a real store
  # further down the list — the reason the candidate test is "holds a db",
  # not "exists".
  def test_an_empty_candidate_directory_does_not_shadow_a_real_store
    with_home do |home, env|
      empty = File.join(home, "empty")
      FileUtils.mkdir_p(empty)
      build_db(home, [["ses_default", "/Users/you/app", 1, 2]])
      found = Agent::Sessions.sessions(:opencode, env: env.merge("OPENCODE_DATA_DIR" => empty))
      assert_equal ["ses_default"], found.map(&:id).force
    end
  end

  # opencode names its database per release channel. A store holding only
  # opencode-stable.db is a real store, and used to report nothing.
  def test_a_release_channel_database_is_enumerated_and_verified
    with_home do |home, env|
      path = File.join(home, ".local", "share", "opencode", "opencode-stable.db")
      build_raw_db(path, [["ses_stable", "/Users/you/app", 1, 2]])
      assert_equal ["ses_stable"], Agent::Sessions.sessions(:opencode, env: env).map(&:id).force
      database = Agent::Sessions.verify(:opencode, env: env).find { |c| c.claim == "store database exists" }
      assert_predicate database, :pass?, "a channel-named database must satisfy the declared store"
      assert_includes database.detail, "opencode-stable.db"
    end
  end

  # Two channel databases can hold the same session after a migration. One
  # session is one row to a caller counting them.
  def test_the_same_session_in_two_databases_is_reported_once
    with_home do |home, env|
      dir = File.join(home, ".local", "share", "opencode")
      build_raw_db(File.join(dir, "opencode.db"), [["ses_shared", "/Users/you/app", 1, 2]])
      build_raw_db(File.join(dir, "opencode-stable.db"), [["ses_shared", "/Users/you/app", 1, 2],
                                                          ["ses_only_stable", "/Users/you/app", 1, 2]])
      ids = Agent::Sessions.sessions(:opencode, env: env).map(&:id).force
      assert_equal %w[ses_shared ses_only_stable].sort, ids.sort
      assert_equal 1, ids.count("ses_shared")
    end
  end

  # SQL ORDER BY sorts within one file; the union of two must still be sorted,
  # which is the one thing Base guarantees about project_paths.
  def test_projects_are_sorted_across_two_databases
    with_home do |home, env|
      dir = File.join(home, ".local", "share", "opencode")
      build_raw_db(File.join(dir, "opencode.db"), [["s1", "/z/last", 1, 2]])
      build_raw_db(File.join(dir, "opencode-stable.db"), [["s2", "/a/first", 1, 2]])
      assert_equal ["/a/first", "/z/last"], Agent::Sessions.projects(:opencode, env: env)
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
