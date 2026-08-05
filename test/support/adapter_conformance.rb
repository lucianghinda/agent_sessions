# frozen_string_literal: true

# Include in an adapter test and define:
#   adapter_class            -> the adapter class
#   build_fixture(home)      -> create the agent's on-disk layout under home
#   expected_default_path(home) -> effective path when only HOME is set
#   override_env             -> env hash exercising the primary env override
#   expected_override_path   -> effective path under override_env
module AdapterConformance
  include FixtureHelpers

  def test_conformance_is_registered
    assert_equal adapter_class, AgentSessions.registry[adapter_class.agent_name]
  end

  def test_conformance_declares_required_metadata
    assert_kind_of Symbol, adapter_class.agent_name
    assert_kind_of String, adapter_class.label_text
    assert_kind_of Date, adapter_class.verified_on_date
    assert_includes [true, false, :partly], adapter_class.documented_value
    refute_empty adapter_class.store_configs
  end

  def test_conformance_locates_under_default_home
    with_home do |home, env|
      build_fixture(home)
      store = adapter_class.new(env: env).locate
      assert_equal expected_default_path(home), store.effective.path
      assert store.effective.exists?
      assert store.installed?
    end
  end

  def test_conformance_env_override_wins
    skip "#{adapter_class.agent_name} declares no verified env override" if override_env.nil?

    with_home do |_home, env|
      store = adapter_class.new(env: env.merge(override_env)).locate
      assert_equal expected_override_path, store.effective.path
    end
  end

  def test_conformance_locate_never_raises_when_absent
    with_home do |_home, env|
      store = adapter_class.new(env: env).locate
      refute store.installed?
    end
  end

  def test_conformance_instances_do_not_share_state
    first = adapter_class.new(env: { "HOME" => "/home-one" }).locate.effective.path
    second = adapter_class.new(env: { "HOME" => "/home-two" }).locate.effective.path
    refute_equal first, second
  end

  # --- Layer 2 conformance ---------------------------------------------------
  # Opt in by additionally defining:
  #   expected_session_id     -> id of the single session build_fixture creates
  #   expected_project_path   -> the project recorded in that fixture, or nil
  #                              when the agent genuinely cannot know it
  # Tests skip when these are absent, so Layer-1-only adapters stay green.

  def test_conformance_sessions_are_lazy
    with_home do |_home, env|
      assert_instance_of Enumerator::Lazy, adapter_class.new(env: env).sessions
    end
  end

  def test_conformance_absent_agent_has_no_sessions
    with_home do |_home, env|
      assert_empty adapter_class.new(env: env).sessions.force
    end
  end

  def test_conformance_enumerates_exactly_the_fixture_session
    skip_unless_layer2
    with_home do |home, env|
      build_fixture(home)
      sessions = adapter_class.new(env: env).sessions.force
      assert_equal [expected_session_id], sessions.map(&:id)
      session = sessions.first
      assert_equal adapter_class.agent_name, session.agent
      assert_equal "#{adapter_class.agent_name}:#{expected_session_id}", session.uid
      refute_nil session.updated_at
      assert_equal adapter_class.fidelity_value, session.fidelity
    end
  end

  def test_conformance_project_path_matches_the_fixture
    skip_unless_layer2
    with_home do |home, env|
      build_fixture(home)
      session = adapter_class.new(env: env).sessions.first
      if expected_project_path.nil?
        assert_nil session.project_path
      else
        assert_equal expected_project_path, session.project_path
      end
    end
  end

  def test_conformance_for_project_round_trips
    skip_unless_layer2
    skip "#{adapter_class.agent_name} cannot know its project paths" if expected_project_path.nil?

    with_home do |home, env|
      build_fixture(home)
      adapter = adapter_class.new(env: env)
      found = adapter.sessions_for_project(expected_project_path).force
      assert_equal [expected_session_id], found.map(&:id)
      assert_empty adapter.sessions_for_project("/definitely/not/this/project").force
    end
  end

  def test_conformance_project_paths_lists_the_fixture_project
    skip_unless_layer2
    skip "#{adapter_class.agent_name} cannot know its project paths" if expected_project_path.nil?

    with_home do |home, env|
      build_fixture(home)
      assert_equal [expected_project_path], adapter_class.new(env: env).project_paths
    end
  end

  # --- Filename-parsing conformance -------------------------------------------
  # Opt in by additionally defining:
  #   malformed_date_filename -> a filename matching the adapter's own
  #                              timestamp-in-filename shape, but with an
  #                              out-of-range digit (month 13, minute 60...)
  #                              that Time.new rejects
  #   unmatched_filename      -> a filename that does not match that shape at
  #                              all (a sync tool's "(conflicted copy)" or
  #                              similar), forcing the basename fallback
  # Requires build_fixture(home) to return the path of the file it writes
  # (write already does), so a sibling file can be written into the same
  # directory without each test class re-deriving its own layout.
  #
  # Written for Task 5 (pi) after two mutations — an unrescued ArgumentError
  # from a bad filename, and session_id_from's fallback missing its `super`
  # — survived the full suite despite Codex declaring the identical rescue
  # and fallback pattern first. The rules had transferred as code; the
  # evidence they mattered had not. Pi opts in below; any future adapter
  # that parses a timestamp or id out of its filename should too.

  def test_conformance_a_malformed_date_filename_does_not_take_down_the_listing
    skip_unless_filename_parsed
    with_home do |home, env|
      fixture_path = build_fixture(home)
      write("{}", File.dirname(fixture_path), malformed_date_filename)

      sessions = adapter_class.new(env: env).sessions.force
      assert_equal 2, sessions.size, "expected the listing to survive #{malformed_date_filename.inspect}"

      bad = sessions.find { |s| File.basename(s.path) == malformed_date_filename }
      refute_nil bad, "expected a session for #{malformed_date_filename.inspect}"
      assert_equal base_started_at(bad), bad.started_at,
                   "expected started_at_for's rescue to fall back to Base's answer"
    end
  end

  def test_conformance_unrecognized_filename_falls_back_to_the_basename
    skip_unless_filename_parsed
    with_home do |home, env|
      fixture_path = build_fixture(home)
      write("{}", File.dirname(fixture_path), unmatched_filename)

      sessions = adapter_class.new(env: env).sessions.force
      assert_equal 2, sessions.size, "expected the listing to survive #{unmatched_filename.inspect}"

      unmatched = sessions.find { |s| File.basename(s.path) == unmatched_filename }
      refute_nil unmatched, "expected a session for #{unmatched_filename.inspect}"
      assert_equal File.basename(unmatched_filename, ".*"), unmatched.id
      assert_equal base_started_at(unmatched), unmatched.started_at
    end
  end

  private

  def skip_unless_layer2
    return if respond_to?(:expected_session_id, true)

    skip "define expected_session_id and expected_project_path for Layer 2 conformance"
  end

  # A stricter version could `flunk` instead of `skip` when the adapter
  # overrides session_id_from or started_at_for without defining these
  # fixtures: instance_method(:session_id_from).owner != Base separates
  # "parses its own filenames" from "does not" cleanly, today, for every
  # adapter. Considered 2026-08-05 and deferred rather than declined: Codex
  # overrides both hooks but keeps its own pre-existing bespoke coverage of
  # the same guarantees instead of opting into these, so enabling the
  # stricter check now would fail Codex's suite, not just catch a future
  # adapter that forgets — and deciding to migrate Codex onto this shared
  # conformance is a separate call from this one. The next adapter that
  # parses filenames without opting in (Cursor, Task 7) is exactly the case
  # this would catch; worth revisiting once Codex's own tests are folded in
  # or removed.
  def skip_unless_filename_parsed
    return if respond_to?(:malformed_date_filename, true)

    skip "define malformed_date_filename and unmatched_filename for filename-parsing conformance"
  end

  # What Base's started_at_for would answer for this session's file — a Time
  # on a filesystem carrying birthtime, nil on one without (every Linux CI
  # runner). Comparing against it, rather than asserting non-nil, pins "the
  # adapter's own fallback fired" on both platforms; refute_nil would only
  # pin "this machine implements birthtime". Mirrors Codex's own
  # base_started_at helper; an adapter test class may define its own
  # same-named private method to override this default if it needs to.
  def base_started_at(session)
    AgentSessions::Adapters::Base
      .instance_method(:started_at_for)
      .bind(adapter_class.new(env: {}))
      .call(session.path, File.stat(session.path))
  end
end
