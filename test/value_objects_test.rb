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

  def test_location_matches_survives_a_symlink_loop
    Dir.mktmpdir do |dir|
      looped = File.join(dir, "looped")
      File.symlink(looped, looped)
      location = AgentSessions::Location.new(kind: :sessions, path: looped, format: :jsonl, glob: "*.jsonl")
      assert_empty location.matches
    end
  end

  def test_location_matches_treats_path_metacharacters_literally
    Dir.mktmpdir do |dir|
      weird = File.join(dir, "app [old]")
      FileUtils.mkdir_p(weird)
      FileUtils.touch(File.join(weird, "a.jsonl"))
      location = AgentSessions::Location.new(kind: :sessions, path: weird, format: :jsonl, glob: "*.jsonl")
      assert_equal [File.join(weird, "a.jsonl")], location.matches
    end
  end
end
