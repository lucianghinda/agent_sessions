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

  def test_location_exists_and_lists_glob_files
    Dir.mktmpdir do |dir|
      FileUtils.touch(File.join(dir, "a.jsonl"))
      location = AgentSessions::Location.new(kind: :sessions, path: dir, format: :jsonl, glob: "*.jsonl")
      assert location.exists?
      assert_equal [File.join(dir, "a.jsonl")], location.files

      missing = location.with(path: File.join(dir, "nope"))
      refute missing.exists?
    end
  end

  def test_single_file_location_lists_itself
    Dir.mktmpdir do |dir|
      path = File.join(dir, "history.jsonl")
      FileUtils.touch(path)
      location = AgentSessions::Location.new(kind: :history, path: path, format: :jsonl, single_file: true)
      assert_equal [path], location.files
    end
  end

  def test_single_file_location_lists_nothing_when_absent
    location = AgentSessions::Location.new(
      kind: :history, path: "/nonexistent/history.jsonl", format: :jsonl, single_file: true
    )
    assert_empty location.files
  end

  # A plain directory with no glob is a store whose internal layout this gem has not
  # yet learned (opencode's legacy storage/, Cursor's acp-sessions/). Returning [] is
  # honest; enumerable? is how a caller tells that apart from "enumerated, found none".
  def test_directory_without_glob_lists_nothing_and_says_so
    Dir.mktmpdir do |dir|
      FileUtils.touch(File.join(dir, "a.json"))
      location = AgentSessions::Location.new(kind: :legacy, path: dir, format: :json)
      assert_empty location.files
      refute location.enumerable?
    end
  end

  def test_enumerable_covers_globs_and_single_files
    glob = AgentSessions::Location.new(kind: :sessions, path: "/x", format: :jsonl, glob: "*.jsonl")
    file = AgentSessions::Location.new(kind: :history, path: "/x/h.jsonl", format: :jsonl, single_file: true)
    assert glob.enumerable?
    assert file.enumerable?
  end

  def test_location_defaults_keep_glob_optional
    location = AgentSessions::Location.new(kind: :legacy, path: "/x", format: :json)
    assert_nil location.glob
    refute location.single_file
  end

  def test_check_predicates
    check = AgentSessions::Check.new(agent: :claude, status: :pass, claim: "c", detail: "d")
    assert check.pass?
    refute AgentSessions::Check.new(agent: :claude, status: :fail, claim: "c", detail: "d").pass?
  end

  def test_location_files_survives_a_symlink_loop
    Dir.mktmpdir do |dir|
      looped = File.join(dir, "looped")
      File.symlink(looped, looped)
      location = AgentSessions::Location.new(kind: :sessions, path: looped, format: :jsonl, glob: "*.jsonl")
      assert_empty location.files
    end
  end

  def test_location_files_treats_path_metacharacters_literally
    Dir.mktmpdir do |dir|
      weird = File.join(dir, "app [old]")
      FileUtils.mkdir_p(weird)
      FileUtils.touch(File.join(weird, "a.jsonl"))
      location = AgentSessions::Location.new(kind: :sessions, path: weird, format: :jsonl, glob: "*.jsonl")
      assert_equal [File.join(weird, "a.jsonl")], location.files
    end
  end
end
