# frozen_string_literal: true

require_relative "test_helper"

# Shapes from a real store on this machine (2026-08-24): 9 project hashes,
# 12 chat files, 121 records (user 20, gemini 97, info 4), models
# gemini-2.5-pro and gemini-2.5-flash.
class GeminiAdapterTest < Minitest::Test
  include AdapterConformance

  def adapter_class = AgentSessions::Adapters::Gemini

  def build_fixture(home)
    write(JSON.generate(chat_document), home, ".gemini", "tmp", PROJECT_HASH, "chats", "#{SESSION}.json")
  end

  def expected_default_path(home) = File.join(home, ".gemini", "tmp")

  def override_env = nil

  def expected_session_id = SESSION
  # Without projects.json the hash cannot be reversed, so the fixture's
  # session has no project. test_projects_json_reverses_the_hash covers the
  # other case.
  def expected_project_path = nil

  def malformed_date_filename = "session-2025-13-45T99-99-b20947ab.json"
  # Inside the store by its glob (session-*.json) but not parseable by
  # FILENAME — the case that must degrade to the basename, not vanish. A name
  # the glob itself rejects would test the glob, not the fallback.
  def unmatched_filename = "session-notes.json"

  # The trailing hex is not a session id: two real files share d4abc9ce while
  # being different sessions, so the whole basename is the id.
  def test_two_sessions_sharing_a_filename_suffix_are_distinct
    with_home do |home, env|
      %w[session-2025-12-12T12-42-d4abc9ce session-2025-12-12T12-45-d4abc9ce].each do |name|
        write(JSON.generate(chat_document), home, ".gemini", "tmp", PROJECT_HASH, "chats", "#{name}.json")
      end
      ids = AgentSessions.sessions(:gemini, env: env).map(&:id).force
      assert_equal 2, ids.uniq.size
    end
  end

  # UTC, unlike Codex and pi. Four real filenames match their document's own
  # startTime to the minute as UTC, and would be hours out as local time.
  def test_started_at_reads_the_filename_as_utc
    with_home do |home, env|
      build_fixture(home)
      session = AgentSessions.sessions(:gemini, env: env).first
      assert_equal Time.utc(2025, 11, 29, 20, 8), session.started_at
    end
  end

  def test_a_malformed_filename_date_falls_back_rather_than_raising
    with_home do |home, env|
      write(JSON.generate(chat_document), home, ".gemini", "tmp", PROJECT_HASH, "chats",
            malformed_date_filename)
      session = AgentSessions.sessions(:gemini, env: env).first
      refute_nil session.updated_at
    end
  end

  # The store records no working directory anywhere — every JSON file in the
  # real store was grepped for cwd, workspace, projectPath, rootPath and
  # directory, and none appears. projects.json is Gemini's own map, and when
  # it is absent nil is the honest answer.
  def test_without_projects_json_a_session_has_no_project
    with_home do |home, env|
      build_fixture(home)
      assert_nil AgentSessions.sessions(:gemini, env: env).first.project_path
      assert_empty AgentSessions.projects(:gemini, env: env)
    end
  end

  def test_projects_json_reverses_the_hash
    with_home do |home, env|
      build_fixture(home)
      write(JSON.generate({ "/Users/you/app" => PROJECT_HASH }), home, ".gemini", "projects.json")
      session = AgentSessions.sessions(:gemini, env: env).first
      assert_equal "/Users/you/app", session.project_path
      assert_equal ["/Users/you/app"], AgentSessions.projects(:gemini, env: env)
      found = AgentSessions.for_project("/Users/you/app", env: env, agents: [:gemini]).to_a
      assert_equal [SESSION], found.map(&:id)
    end
  end

  def test_a_nested_projects_json_spelling_is_also_accepted
    with_home do |home, env|
      build_fixture(home)
      write(JSON.generate({ "projects" => { "/Users/you/app" => PROJECT_HASH } }),
            home, ".gemini", "projects.json")
      assert_equal "/Users/you/app", AgentSessions.sessions(:gemini, env: env).first.project_path
    end
  end

  def test_a_corrupt_projects_json_degrades_to_no_project_rather_than_raising
    with_home do |home, env|
      build_fixture(home)
      write("not json", home, ".gemini", "projects.json")
      assert_nil AgentSessions.sessions(:gemini, env: env).first.project_path
    end
  end

  # The JSONL delta variant exists in tokentelemetry's parser of this store
  # but on no file here. Enumerating nothing for those sessions silently is
  # the bug this warning exists to prevent.
  def test_jsonl_chats_are_reported_as_unread_rather_than_ignored
    with_home do |home, env|
      build_fixture(home)
      refute(AgentSessions.locate(:gemini, env: env).warnings.any? { |w| w.include?("JSONL") })
      write("{}\n", home, ".gemini", "tmp", PROJECT_HASH, "chats", "session-2026-01-01T00-00-aaaaaaaa.jsonl")
      assert(AgentSessions.locate(:gemini, env: env).warnings.any? { |w| w.include?("JSONL") })
    end
  end

  private

  SESSION = "session-2025-11-29T20-08-b20947ab"
  PROJECT_HASH = "c50803d9b17d02f08903fa879df04d28d4b5e7b68d97add32827a31e211f8b95"

  def chat_document
    { sessionId: "b20947ab-6d96-4c50-af3c-d04af150950a", projectHash: PROJECT_HASH,
      startTime: "2025-11-29T20:09:43.874Z", lastUpdated: "2025-12-02T04:37:33.208Z",
      messages: [{ id: "m1", timestamp: "2025-11-29T20:09:43.874Z", type: "user",
                   content: "hello" }] }
  end
end
