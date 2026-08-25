# frozen_string_literal: true

require_relative "test_helper"

# PROVISIONAL: no ~/.grok exists on the machine this was written on, so these
# fixtures encode tokentelemetry's parser of the format rather than observed
# Grok output.
#
# Grok's session is a DIRECTORY — summary.json plus chat_history.jsonl and
# siblings — which makes it the first adapter whose enumerated file is not
# the file its reader reads.
class GrokAdapterTest < Minitest::Test
  include AdapterConformance

  def adapter_class = Agent::Sessions::Adapters::Grok

  def build_fixture(home)
    write(JSON.generate(summary), *session_dir(home), "summary.json")
  end

  def expected_default_path(home) = File.join(home, ".grok", "sessions")

  def override_env = nil

  def expected_session_id = SESSION
  def expected_project_path = PROJECT

  def test_the_id_is_the_directory_not_the_filename
    with_home do |home, env|
      build_fixture(home)
      session = Agent::Sessions.sessions(:grok, env: env).first
      assert_equal SESSION, session.id, "summary.json is the file; the directory is the session"
    end
  end

  # The project bucket is a URL-encoded absolute path, so unlike Claude's and
  # pi's dash encodings this one round-trips exactly.
  def test_the_project_bucket_encoding_round_trips
    adapter = adapter_class.new(env: {})
    encoded = adapter.encode_project(PROJECT)
    assert_equal PROJECT, adapter.decode_project(encoded)
    assert_equal ENCODED_PROJECT, encoded
  end

  def test_a_space_encodes_as_percent_20_rather_than_plus
    adapter = adapter_class.new(env: {})
    encoded = adapter.encode_project("/Users/you/my app")
    refute_includes encoded, "+", "a + would decode back to a literal +, not a space"
    assert_equal "/Users/you/my app", adapter.decode_project(encoded)
  end

  # summary.json's own info.cwd beats the directory name where both exist.
  def test_the_recorded_cwd_is_preferred_over_the_decoded_directory
    with_home do |home, env|
      recorded = { info: { cwd: "/Users/you/moved" }, created_at: CREATED, updated_at: UPDATED }
      write(JSON.generate(recorded), *session_dir(home), "summary.json")
      assert_equal "/Users/you/moved", Agent::Sessions.sessions(:grok, env: env).first.project_path
    end
  end

  def test_a_summary_without_a_cwd_falls_back_to_the_decoded_directory
    with_home do |home, env|
      write(JSON.generate({ created_at: CREATED }), *session_dir(home), "summary.json")
      assert_equal PROJECT, Agent::Sessions.sessions(:grok, env: env).first.project_path
    end
  end

  def test_timestamps_come_from_the_summary
    with_home do |home, env|
      build_fixture(home)
      session = Agent::Sessions.sessions(:grok, env: env).first
      assert_equal Time.utc(2026, 7, 21, 9, 12, 3), session.started_at
      assert_equal Time.utc(2026, 7, 21, 10, 30), session.updated_at
    end
  end

  # bytes counts the whole session directory, the way Claude's counts its
  # sidecar tree: the transcript and its sibling logs belong to this session.
  def test_bytes_counts_the_whole_session_directory
    with_home do |home, env|
      build_fixture(home)
      write("x" * 500, *session_dir(home), "chat_history.jsonl")
      write("y" * 300, *session_dir(home), "events.jsonl")
      session = Agent::Sessions.sessions(:grok, env: env).first
      assert_operator session.bytes, :>=, 800, "the transcript and event log are this session's bytes"
    end
  end

  def test_provisional_shape_is_declared_once_the_store_exists
    with_home do |home, env|
      refute(Agent::Sessions.locate(:grok, env: env).warnings.any? { |w| w.include?("unverified") })
      build_fixture(home)
      assert(Agent::Sessions.locate(:grok, env: env).warnings.any? { |w| w.include?("unverified") })
    end
  end

  def test_the_separate_usage_log_is_declared
    with_home do |_home, env|
      assert(Agent::Sessions.locate(:grok, env: env).warnings.any? { |w| w.include?("unified.jsonl") })
    end
  end

  private

  SESSION = "0f1e2d3c-4b5a-4697-8899-aabbccddeeff"
  PROJECT = "/Users/you/app"
  ENCODED_PROJECT = "%2FUsers%2Fyou%2Fapp"
  CREATED = "2026-07-21T09:12:03.000Z"
  UPDATED = "2026-07-21T10:30:00.000Z"

  def session_dir(home) = [home, ".grok", "sessions", ENCODED_PROJECT, SESSION]

  def summary
    { info: { cwd: PROJECT }, created_at: CREATED, updated_at: UPDATED,
      generated_title: "fixing the parser", current_model_id: "grok-build" }
  end
end
