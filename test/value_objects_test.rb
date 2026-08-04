# frozen_string_literal: true

require_relative "test_helper"

class ValueObjectsTest < Minitest::Test
  def test_error_hierarchy
    assert_operator AgentSessions::UnknownAgent, :<, AgentSessions::Error
    assert_operator AgentSessions::MissingDependency, :<, AgentSessions::Error
    assert_operator AgentSessions::UnreadableStore, :<, AgentSessions::Error
    assert_operator AgentSessions::UnsupportedFormat, :<, AgentSessions::Error
  end

  def test_env_override_active
    assert AgentSessions::EnvOverride.new(name: "CODEX_HOME", value: "/x").active?
    refute AgentSessions::EnvOverride.new(name: "CODEX_HOME", value: nil).active?
    refute AgentSessions::EnvOverride.new(name: "CODEX_HOME", value: "").active?
  end

  def test_location_exists_and_matches
    Dir.mktmpdir do |dir|
      FileUtils.touch(File.join(dir, "a.jsonl"))
      location = AgentSessions::Location.new(kind: :sessions, path: dir, format: :jsonl, glob: "*.jsonl")
      assert location.exists?
      assert_equal [File.join(dir, "a.jsonl")], location.matches

      missing = location.with(path: File.join(dir, "nope"))
      refute missing.exists?
    end
  end

  def test_location_without_glob_has_no_matches
    location = AgentSessions::Location.new(kind: :history, path: "/tmp/h.jsonl", format: :jsonl, glob: nil)
    assert_empty location.matches
  end

  def test_check_predicates
    check = AgentSessions::Check.new(agent: :claude, status: :pass, claim: "c", detail: "d")
    assert check.pass?
    refute AgentSessions::Check.new(agent: :claude, status: :fail, claim: "c", detail: "d").pass?
  end
end
