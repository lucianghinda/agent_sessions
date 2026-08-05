# frozen_string_literal: true

require_relative "test_helper"

class SessionTest < Minitest::Test
  def build(project_path: :omit, **overrides, &resolver)
    args = {
      agent: :claude,
      id: "018f2a7c",
      path: "/h/.claude/projects/-x/018f2a7c.jsonl",
      started_at: Time.utc(2026, 7, 14, 9, 12, 3),
      updated_at: Time.utc(2026, 7, 14, 10, 44, 51),
      bytes: 412_003,
      format: :jsonl,
      fidelity: :full
    }.merge(overrides)
    args[:project_path] = project_path unless project_path == :omit
    AgentSessions::Session.new(**args, &resolver)
  end

  def test_exposes_its_fields
    session = build
    assert_equal :claude, session.agent
    assert_equal "018f2a7c", session.id
    assert_equal "/h/.claude/projects/-x/018f2a7c.jsonl", session.path
    assert_equal Time.utc(2026, 7, 14, 9, 12, 3), session.started_at
    assert_equal Time.utc(2026, 7, 14, 10, 44, 51), session.updated_at
    assert_equal 412_003, session.bytes
    assert_equal :jsonl, session.format
    assert_equal :full, session.fidelity
  end

  def test_uid_is_agent_and_id
    assert_equal "claude:018f2a7c", build.uid
  end

  def test_project_path_is_lazy
    calls = 0
    session = build { calls += 1; "/Users/you/app" }
    assert_equal 0, calls
    assert_equal "/Users/you/app", session.project_path
    assert_equal 1, calls
  end

  def test_project_path_is_memoized
    calls = 0
    session = build { calls += 1; "/Users/you/app" }
    2.times { session.project_path }
    assert_equal 1, calls
  end

  def test_nil_resolution_is_memoized_too
    calls = 0
    session = build { calls += 1; nil }
    2.times { assert_nil session.project_path }
    assert_equal 1, calls
  end

  def test_project_path_can_be_pre_resolved
    session = build(project_path: "/Users/you/app")
    assert_equal "/Users/you/app", session.project_path
  end

  def test_pre_resolved_nil_is_a_real_answer_not_unresolved
    calls = 0
    session = build(project_path: nil) { calls += 1; "/should/not/run" }
    assert_nil session.project_path
    assert_equal 0, calls
  end

  def test_without_resolver_or_value_project_path_is_nil
    assert_nil build.project_path
  end

  def test_to_h_includes_everything_and_forces_project_path
    session = build { "/Users/you/app" }
    hash = session.to_h
    assert_equal "/Users/you/app", hash.fetch(:project_path)
    assert_equal "claude:018f2a7c", hash.fetch(:uid)
    assert_equal 412_003, hash.fetch(:bytes)
    assert_equal %i[agent id uid path project_path started_at updated_at bytes format fidelity],
                 hash.keys
  end

  def test_inspect_does_not_resolve_and_shows_unresolved
    calls = 0
    session = build { calls += 1; "/Users/you/app" }
    assert_match(/project_path: \(unresolved\)/, session.inspect)
    assert_equal 0, calls
  end

  def test_inspect_shows_resolved_project_path
    session = build(project_path: "/Users/you/app")
    assert_match(%r{project_path: "/Users/you/app"}, session.inspect)
  end
end
