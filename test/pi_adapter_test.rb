# frozen_string_literal: true

require_relative "test_helper"

class PiAdapterTest < Minitest::Test
  include AdapterConformance

  def adapter_class = AgentSessions::Adapters::Pi

  # Directory is the double-dash-wrapped encoded cwd; filename is
  # <timestamp>_<8-hex-id>.jsonl; a header line opens the file (pi publishes
  # its format — design doc 8.6). UNVERIFIED on this machine (zero pi
  # sessions on disk 2026-08-05) — see the comment above `warnings` in the
  # adapter for what to check against a real session, and where.
  #
  # The header's timestamp (06:16:25 UTC) and the filename's timestamp
  # (09:12:03) deliberately disagree, mirroring Codex's fixture: it is what
  # gives test_started_at_comes_from_the_filename its teeth — if
  # started_at_for ever fell back to reading the file, this fixture would
  # catch it by returning the wrong hour. It is also why the local-vs-UTC
  # paragraph in started_at_for's comment matters: a UTC-publishing pi would
  # make this fixture read as self-consistent instead of deliberately not.
  # Do not "fix" the digits to match.
  def build_fixture(home)
    header = { version: 3, cwd: "/Users/you/app", timestamp: "2026-07-14T06:16:25.000Z" }
    write(JSON.generate(header), home, ".pi", "agent", "sessions", "--Users-you-app--",
          "2026-07-14T09-12-03_ab12cd34.jsonl")
  end

  def expected_session_id = "ab12cd34"
  def expected_project_path = "/Users/you/app"

  def expected_default_path(home) = File.join(home, ".pi", "agent", "sessions")

  def override_env = { "PI_CODING_AGENT_DIR" => "/custom/pi" }
  def expected_override_path = "/custom/pi/sessions"

  # Filename-parsing conformance (test/support/adapter_conformance.rb):
  # matches FILENAME's own shape (month "13" satisfies \d{2}) but Time.new
  # rejects it, proving started_at_for's rescue actually fires rather than
  # merely being present.
  def malformed_date_filename = "2026-13-21T09-12-03_ab12cd34.jsonl"

  # A sync tool's "(conflicted copy)" suffix breaks FILENAME's \A...\z
  # anchors entirely — this machine's home is Dropbox-hosted, so this is not
  # hypothetical. Forces session_id_from's basename fallback, and (with a
  # greedy id capture like (.+) instead of (\h{8})) would otherwise get
  # silently absorbed into what looks like a canonical id.
  def unmatched_filename = "2026-07-14T09-12-03_ab12cd34 (conflicted copy).jsonl"

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

  # The store is reported unverified only once it exists — an agent that was
  # never installed should not surface a warning about data it does not have.
  def test_unverified_warning_appears_once_the_store_exists
    with_home do |home, env|
      build_fixture(home)
      store = AgentSessions.locate(:pi, env: env)
      assert(store.warnings.any? { |w| w.include?("unverified") })
    end
  end

  def test_no_unverified_warning_when_pi_is_not_installed
    with_home do |_home, env|
      store = AgentSessions.locate(:pi, env: env)
      refute(store.warnings.any? { |w| w.include?("unverified") })
    end
  end

  # limit: 25 mirrors Claude's number, not because pi is assumed to behave
  # like Claude, but because scan_jsonl_for_key returns as soon as it finds a
  # usable record — the width is free while the line-1 assumption holds and
  # is only paid on the case this file cannot rule out. See project_path_for's
  # comment for the full reasoning and its one real cost.
  #
  # Filler lines omit "cwd" entirely so scan_jsonl_for_key's key-presence
  # check, not the predicate, is what advances the scan up to the boundary.
  def test_project_path_resolves_at_the_scan_cap_boundary
    with_home do |home, env|
      filler = Array.new(24) { JSON.generate({ version: 3 }) }
      target = JSON.generate({ version: 3, cwd: "/Users/you/app" })
      write("#{(filler + [target]).join("\n")}\n", home, ".pi", "agent", "sessions", "--Users-you-app--",
            "2026-07-14T09-12-03_00000001.jsonl")
      session = AgentSessions::Adapters::Pi.new(env: env).sessions.first
      assert_equal "/Users/you/app", session.project_path
    end
  end

  # A usable header on line 26 — one line past the cap — must not resolve.
  # Paired with the boundary test above, this is what actually pins 25
  # rather than merely being consistent with it.
  def test_project_path_gives_up_one_line_past_the_scan_cap
    with_home do |home, env|
      filler = Array.new(25) { JSON.generate({ version: 3 }) }
      target = JSON.generate({ version: 3, cwd: "/Users/you/app" })
      write("#{(filler + [target]).join("\n")}\n", home, ".pi", "agent", "sessions", "--Users-you-app--",
            "2026-07-14T09-12-03_00000002.jsonl")
      session = AgentSessions::Adapters::Pi.new(env: env).sessions.first
      assert_nil session.project_path
    end
  end

  # A record carrying "cwd": null must not shadow a later, usable record —
  # the presence-only scan stops right there and project_path is
  # permanently nil for the session without the predicate. Green on arrival;
  # kills the predicate-deletion mutation the 2026-08-05 review caught.
  def test_project_path_skips_a_null_cwd_and_finds_the_real_one
    with_home do |home, env|
      content = "#{JSON.generate({ version: 3, cwd: nil })}\n" \
                "#{JSON.generate({ version: 3, cwd: "/Users/you/app" })}\n"
      write(content, home, ".pi", "agent", "sessions", "--Users-you-app--",
            "2026-07-14T09-12-03_00000003.jsonl")
      session = AgentSessions::Adapters::Pi.new(env: env).sessions.first
      assert_equal "/Users/you/app", session.project_path
    end
  end
end
