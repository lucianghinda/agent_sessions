# frozen_string_literal: true

require_relative "test_helper"

class ClaudeAdapterTest < Minitest::Test
  include AdapterConformance

  def adapter_class = AgentSessions::Adapters::Claude

  # Mirrors the real invariant: the project directory name is the encoded cwd
  # recorded inside the file. Real sessions open with a kebab-case preamble
  # (ai-title, agent-name, mode, permission-mode) followed by a
  # variable-length run of file-history-snapshot records — the run that makes
  # project_path_for's scan cap a judgement call rather than a tight fit —
  # before the first cwd-bearing record appears; never on line 1.
  def build_fixture(home)
    write_session(home, "-Users-you-app", expected_session_id, "/Users/you/app")
  end

  def expected_session_id = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
  def expected_project_path = "/Users/you/app"

  def expected_default_path(home) = File.join(home, ".claude", "projects")

  def override_env = { "CLAUDE_CONFIG_DIR" => "/custom/claude" }
  def expected_override_path = "/custom/claude/projects"

  def test_retention_defaults_to_30_days
    with_home do |_home, env|
      store = AgentSessions.locate(:claude, env: env)
      assert_equal 30, store.retention
      assert_equal :default, store.retention_source
    end
  end

  def test_retention_reads_cleanup_period_from_settings
    with_home do |home, env|
      write('{"cleanupPeriodDays": 7}', home, ".claude", "settings.json")
      store = AgentSessions.locate(:claude, env: env)
      assert_equal 7, store.retention
      assert_equal :setting, store.retention_source
    end
  end

  def test_corrupt_settings_fall_back_to_default
    with_home do |home, env|
      write("{not json", home, ".claude", "settings.json")
      store = AgentSessions.locate(:claude, env: env)
      assert_equal 30, store.retention
    end
  end

  def test_nonsense_retention_settings_fall_back_to_default
    [nil, "7", 7.5, -5].each do |value|
      with_home do |home, env|
        write(JSON.generate({ "cleanupPeriodDays" => value }), home, ".claude", "settings.json")
        store = AgentSessions.locate(:claude, env: env)
        assert_equal 30, store.retention, "expected #{value.inspect} to fall back"
        assert_equal :default, store.retention_source, "expected #{value.inspect} to report :default"
      end
    end
  end

  def test_zero_retention_is_a_real_setting
    with_home do |home, env|
      write('{"cleanupPeriodDays": 0}', home, ".claude", "settings.json")
      store = AgentSessions.locate(:claude, env: env)
      assert_equal 0, store.retention
      assert_equal :setting, store.retention_source
    end
  end

  def test_skip_prompt_history_env_adds_warning
    with_home do |_home, env|
      store = AgentSessions.locate(:claude, env: env.merge("CLAUDE_CODE_SKIP_PROMPT_HISTORY" => "1"))
      assert(store.warnings.any? { |w| w.include?("CLAUDE_CODE_SKIP_PROMPT_HISTORY") })
    end
  end

  def test_no_history_warning_by_default
    with_home do |_home, env|
      store = AgentSessions.locate(:claude, env: env)
      refute(store.warnings.any? { |w| w.include?("CLAUDE_CODE_SKIP_PROMPT_HISTORY") })
    end
  end

  def test_encode_project_collapses_every_non_alphanumeric_to_a_dash
    adapter = AgentSessions::Adapters::Claude.new(env: { "HOME" => "/h" })
    assert_equal "-Users-you-state-of-mind-til", adapter.encode_project("/Users/you/state_of_mind/til")
    assert_equal "-Users-you--config", adapter.encode_project("/Users/you/.config")
  end

  # Pins the cap rather than leaving it free to regress: mutation-proved, any
  # value in [4, 30] passed the old suite. cwd on line 25 must still resolve.
  def test_project_path_resolves_at_the_scan_cap_boundary
    with_home do |home, env|
      lines = Array.new(24) { JSON.generate({ type: "file-history-snapshot" }) }
      lines << JSON.generate({ type: "attachment", cwd: "/Users/you/app" })
      write("#{lines.join("\n")}\n", home, ".claude", "projects", "-Users-you-app", "cccccccc-0000-4000-8000-000000000001.jsonl")
      session = AgentSessions::Adapters::Claude.new(env: env).sessions.first
      assert_equal "/Users/you/app", session.project_path
    end
  end

  # cwd on line 26 — one line past the cap — must not resolve. Paired with
  # the boundary test above, this is what actually pins 25 rather than
  # merely being consistent with it.
  def test_project_path_gives_up_one_line_past_the_scan_cap
    with_home do |home, env|
      lines = Array.new(25) { JSON.generate({ type: "file-history-snapshot" }) }
      lines << JSON.generate({ type: "attachment", cwd: "/Users/you/app" })
      write("#{lines.join("\n")}\n", home, ".claude", "projects", "-Users-you-app", "dddddddd-0000-4000-8000-000000000002.jsonl")
      session = AgentSessions::Adapters::Claude.new(env: env).sessions.first
      assert_nil session.project_path
    end
  end

  def test_fidelity_is_full
    assert_equal :full, AgentSessions::Adapters::Claude.fidelity_value
  end

  # A record carrying "cwd": null must not shadow a later, usable record —
  # the presence-only scan stops right there and project_path is
  # permanently nil for the session, which is what item 3 of the review
  # (2026-08-05) caught.
  def test_project_path_skips_a_null_cwd_and_finds_the_real_one
    with_home do |home, env|
      content = "#{JSON.generate({ type: "attachment", cwd: nil })}\n" \
                "#{JSON.generate({ type: "attachment", cwd: "/Users/you/app" })}\n"
      write(content, home, ".claude", "projects", "-Users-you-app", "eeeeeeee-0000-4000-8000-000000000003.jsonl")
      session = AgentSessions::Adapters::Claude.new(env: env).sessions.first
      assert_equal "/Users/you/app", session.project_path
    end
  end

  # Without the type guard, "cwd": 42 or "cwd": {...} would reach
  # project_paths' .uniq.sort and raise ArgumentError from one malformed
  # record — a crash in `projects` caused by a single bad session.
  def test_project_paths_excludes_malformed_cwd_types_instead_of_crashing
    with_home do |home, env|
      write(JSON.generate({ type: "attachment", cwd: 42 }), home, ".claude", "projects", "-Users-you-int", "ffffffff-0000-4000-8000-000000000004.jsonl")
      write(JSON.generate({ type: "attachment", cwd: { "nested" => true } }), home, ".claude", "projects", "-Users-you-hash",
            "11111111-0000-4000-8000-000000000005.jsonl")
      build_fixture(home)
      paths = AgentSessions::Adapters::Claude.new(env: env).project_paths
      assert_equal [expected_project_path], paths
    end
  end

  # The critical fix (2026-08-05, reproduced against this machine's real
  # store): a rename leaves Claude still writing under the OLD encoded
  # directory, so two directories hold live sessions for the SAME current
  # cwd. Matching by directory name alone silently drops the stale
  # directory's sessions; matching by what each directory's sessions
  # actually record does not.
  # The stale directory is itself heterogeneous, mirroring what was found on
  # the real store: two of its sessions were resumed after the rename and
  # record the NEW cwd, one was never resumed and still records the OLD cwd
  # matching its own directory name. Matching by each session's own recorded
  # cwd finds the two resumed sessions and the fresh post-rename session,
  # and excludes the stale one on its own merits — no false positive from a
  # directory-level verdict.
  def test_sessions_for_project_finds_sessions_left_under_a_renamed_directory
    with_home do |home, env|
      # Stale, pre-rename directory name — Claude kept writing here.
      write_session(home, "-Users-you-review-hunk-changes", "22222222-0000-4000-8000-000000000006", "/Users/you/hunk-review-changes")
      write_session(home, "-Users-you-review-hunk-changes", "33333333-0000-4000-8000-000000000007", "/Users/you/hunk-review-changes")
      # Same stale directory, never resumed — still records the OLD cwd and
      # must NOT be returned.
      write_session(home, "-Users-you-review-hunk-changes", "66666666-0000-4000-8000-00000000000a", "/Users/you/review-hunk-changes")
      # Current, post-rename directory name.
      write_session(home, "-Users-you-hunk-review-changes", "44444444-0000-4000-8000-000000000008", "/Users/you/hunk-review-changes")
      # An unrelated project must not be swept in.
      write_session(home, "-Users-you-other", "55555555-0000-4000-8000-000000000009", "/Users/you/other")

      found = AgentSessions::Adapters::Claude.new(env: env).sessions_for_project("/Users/you/hunk-review-changes").force
      assert_equal %w[22222222-0000-4000-8000-000000000006 33333333-0000-4000-8000-000000000007
                      44444444-0000-4000-8000-000000000008], found.map(&:id).sort
    end
  end

  # A session whose header carries no readable cwd at all still needs to be
  # findable — it falls back to comparing its own directory's name, which is
  # the only thing encode_project still buys now that matching is exact.
  def test_sessions_for_project_falls_back_to_directory_name_when_cwd_is_unreadable
    with_home do |home, env|
      filler = Array.new(30) { JSON.generate({ type: "file-history-snapshot" }) } # no cwd anywhere — unreadable
      write("#{filler.join("\n")}\n", home, ".claude", "projects", "-Users-you-app", "77777777-0000-4000-8000-00000000000b.jsonl")

      found = AgentSessions::Adapters::Claude.new(env: env).sessions_for_project("/Users/you/app").force
      assert_equal ["77777777-0000-4000-8000-00000000000b"], found.map(&:id)
    end
  end

  # The name fallback exists for sessions whose cwd cannot be read; it must never
  # override one that can. Querying the STALE directory's own name is what exposes
  # that — its two resumed sessions sit in a name-matching directory while
  # recording a different cwd, so they must be excluded on their own merits.
  # Without this, `s.project_path == dir || name_matches` passes every other test.
  def test_name_fallback_never_overrides_a_readable_cwd
    with_home do |home, env|
      write_session(home, "-Users-you-review-hunk-changes", "22222222-0000-4000-8000-000000000006",
                    "/Users/you/hunk-review-changes")
      write_session(home, "-Users-you-review-hunk-changes", "33333333-0000-4000-8000-000000000007",
                    "/Users/you/hunk-review-changes")
      write_session(home, "-Users-you-review-hunk-changes", "66666666-0000-4000-8000-00000000000a",
                    "/Users/you/review-hunk-changes")
      found = AgentSessions::Adapters::Claude.new(env: env).sessions_for_project("/Users/you/review-hunk-changes").force
      assert_equal %w[66666666-0000-4000-8000-00000000000a], found.map(&:id)
    end
  end

  # A Claude session is a transcript plus a sidecar directory named after it:
  # subagents/ holds child agent transcripts, tool-results/ holds spilled tool
  # output. Both are that session's bytes on disk. Counting only the transcript
  # made `du` report 71% of what `audit` reported for the same store (122.1 MB
  # against 173.0 MB, measured on a real store 2026-08-10) — two commands in
  # one gem disagreeing about one directory.
  def test_bytes_include_the_sidecar_directory
    with_home do |home, env|
      path = write_session(home, "-Users-you-app", expected_session_id, "/Users/you/app")
      sidecar = File.join(File.dirname(path), expected_session_id)
      write("a" * 100, sidecar, "subagents", "agent-0198fa3c1122.jsonl")
      write("b" * 40, sidecar, "subagents", "agent-0198fa3c1122.meta.json")
      write("c" * 60, sidecar, "tool-results", "hook-1-additionalContext.txt")

      session = AgentSessions.sessions(:claude, env: env).first
      assert_equal File.size(path) + 200, session.bytes
    end
  end

  # FNM_DOTMATCH, for the same reason Audit#bytes_under uses it: a byte total
  # that quietly omits dotfiles is worse than no total at all.
  def test_sidecar_bytes_include_dotfiles
    with_home do |home, env|
      path = write_session(home, "-Users-you-app", expected_session_id, "/Users/you/app")
      write("x" * 25, File.dirname(path), expected_session_id, ".DS_Store")

      session = AgentSessions.sessions(:claude, env: env).first
      assert_equal File.size(path) + 25, session.bytes
    end
  end

  # A session without a sidecar is the whole store's shape on a fresh install,
  # and the common case forever on machines that never spawn subagents.
  def test_bytes_are_the_transcript_alone_without_a_sidecar
    with_home do |home, env|
      path = write_session(home, "-Users-you-app", expected_session_id, "/Users/you/app")

      session = AgentSessions.sessions(:claude, env: env).first
      assert_equal File.size(path), session.bytes
    end
  end

  # The sidecar lookup must not become a second way for enumeration to die.
  # A directory that cannot be read is missing bytes, not a missing session.
  def test_unreadable_sidecar_does_not_take_the_session_down
    with_home do |home, env|
      path = write_session(home, "-Users-you-app", expected_session_id, "/Users/you/app")
      sidecar = File.join(File.dirname(path), expected_session_id)
      write("a" * 100, sidecar, "subagents", "agent-0198fa3c1122.jsonl")
      File.chmod(0o000, sidecar)

      begin
        session = AgentSessions.sessions(:claude, env: env).first
        refute_nil session
        assert_operator session.bytes, :>=, File.size(path)
      ensure
        File.chmod(0o755, sidecar)
      end
    end
  end

  private

  # Builds a realistically-shaped session file: kebab-case preamble records, a
  # file-history-snapshot (the variable-length run project_path_for's comment
  # explains), then the first cwd-bearing record — never on line 1.
  def write_session(home, dir_name, session_id, cwd)
    lines = [
      { type: "ai-title", title: "fixture session", sessionId: session_id },
      { type: "agent-name", agentName: "claude", sessionId: session_id },
      { type: "mode", mode: "default", sessionId: session_id },
      { type: "permission-mode", permissionMode: "default", sessionId: session_id },
      { type: "file-history-snapshot", sessionId: session_id, snapshot: {} },
      { type: "attachment", cwd: cwd, sessionId: session_id, timestamp: "2026-07-14T09:12:03.000Z" }
    ]
    content = "#{lines.map { JSON.generate(it) }.join("\n")}\n"
    write(content, home, ".claude", "projects", dir_name, "#{session_id}.jsonl")
  end
end
