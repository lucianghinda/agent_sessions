# frozen_string_literal: true

require_relative "test_helper"

class AuditTest < Minitest::Test
  include FixtureHelpers

  def test_reports_bytes_per_existing_store
    with_home do |home, env|
      write("x" * 100, home, ".claude", "projects", "-p", "s.jsonl")
      findings = Agent::Sessions.audit(env: env)
      claude = findings.find { |f| f.agent == :claude && f.kind == :projects }
      assert_equal 100, claude.bytes
      assert_empty claude.synced_to
    end
  end

  def test_skips_absent_stores
    with_home do |_home, env|
      assert_empty Agent::Sessions.audit(env: env)
    end
  end

  def test_flags_stores_inside_dropbox
    with_home do |home, env|
      write("x" * 10, home, "Dropbox", "claude", "projects", "-p", "s.jsonl")
      env = env.merge("CLAUDE_CONFIG_DIR" => File.join(home, "Dropbox", "claude"))
      findings = Agent::Sessions.audit(env: env)
      claude = findings.find { |f| f.agent == :claude }
      assert_includes claude.synced_to, :dropbox
    end
  end

  def test_flags_stores_inside_cloudstorage
    with_home do |home, env|
      write("x", home, "Library", "CloudStorage", "GoogleDrive-x", "claude", "projects", "-p", "s.jsonl")
      env = env.merge("CLAUDE_CONFIG_DIR" => File.join(home, "Library", "CloudStorage", "GoogleDrive-x", "claude"))
      findings = Agent::Sessions.audit(env: env)
      assert_includes findings.find { |f| f.agent == :claude }.synced_to, :cloud_storage
    end
  end

  def test_bytes_for_single_file_stores
    with_home do |home, env|
      touch(home, ".claude", "projects", "-p", "s.jsonl")
      write("y" * 42, home, ".claude", "history.jsonl")
      findings = Agent::Sessions.audit(env: env)
      history = findings.find { |f| f.agent == :claude && f.kind == :history }
      assert_equal 42, history.bytes
    end
  end

  def test_layer_one_is_read_only
    with_home do |home, env|
      touch(home, ".claude", "projects", "-p", "s.jsonl")
      FileUtils.chmod_R(0o555, home)
      begin
        assert_equal Agent::Sessions.agents.size, Agent::Sessions.all(env: env).size
        refute_empty Agent::Sessions.verify(env: env)
        refute_empty Agent::Sessions.doctor(env: env)
        refute_empty Agent::Sessions.audit(env: env)
      ensure
        FileUtils.chmod_R(0o755, home)
      end
    end
  end
end
