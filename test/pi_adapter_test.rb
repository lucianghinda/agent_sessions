# frozen_string_literal: true

require_relative "test_helper"

class PiAdapterTest < Minitest::Test
  include AdapterConformance

  def adapter_class = AgentSessions::Adapters::Pi

  # Directory is the double-dash-wrapped encoded cwd; filename is
  # <timestamp>_<8-hex-id>.jsonl; a header line opens the file (pi publishes its
  # format — design doc 8.6). UNVERIFIED on this machine (zero pi sessions on
  # disk 2026-08-05): the header is assumed to carry a "cwd" key. If a real pi
  # session disagrees, fix the adapter and record the deviation in the plan.
  def build_fixture(home)
    header = { version: 3, cwd: "/Users/you/app", timestamp: "2026-07-14T09:12:03.000Z" }
    write(JSON.generate(header), home, ".pi", "agent", "sessions", "--Users-you-app--",
          "2026-07-14T09-12-03_ab12cd34.jsonl")
  end

  def expected_session_id = "ab12cd34"
  def expected_project_path = "/Users/you/app"

  def expected_default_path(home) = File.join(home, ".pi", "agent", "sessions")

  def override_env = { "PI_CODING_AGENT_DIR" => "/custom/pi" }
  def expected_override_path = "/custom/pi/sessions"

  def test_session_dir_env_overrides_the_store_directly
    store = AgentSessions.locate(:pi, env: { "HOME" => "/h", "PI_CODING_AGENT_SESSION_DIR" => "/elsewhere" })
    assert_equal "/elsewhere", store.effective.path
  end

  def test_session_dir_env_beats_base_dir_env
    env = { "HOME" => "/h", "PI_CODING_AGENT_DIR" => "/custom/pi", "PI_CODING_AGENT_SESSION_DIR" => "/elsewhere" }
    store = AgentSessions.locate(:pi, env: env)
    assert_equal "/elsewhere", store.effective.path
  end

  def test_encode_project_wraps_the_dashed_cwd_in_double_dashes
    adapter = AgentSessions::Adapters::Pi.new(env: { "HOME" => "/h" })
    assert_equal "--Users-you-app--", adapter.encode_project("/Users/you/app")
  end

  def test_started_at_comes_from_the_filename
    with_home do |home, env|
      build_fixture(home)
      session = AgentSessions::Adapters::Pi.new(env: env).sessions.first
      assert_equal Time.new(2026, 7, 14, 9, 12, 3), session.started_at
    end
  end

  def test_fidelity_is_full
    assert_equal :full, AgentSessions::Adapters::Pi.fidelity_value
  end

  # limit: 3 mirrors Codex's slack even though the design doc places pi's
  # header on line 1 only (8.6) — this machine has zero real pi sessions to
  # verify that against, so the same tolerance-for-a-blank-or-truncated-first-
  # line reasoning applies here without the 360-file evidence Codex has.
  # "3" counts iterations of File.foreach(path, "\n", MAX_LINE_BYTES), not
  # lines, per scan_jsonl_for_key's own docs.
  #
  # Filler lines omit "cwd" entirely so scan_jsonl_for_key's key-presence
  # check, not the predicate, is what advances the scan up to the boundary.
  def test_project_path_resolves_at_the_scan_cap_boundary
    with_home do |home, env|
      filler = Array.new(2) { JSON.generate({ version: 3 }) }
      target = JSON.generate({ version: 3, cwd: "/Users/you/app" })
      write("#{(filler + [target]).join("\n")}\n", home, ".pi", "agent", "sessions", "--Users-you-app--",
            "2026-07-14T09-12-03_00000001.jsonl")
      session = AgentSessions::Adapters::Pi.new(env: env).sessions.first
      assert_equal "/Users/you/app", session.project_path
    end
  end

  # A usable header on line 4 — one line past the cap — must not resolve.
  # Paired with the boundary test above, this is what actually pins 3 rather
  # than merely being consistent with it.
  def test_project_path_gives_up_one_line_past_the_scan_cap
    with_home do |home, env|
      filler = Array.new(3) { JSON.generate({ version: 3 }) }
      target = JSON.generate({ version: 3, cwd: "/Users/you/app" })
      write("#{(filler + [target]).join("\n")}\n", home, ".pi", "agent", "sessions", "--Users-you-app--",
            "2026-07-14T09-12-03_00000002.jsonl")
      session = AgentSessions::Adapters::Pi.new(env: env).sessions.first
      assert_nil session.project_path
    end
  end
end
