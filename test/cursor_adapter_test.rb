# frozen_string_literal: true

require_relative "test_helper"
require "sqlite3"

class CursorAdapterTest < Minitest::Test
  include AdapterConformance

  def adapter_class = AgentSessions::Adapters::Cursor

  # store.db content is an undocumented blob (design doc 8.3) — Layer 2 never
  # opens it. The sibling meta.json carries the metadata. Field names are from
  # the design doc, UNVERIFIED on this machine (no ~/.cursor/chats here).
  def build_fixture(home)
    write("", home, ".cursor", "chats", "chat-1", "0192-uuid", "store.db")
    meta = { schemaVersion: 1, createdAtMs: 1_752_484_323_000,
             updatedAtMs: 1_752_490_000_000, cwd: "/Users/you/app", title: "fixture" }
    write(JSON.generate(meta), home, ".cursor", "chats", "chat-1", "0192-uuid", "meta.json")
  end

  def expected_session_id = "chat-1/0192-uuid"
  def expected_project_path = "/Users/you/app"

  def expected_default_path(home) = File.join(home, ".cursor", "chats")

  def override_env = nil

  def test_warns_that_chat_payloads_are_undecoded
    with_home do |_home, env|
      store = AgentSessions.locate(:cursor, env: env)
      assert(store.warnings.any? { |w| w.include?("blob") })
    end
  end

  def test_xdg_config_home_does_not_move_cursor
    store = AgentSessions.locate(:cursor, env: { "HOME" => "/h", "XDG_CONFIG_HOME" => "/xdg/config" })
    assert_equal "/h/.cursor/chats", store.effective.path
  end

  def test_timestamps_come_from_meta_json
    with_home do |home, env|
      build_fixture(home)
      session = AgentSessions::Adapters::Cursor.new(env: env).sessions.first
      assert_equal Time.at(1_752_484_323_000 / 1000.0), session.started_at
      assert_equal Time.at(1_752_490_000_000 / 1000.0), session.updated_at
    end
  end

  def test_missing_meta_json_falls_back_to_stat
    with_home do |home, env|
      db = write("", home, ".cursor", "chats", "chat-2", "u2", "store.db")
      session = AgentSessions::Adapters::Cursor.new(env: env).sessions.first
      assert_equal File.mtime(db), session.updated_at
      assert_nil session.project_path
    end
  end

  def test_fidelity_is_metadata
    assert_equal :metadata, AgentSessions::Adapters::Cursor.fidelity_value
  end

  # Gated like cursor_ide's warning about its real session location: a "here
  # is what breaks, please act on it" report reaches only someone whose
  # declared store exists to act on — silent for a user with no
  # ~/.cursor/chats at all (this machine, today), present once chats exist.
  def test_warns_that_meta_json_field_names_are_unverified_once_chats_exist
    with_home do |home, env|
      refute(AgentSessions.locate(:cursor, env: env).warnings.any? { |w| w.include?("createdAtMs") })
      build_fixture(home)
      assert(AgentSessions.locate(:cursor, env: env).warnings.any? { |w| w.include?("createdAtMs") })
    end
  end

  # --- Malformed-shape guards -------------------------------------------------
  # Mirrors Amp's own section by the same name: presence of a key is not a
  # usable value (rule 1), and the container holding it needs its type
  # checked too, not just the leaf (rule 2). meta_for centralizes both checks
  # for all three readers (started_at_for, updated_at_for, project_path_for),
  # so one fixture per case here is enough to pin all of them at once rather
  # than tripling the fixtures the way project_path_for-only coverage would.

  def test_project_path_is_nil_when_meta_json_is_not_an_object
    with_home do |home, env|
      write("", home, ".cursor", "chats", "chat-array", "u", "store.db")
      write(JSON.generate([1, 2, 3]), home, ".cursor", "chats", "chat-array", "u", "meta.json")
      session = AgentSessions::Adapters::Cursor.new(env: env).sessions.find { |s| s.id == "chat-array/u" }
      assert_nil session.project_path
    end
  end

  def test_project_path_is_nil_when_cwd_is_not_a_string
    with_home do |home, env|
      write("", home, ".cursor", "chats", "chat-int-cwd", "u", "store.db")
      write(JSON.generate({ cwd: 42 }), home, ".cursor", "chats", "chat-int-cwd", "u", "meta.json")
      session = AgentSessions::Adapters::Cursor.new(env: env).sessions.find { |s| s.id == "chat-int-cwd/u" }
      assert_nil session.project_path
    end
  end

  # createdAtMs: 1e400 is valid JSON (an in-range exponent literal) that
  # overflows Ruby's Float to Infinity at parse time, not at read time —
  # Time.at(Float::INFINITY) raises FloatDomainError, uncaught, which is
  # rule 3's failure mode: one bad timestamp taking every agent's listing
  # down, not just this session's. Pins meta_time's post-division finite?
  # check rather than a pre-division check on millis alone (see the comment
  # on meta_time): millis itself is a valid, finite Integer here, and only
  # overflows once divided by 1000.0.
  # silence_warnings wraps the lookup: real 1e400 JSON overflowing to
  # Infinity is exactly what this test targets, and Ruby's own -w narrates
  # that at the two points it happens (JSON's internal Float() call, and this
  # adapter's `/ 1000.0`) — informative when hunting the bug, but noise once
  # the guard it exists to prove is in place and covered by an assertion.
  # This is a report artifact, not a behavior change: nothing here touches
  # what meta_time returns, only whether Ruby narrates the overflow reaching
  # it, and the surrounding assertions still fail exactly as they would
  # unsilenced if the guard regressed.
  def test_started_at_falls_back_to_stat_when_created_at_ms_overflows_to_infinity
    with_home do |home, env|
      db = write("", home, ".cursor", "chats", "chat-huge", "u", "store.db")
      # Written as raw text, not JSON.generate({ createdAtMs: 1e400 }): the Ruby
      # Float literal 1e400 is ALREADY Infinity by the time Ruby parses this
      # source file, and JSON.generate refuses to serialize Infinity at all
      # (GeneratorError). The on-disk case this test pins is different: the
      # bytes on disk are the finite-looking text "1e400", and it is JSON.parse
      # — not this test file's own Ruby source — that overflows it to Infinity.
      write('{"createdAtMs": 1e400}', home, ".cursor", "chats", "chat-huge", "u", "meta.json")
      session = silence_warnings { AgentSessions::Adapters::Cursor.new(env: env).sessions.find { |s| s.id == "chat-huge/u" } }
      assert_equal base_started_at(session), session.started_at
      assert_equal File.mtime(db), session.updated_at
    end
  end

  # A JSON integer literal hundreds of digits long parses as an exact Ruby
  # Integer (is_a?(Numeric) holds, finite? holds — Integers have no Infinity)
  # and only overflows once `/ 1000.0` forces it through Float. Same crash,
  # different route than the Float-literal case above; kept as its own test
  # because millis.finite? alone would have let this one through.
  def test_started_at_falls_back_to_stat_when_created_at_ms_is_a_huge_integer
    with_home do |home, env|
      db = write("", home, ".cursor", "chats", "chat-bignum", "u", "store.db")
      write(JSON.generate({ createdAtMs: 10**400 }), home, ".cursor", "chats", "chat-bignum", "u", "meta.json")
      session = silence_warnings { AgentSessions::Adapters::Cursor.new(env: env).sessions.find { |s| s.id == "chat-bignum/u" } }
      assert_equal base_started_at(session), session.started_at
      assert_equal File.mtime(db), session.updated_at
    end
  end

  # Pins the OTHER half of meta_time's guard chain: is_a?(Numeric) rejects a
  # wrong-typed value before the division that the two overflow tests above
  # exercise ever runs. A String intermediate would not raise here even
  # unguarded ("not-a-number" / 1000.0 raises NoMethodError, which IS a
  # raise — so this is still load-bearing, just via a different exception
  # than the TypeError/FloatDomainError the other guards catch).
  def test_started_at_falls_back_to_stat_when_created_at_ms_is_not_numeric
    with_home do |home, env|
      db = write("", home, ".cursor", "chats", "chat-str", "u", "store.db")
      write(JSON.generate({ createdAtMs: "not-a-number" }), home, ".cursor", "chats", "chat-str", "u", "meta.json")
      session = AgentSessions::Adapters::Cursor.new(env: env).sessions.find { |s| s.id == "chat-str/u" }
      assert_equal base_started_at(session), session.started_at
      assert_equal File.mtime(db), session.updated_at
    end
  end

  # --- read_json survives an unreadable sibling -------------------------------
  # Task 7 made Base#read_json reachable EAGERLY, from started_at_for and
  # updated_at_for, for every single Cursor session — the first adapter to do
  # so; every earlier caller of read_json only reached it lazily, through the
  # deferred project_path resolver. That turned Base#read_json's original
  # rescue (four specific Errno constants, none of them ELOOP) into a real
  # bug, not a theoretical gap: a symlink-loop meta.json next to a HEALTHY
  # chat raised Errno::ELOOP out of Enumerator::Lazy#filter_map and took the
  # WHOLE `sessions` enumeration down with it — the healthy chat included, not
  # just the looped one. Fixed in Base#read_json and Base#build_session
  # (SystemCallError, not an enumerated Errno list — see their comments for
  # the EPERM evidence alongside this ELOOP one). Pinned here, in the adapter
  # that made it reachable, because "the healthy sibling survives" is the part
  # a narrower fix (rescuing only Errno::ELOOP, say) would not obviously get
  # right without a test asserting the SURVIVING session, not just the absence
  # of a raise.
  def test_a_symlink_loop_meta_json_does_not_take_down_a_healthy_sibling_chat
    with_home do |home, env|
      build_fixture(home)
      write("", home, ".cursor", "chats", "chat-loop", "u", "store.db")
      loop_path = File.join(home, ".cursor", "chats", "chat-loop", "u", "meta.json")
      File.symlink(loop_path, loop_path)

      sessions = AgentSessions::Adapters::Cursor.new(env: env).sessions.force
      assert_equal 2, sessions.size, "expected the listing to survive a symlink-loop meta.json"

      looped = sessions.find { |s| s.id == "chat-loop/u" }
      refute_nil looped, "expected a session for the chat whose meta.json is the symlink loop"
      assert_nil looped.project_path
    end
  end

  # --- session_id_from's path-depth assumption --------------------------------
  # Not opted into the shared filename-parsing conformance (test/support/
  # adapter_conformance.rb): that module's two tests both write a SIBLING
  # file into the fixture's own directory under a different basename, relying
  # on the adapter's own glob to pick it up so the enumerator actually sees
  # two sessions. Cursor's glob is "chats/*/*/store.db" — the wildcards are
  # both DIRECTORY segments; the filename itself is the literal string
  # "store.db", not a pattern. Dir.glob confirms a sibling under any other
  # name is invisible to it (verified: only "store.db" itself matches, a file
  # named e.g. "rollout-2026-13-21T09-12-03-x.jsonl" written next to it does
  # not appear in the glob's results at all). So malformed_date_filename and
  # unmatched_filename cannot be defined here the way pi's and Codex's are:
  # either fixture would make test_conformance_a_malformed_date_filename_...
  # and test_conformance_unrecognized_filename_falls_back_to_the_basename
  # fail outright (sessions.size stays 1, not the 2 those tests assert),
  # not skip — the fixture the shared harness needs is one this store's own
  # declaration cannot produce.
  #
  # That is also why "a filename Cursor doesn't recognize" isn't quite the
  # right question for this adapter in the first place: session_id_from
  # parses ENCLOSING DIRECTORY names, not the (fixed) filename, and never
  # falls back to a basename the way pi/Codex/Base do — there is no `super`
  # call in it. What the shared tests are really standing in for — "a
  # surprising path must not crash the hook, and must not crash the listing"
  # — is tested directly below instead, against the actual assumption this
  # hook makes (two directory segments), by calling the hook rather than
  # routing through the (structurally incapable of producing this) glob.
  def test_session_id_from_does_not_raise_for_a_shallow_path
    adapter = AgentSessions::Adapters::Cursor.new(env: { "HOME" => "/h" })
    assert_equal "///", adapter.session_id_from("/store.db")
  end

  private

  # See the comment on its two callers above: this only suppresses Ruby's -w
  # narration of an overflow the surrounding assertions already pin, never
  # the overflow itself.
  def silence_warnings
    original = $VERBOSE
    $VERBOSE = nil
    yield
  ensure
    $VERBOSE = original
  end
end

# Repointed 2026-08-24 at the store the 0.2 adapter's warning named, now that
# it has been opened: ~/Library/Application Support/Cursor/User/globalStorage/
# state.vscdb, table cursorDiskKV, keys composerData:<uuid> — 6 real rows on
# the machine this was written on, each carrying composerId, createdAt (epoch
# millis) and an EMPTY conversation array. The old declaration
# (~/.cursor/projects/*/agent-transcripts/*) did not exist there at all.
class CursorIdeAdapterTest < Minitest::Test
  include AdapterConformance

  def adapter_class = AgentSessions::Adapters::CursorIde

  def build_fixture(home)
    build_db(home, [[composer_key(SESSION), composer_value(CREATED_MS)]])
  end

  # The macOS layout, which is the verified one and the platform CI and this
  # machine both run. expected_default_path follows the same branch rather
  # than hardcoding it, so the suite is honest on a Linux runner too.
  def expected_default_path(home)
    File.join(home, *globalstorage_segments, "state.vscdb")
  end

  def override_env = nil

  def expected_session_id = SESSION
  # Composer records name no project: context.fileSelections holds paths of
  # ATTACHED files (an unrelated settings file, in the real data), and a
  # workspace root inferred from one attachment would be a guess.
  def expected_project_path = nil

  def test_ide_is_a_separate_agent_from_the_cli
    refute_equal AgentSessions.registry[:cursor], AgentSessions.registry[:cursor_ide]
  end

  def test_warns_stores_do_not_sync
    with_home do |_home, env|
      store = AgentSessions.locate(:cursor_ide, env: env)
      assert(store.warnings.any? { |w| w.include?("sync") })
    end
  end

  # :metadata, not :unsupported — the adapter can now say a session exists and
  # when it started. It stays below :messages because every real record here
  # carried an empty conversation, so the turn format is still unseen.
  def test_ide_reports_metadata_fidelity
    assert_equal :metadata, AgentSessions::Adapters::CursorIde.fidelity_value
  end

  def test_warns_that_session_content_is_not_read
    with_home do |_home, env|
      store = AgentSessions.locate(:cursor_ide, env: env)
      assert(store.warnings.any? { |w| w.include?("conversation") })
    end
  end

  def test_the_store_is_a_single_sqlite_file
    with_home do |_home, env|
      store = AgentSessions.locate(:cursor_ide, env: env)
      assert_equal :sqlite, store.format
      assert_predicate store.effective, :single_file
    end
  end

  def test_started_at_comes_from_the_records_created_at
    with_home do |home, env|
      build_fixture(home)
      session = AgentSessions.sessions(:cursor_ide, env: env).first
      assert_equal Time.at(CREATED_MS / 1000.0), session.started_at
      assert_equal session.started_at, session.updated_at
      assert_nil session.bytes, "a row in a shared database has no file size of its own"
    end
  end

  # updated_at is a cross-adapter invariant: never nil, because `since` and
  # every sort rely on it. A record with no usable createdAt falls back to the
  # database file's own mtime rather than returning nil.
  def test_a_record_without_a_usable_created_at_still_has_an_updated_at
    with_home do |home, env|
      build_db(home, [[composer_key(SESSION), JSON.generate({ composerId: SESSION })]])
      session = AgentSessions.sessions(:cursor_ide, env: env).first
      assert_nil session.started_at
      refute_nil session.updated_at
    end
  end

  def test_a_record_whose_value_is_not_json_is_still_a_session
    with_home do |home, env|
      build_db(home, [[composer_key(SESSION), "not json"]])
      session = AgentSessions.sessions(:cursor_ide, env: env).first
      assert_equal SESSION, session.id
      assert_nil session.started_at
    end
  end

  # cursorDiskKV also holds inlineDiffsData rows (1 of 7 in the real store).
  # Only composerData rows are sessions.
  def test_other_key_prefixes_in_the_same_table_are_not_sessions
    with_home do |home, env|
      build_db(home, [[composer_key(SESSION), composer_value(CREATED_MS)],
                      ["inlineDiffsData:x", JSON.generate({ createdAt: CREATED_MS })]])
      assert_equal [SESSION], AgentSessions.sessions(:cursor_ide, env: env).map(&:id).force
    end
  end

  def test_projects_are_empty_rather_than_guessed_from_attached_files
    with_home do |home, env|
      build_fixture(home)
      assert_empty AgentSessions.projects(:cursor_ide, env: env)
      assert_empty AgentSessions.for_project("/Users/you/app", env: env, agents: [:cursor_ide]).to_a
    end
  end

  def test_platform_selection_covers_the_three_declared_layouts
    klass = AgentSessions::Adapters::Base
    assert_equal :macos, klass.platform_for("x86_64-darwin24")
    assert_equal :windows, klass.platform_for("x64-mingw-ucrt")
    assert_equal :linux, klass.platform_for("x86_64-linux")
  end

  private

  SESSION = "6c65ff9a-02b9-47de-8c48-8e60d682b689"
  CREATED_MS = 1_776_161_422_165

  def composer_key(id) = "composerData:#{id}"

  # Shaped as the real records are, trimmed to the keys this adapter reads
  # plus the empty conversation that is the reason it stops at :metadata.
  def composer_value(created_ms)
    JSON.generate({ composerId: SESSION, createdAt: created_ms, conversation: [],
                    status: "none", unifiedMode: "edit", tokenCount: 1993 })
  end

  def globalstorage_segments
    case AgentSessions::Adapters::Base.platform_for
    when :macos then ["Library", "Application Support", "Cursor", "User", "globalStorage"]
    when :windows then ["AppData", "Roaming", "Cursor", "User", "globalStorage"]
    else [".config", "Cursor", "User", "globalStorage"]
    end
  end

  def build_db(home, rows)
    path = File.join(home, *globalstorage_segments, "state.vscdb")
    FileUtils.mkdir_p(File.dirname(path))
    db = SQLite3::Database.new(path)
    db.execute("CREATE TABLE cursorDiskKV (key TEXT PRIMARY KEY, value BLOB)")
    rows.each { |row| db.execute("INSERT INTO cursorDiskKV VALUES (?, ?)", row) }
    path
  ensure
    db&.close
  end
end
