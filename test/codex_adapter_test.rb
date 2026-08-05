# frozen_string_literal: true

require_relative "test_helper"

class CodexAdapterTest < Minitest::Test
  include AdapterConformance

  def adapter_class = AgentSessions::Adapters::Codex

  # Real filename shape, verified 2026-08-05:
  # rollout-2026-03-28T18-00-42-019d352d-1d88-7ed3-b0cc-dfab5f37ecd9.jsonl
  # Line 1 is session_meta with payload.cwd.
  FIXTURE_UUID = "019d352d-1d88-7ed3-b0cc-dfab5f37ecd9"

  # The meta timestamp (06:16:25) and the filename timestamp (09:12:03)
  # deliberately disagree — no real file does this, but it is what gives
  # test_started_at_comes_from_the_filename_not_a_read its teeth: if
  # started_at_for ever fell back to reading the file, this fixture would
  # catch it by returning the wrong hour. Do not "fix" them to match.
  def build_fixture(home)
    meta = { type: "session_meta", timestamp: "2026-07-21T06:16:25.064Z",
             payload: { id: FIXTURE_UUID, cwd: "/Users/you/app", cli_version: "0.0.0" } }
    write(JSON.generate(meta), home, ".codex", "sessions", "2026", "07", "21",
          "rollout-2026-07-21T09-12-03-#{FIXTURE_UUID}.jsonl")
  end

  def expected_session_id = FIXTURE_UUID
  def expected_project_path = "/Users/you/app"

  def expected_default_path(home) = File.join(home, ".codex", "sessions")

  def override_env = { "CODEX_HOME" => "/custom/codex" }
  def expected_override_path = "/custom/codex/sessions"

  def test_declares_history_and_index_as_optional_layers
    with_home do |_home, env|
      store = AgentSessions.locate(:codex, env: env)
      assert_equal %i[sessions history index], store.layers.map(&:kind)
    end
  end

  def test_carries_the_history_config_warning
    with_home do |_home, env|
      store = AgentSessions.locate(:codex, env: env)
      assert(store.warnings.any? { |w| w.include?("history.jsonl") })
    end
  end

  def test_started_at_comes_from_the_filename_not_a_read
    with_home do |home, env|
      build_fixture(home)
      session = AgentSessions::Adapters::Codex.new(env: env).sessions.first
      assert_equal Time.new(2026, 7, 21, 9, 12, 3), session.started_at
    end
  end

  def test_unrecognized_filenames_fall_back_to_the_basename
    with_home do |home, env|
      write("{}", home, ".codex", "sessions", "2026", "07", "21", "rollout-weird.jsonl")
      session = AgentSessions::Adapters::Codex.new(env: env).sessions.first
      assert_equal "rollout-weird", session.id
      # Confirms started_at_for's super fallback fired too, not just session_id_from's.
      # Compared against Base rather than asserted non-nil: Base returns nil where
      # birthtime is unimplemented, which is every Linux CI runner, so refute_nil
      # would test the platform rather than the fallback.
      assert_equal base_started_at(session), session.started_at
    end
  end

  # A sync tool's or backup's "(conflicted copy)" suffix must not be read as
  # part of the id: (.+) would swallow it greedily against \.jsonl\z, so the
  # uuid capture is pinned to its real shape (8-4-4-4-12 hex) instead. This
  # filename does not match FILENAME at all, so it falls back to the
  # basename, where the suffix stays visible rather than looking canonical.
  def test_conflicted_copy_suffix_does_not_get_absorbed_into_the_id
    with_home do |home, env|
      write("{}", home, ".codex", "sessions", "2026", "07", "21",
            "rollout-2026-07-21T09-12-03-#{FIXTURE_UUID} (conflicted copy).jsonl")
      session = AgentSessions::Adapters::Codex.new(env: env).sessions.first
      assert_equal "rollout-2026-07-21T09-12-03-#{FIXTURE_UUID} (conflicted copy)", session.id
    end
  end

  # month 13 and minute 60 both pass FILENAME's \d{2} groups (00-99) but both
  # raise ArgumentError from Time.new, through different internal checks
  # ("mon out of range" vs "min out of range") — proving the rescue in
  # started_at_for is not tuned to a single failure path.
  #
  # The assertion that matters is that the LISTING SURVIVES: build_session
  # deliberately lets a raising hook propagate and take the whole enumeration
  # down, on the theory that a raising hook is an adapter bug. A filename with
  # an out-of-range date is file data, not a bug, so started_at_for must
  # absorb it locally — one bad name among two good ones must still yield all
  # three sessions, not zero.
  def test_a_filename_with_an_out_of_range_date_does_not_take_down_the_whole_listing
    [
      "rollout-2026-13-21T09-12-03-#{FIXTURE_UUID}.jsonl", # month 13
      "rollout-2026-07-21T09-60-03-#{FIXTURE_UUID}.jsonl" # minute 60
    ].each do |bad_filename|
      with_home do |home, env|
        write("{}", home, ".codex", "sessions", "2026", "07", "21", bad_filename)
        write("{}", home, ".codex", "sessions", "2026", "07", "22", "rollout-2026-07-22T09-12-03-#{FIXTURE_UUID}.jsonl")
        write("{}", home, ".codex", "sessions", "2026", "07", "23", "rollout-2026-07-23T09-12-03-#{FIXTURE_UUID}.jsonl")

        sessions = AgentSessions::Adapters::Codex.new(env: env).sessions.force
        assert_equal 3, sessions.size, "expected the listing to survive #{bad_filename.inspect}"

        # FILENAME still matches (its \d{2} groups accept the digits); only
        # Time.new rejects them. session_id_from is unaffected — it is
        # started_at_for specifically that must fall back to stat.birthtime.
        bad_session = sessions.find { |s| s.path.end_with?(bad_filename) }
        assert_equal base_started_at(bad_session), bad_session.started_at,
                     "expected started_at_for's rescue to fall back to Base's answer"
      end
    end
  end

  def test_fidelity_is_full
    assert_equal :full, AgentSessions::Adapters::Codex.fidelity_value
  end

  # Pins the cap rather than leaving it free to regress. Real data (360 files,
  # verified 2026-08-05) puts session_meta on line 1 in every case, so 3 is
  # slack, not a tight fit — this proves the slack is exactly 3, not 2 or 4.
  # Filler lines omit "payload" entirely so scan_jsonl_for_key's key-presence
  # check, not the predicate, is what advances the scan.
  def test_project_path_resolves_at_the_scan_cap_boundary
    with_home do |home, env|
      filler = Array.new(2) { JSON.generate({ type: "event_msg" }) }
      target = JSON.generate({ type: "session_meta", payload: { cwd: "/Users/you/app" } })
      write("#{(filler + [target]).join("\n")}\n", home, ".codex", "sessions", "2026", "07", "21",
            "rollout-2026-07-21T09-12-03-00000000-0000-4000-8000-000000000001.jsonl")
      session = AgentSessions::Adapters::Codex.new(env: env).sessions.first
      assert_equal "/Users/you/app", session.project_path
    end
  end

  # session_meta on line 4 — one line past the cap — must not resolve. Paired
  # with the boundary test above, this is what actually pins 3 rather than
  # merely being consistent with it.
  def test_project_path_gives_up_one_line_past_the_scan_cap
    with_home do |home, env|
      filler = Array.new(3) { JSON.generate({ type: "event_msg" }) }
      target = JSON.generate({ type: "session_meta", payload: { cwd: "/Users/you/app" } })
      write("#{(filler + [target]).join("\n")}\n", home, ".codex", "sessions", "2026", "07", "21",
            "rollout-2026-07-21T09-12-03-00000000-0000-4000-8000-000000000002.jsonl")
      session = AgentSessions::Adapters::Codex.new(env: env).sessions.first
      assert_nil session.project_path
    end
  end

  # Real sessions on this machine (verified 2026-08-05) showed a later
  # turn_context record ALSO carrying a "payload" key whose value itself
  # carries "cwd" — a presence-only scan for "payload" would stop at whichever
  # of these comes first, which is only ever right by coincidence. The
  # predicate requires type == "session_meta" specifically, per design doc
  # 8.2: that is the one documented source of truth, not any record that
  # happens to shape its payload the same way.
  def test_project_path_ignores_a_payload_bearing_record_that_is_not_session_meta
    with_home do |home, env|
      content = "#{JSON.generate({ type: "turn_context", payload: { cwd: "/Users/you/decoy" } })}\n" \
                "#{JSON.generate({ type: "session_meta", payload: { cwd: "/Users/you/app" } })}\n"
      write(content, home, ".codex", "sessions", "2026", "07", "21",
            "rollout-2026-07-21T09-12-03-00000000-0000-4000-8000-000000000003.jsonl")
      session = AgentSessions::Adapters::Codex.new(env: env).sessions.first
      assert_equal "/Users/you/app", session.project_path
    end
  end

  # A session_meta whose payload is malformed (not a Hash, or cwd not a
  # String) must not shadow a later, usable session_meta, and must not raise.
  def test_project_path_skips_a_malformed_session_meta_and_finds_a_usable_one
    with_home do |home, env|
      content = "#{JSON.generate({ type: "session_meta", payload: "not-a-hash" })}\n" \
                "#{JSON.generate({ type: "session_meta", payload: { cwd: 42 } })}\n" \
                "#{JSON.generate({ type: "session_meta", payload: { cwd: "/Users/you/app" } })}\n"
      write(content, home, ".codex", "sessions", "2026", "07", "21",
            "rollout-2026-07-21T09-12-03-00000000-0000-4000-8000-000000000004.jsonl")
      session = AgentSessions::Adapters::Codex.new(env: env).sessions.first
      assert_equal "/Users/you/app", session.project_path
    end
  end

  private

  # What Base's started_at_for would answer for this session — a Time on a
  # filesystem carrying birthtime, nil on one without, which is every Linux CI
  # runner. Asserting equality against it pins "the super fallback fired" on both
  # platforms, where refute_nil would only pin "this machine implements birthtime".
  def base_started_at(session)
    AgentSessions::Adapters::Base
      .instance_method(:started_at_for)
      .bind(AgentSessions::Adapters::Codex.new(env: {}))
      .call(session.path, File.stat(session.path))
  end
end
