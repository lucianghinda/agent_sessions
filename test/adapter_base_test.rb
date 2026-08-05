# frozen_string_literal: true

require_relative "test_helper"

class AdapterBaseTest < Minitest::Test
  include FixtureHelpers

  def test_resolves_default_base_dir_under_injected_home
    with_home do |home, env|
      store = FakeAdapter.new(env: env).locate
      assert_equal File.join(home, ".fake", "sessions"), store.effective.path
      assert_equal :jsonl, store.format
      assert_equal :fake, store.agent
      assert_equal "Fake Agent", store.label
      assert store.documented?
      assert_equal Date.new(2026, 7, 1), store.verified_on
    end
  end

  def test_base_env_override_replaces_base_dir
    store = FakeAdapter.new(env: { "HOME" => "/h", "FAKE_HOME" => "/custom" }).locate
    assert_equal "/custom/sessions", store.effective.path
  end

  def test_store_level_env_override_replaces_store_root
    store = FakeAdapter.new(env: { "HOME" => "/h", "FAKE_HISTORY_FILE" => "/elsewhere/hist.jsonl" }).locate
    history = store.layers.find { |l| l.kind == :history }
    assert_equal "/elsewhere/hist.jsonl", history.path
  end

  # The dir:/path: distinction is the only place the gem knows a layer is one file
  # rather than a directory. Discarding it at resolution time is what made
  # layers.flat_map(&:files) silently skip every single-file layer.
  def test_path_stores_resolve_to_single_file_locations
    store = FakeAdapter.new(env: { "HOME" => "/h" }).locate
    by_kind = store.layers.to_h { |l| [l.kind, l] }
    assert by_kind.fetch(:history).single_file
    refute by_kind.fetch(:sessions).single_file
  end

  def test_env_overridden_path_store_is_still_a_single_file
    store = FakeAdapter.new(env: { "HOME" => "/h", "FAKE_HISTORY_FILE" => "/elsewhere/hist.jsonl" }).locate
    assert store.layers.find { |l| l.kind == :history }.single_file
  end

  def test_gathering_every_layer_includes_single_file_layers
    with_home do |home, env|
      touch(home, ".fake", "sessions", "a.jsonl")
      touch(home, ".fake", "history.jsonl")
      files = FakeAdapter.new(env: env).locate.layers.flat_map(&:files)
      assert_includes files, File.join(home, ".fake", "sessions", "a.jsonl")
      assert_includes files, File.join(home, ".fake", "history.jsonl")
    end
  end

  def test_reports_all_env_overrides_with_state
    store = FakeAdapter.new(env: { "HOME" => "/h", "FAKE_HOME" => "/custom" }).locate
    by_name = store.env_overrides.to_h { |o| [o.name, o] }
    assert by_name.fetch("FAKE_HOME").active?
    refute by_name.fetch("FAKE_HISTORY_FILE").active?
  end

  def test_empty_env_value_is_ignored
    store = FakeAdapter.new(env: { "HOME" => "/h", "FAKE_HOME" => "" }).locate
    assert_equal "/h/.fake/sessions", store.effective.path
  end

  def test_declared_warnings_surface
    store = FakeAdapter.new(env: { "HOME" => "/h" }).locate
    assert_includes store.warnings, "fake is fake"
  end

  def test_retention_defaults_to_none
    store = FakeAdapter.new(env: { "HOME" => "/h" }).locate
    assert_nil store.retention
    assert_equal :none, store.retention_source
  end

  def test_installed_reflects_disk
    with_home do |home, env|
      refute FakeAdapter.new(env: env).locate.installed?
      touch(home, ".fake", "sessions", "a.jsonl")
      assert FakeAdapter.new(env: env).locate.installed?
    end
  end

  def test_dsl_macros_are_private
    refute_respond_to AgentSessions::Adapters::Base, :store
    refute_respond_to AgentSessions::Adapters::Base, :base_dir
  end

  def test_tilde_user_paths_stay_literal
    store = FakeAdapter.new(env: { "HOME" => "/h", "FAKE_HOME" => "~root" }).locate
    assert_equal "~root/sessions", store.effective.path
  end

  def test_store_requires_exactly_one_of_dir_or_path
    missing = assert_raises(ArgumentError) do
      Class.new(AgentSessions::Adapters::Base) { store :bad, format: :jsonl }
    end
    assert_includes missing.message, "dir:"

    assert_raises(ArgumentError) do
      Class.new(AgentSessions::Adapters::Base) { store :bad, dir: "d", path: "p.jsonl", format: :jsonl }
    end
  end

  def test_adapter_without_stores_names_what_is_missing
    adapter = Class.new(AgentSessions::Adapters::Base) do
      agent :bare
      base_dir default: "~/.bare"
    end
    error = assert_raises(AgentSessions::Error) { adapter.new(env: { "HOME" => "/h" }).locate }
    assert_includes error.message, "store"
  end

  def test_adapter_without_base_dir_names_what_is_missing
    adapter = Class.new(AgentSessions::Adapters::Base) do
      agent :bare
      store :sessions, dir: "s", format: :jsonl
    end
    error = assert_raises(AgentSessions::Error) { adapter.new(env: { "HOME" => "/h" }).locate }
    assert_includes error.message, "base_dir"
  end

  def test_empty_home_falls_back_like_an_absent_one
    with_default = FakeAdapter.new(env: {}).locate.effective.path
    assert_equal with_default, FakeAdapter.new(env: { "HOME" => "" }).locate.effective.path
  end

  def test_sessions_is_a_lazy_enumerator
    with_home do |_home, env|
      assert_instance_of Enumerator::Lazy, FakeAdapter.new(env: env).sessions
    end
  end

  def test_sessions_builds_one_session_per_primary_store_file
    with_home do |home, env|
      touch(home, ".fake", "sessions", "abc.jsonl")
      touch(home, ".fake", "history.jsonl") # a different layer — not a session
      sessions = FakeAdapter.new(env: env).sessions.force
      assert_equal ["abc"], sessions.map(&:id)
      session = sessions.first
      assert_equal :fake, session.agent
      assert_equal File.join(home, ".fake", "sessions", "abc.jsonl"), session.path
      assert_equal :jsonl, session.format
      assert_equal :full, session.fidelity
      assert_equal File.mtime(session.path), session.updated_at
      assert_equal 0, session.bytes
    end
  end

  def test_default_project_path_is_nil
    with_home do |home, env|
      touch(home, ".fake", "sessions", "abc.jsonl")
      assert_nil FakeAdapter.new(env: env).sessions.first.project_path
    end
  end

  def test_fidelity_defaults_to_unsupported_when_undeclared
    adapter = Class.new(AgentSessions::Adapters::Base) { agent :bare }
    assert_equal :unsupported, adapter.fidelity_value
  end

  def test_fidelity_rejects_unknown_values
    error = assert_raises(ArgumentError) do
      Class.new(AgentSessions::Adapters::Base) { fidelity :excellent }
    end
    assert_includes error.message, "excellent"
  end

  # The probe hook (project_dir_cwd) runs for every distinct directory
  # regardless of whether an adapter overrides project_path_for — but Base's
  # default hook is a no-op that returns nil without touching disk, so an
  # adapter declaring encode_project and nothing else still costs zero
  # content reads. The probe finding nothing falls back to the name
  # comparison, which is what actually matches here.
  def test_sessions_for_project_uses_the_encoded_dir_when_the_adapter_has_a_rule
    encoding = Class.new(AgentSessions::Adapters::Base) do
      agent :cheap
      label "Cheap"
      documented true
      verified_on "2026-07-01"
      base_dir default: "~/.cheap"
      store :sessions, dir: "sessions", glob: "*/*.jsonl", format: :jsonl

      def encode_project(dir) = dir.gsub(/[^a-zA-Z0-9]/, "-")
    end

    with_home do |home, env|
      touch(home, ".cheap", "sessions", "-Users-you-app", "s1.jsonl")
      touch(home, ".cheap", "sessions", "-Users-you-other", "s2.jsonl")
      found = encoding.new(env: env).sessions_for_project("/Users/you/app").force
      assert_equal ["s1"], found.map(&:id)
    end
  end

  # The critical fix (2026-08-05, reproduced against a real Claude store): a
  # rename leaves an agent still writing under the OLD encoded directory, so
  # two directories can hold live sessions for the SAME current cwd.
  # Directory-name matching alone silently drops the stale directory's
  # sessions — false negatives, decision 11's worst failure mode. Matching
  # must ask each directory what it actually contains.
  def test_sessions_for_project_matches_directories_by_probed_cwd_not_by_name
    renamed = Class.new(AgentSessions::Adapters::Base) do
      agent :renamed
      base_dir default: "~/.renamed"
      store :sessions, dir: "sessions", glob: "*/*.jsonl", format: :jsonl

      def encode_project(dir) = dir.gsub(/[^a-zA-Z0-9]/, "-")
      def project_path_for(path) = JSON.parse(File.read(path))["cwd"]
    end

    with_home do |home, env|
      # Stale, pre-rename directory name — the adapter kept writing here.
      write('{"cwd":"/Users/you/app"}', home, ".renamed", "sessions", "-Users-you-old-name", "s1.jsonl")
      write('{"cwd":"/Users/you/app"}', home, ".renamed", "sessions", "-Users-you-old-name", "s2.jsonl")
      # Current, post-rename directory name.
      write('{"cwd":"/Users/you/app"}', home, ".renamed", "sessions", "-Users-you-app", "s3.jsonl")

      found = renamed.new(env: env).sessions_for_project("/Users/you/app").force
      assert_equal %w[s1 s2 s3], found.map(&:id).sort
    end
  end

  # The whole point of probing per DIRECTORY rather than per session: cost is
  # O(project directories), not O(sessions), and stays that way across
  # repeated calls on the same adapter instance.
  def test_sessions_for_project_reads_each_directory_at_most_once
    counting = Class.new(AgentSessions::Adapters::Base) do
      agent :counting
      base_dir default: "~/.counting"
      store :sessions, dir: "sessions", glob: "*/*.jsonl", format: :jsonl

      attr_reader :probe_count

      def encode_project(dir) = dir.gsub(/[^a-zA-Z0-9]/, "-")

      def project_path_for(path)
        @probe_count = (@probe_count || 0) + 1
        JSON.parse(File.read(path))["cwd"]
      end
    end

    with_home do |home, env|
      write('{"cwd":"/Users/you/app"}', home, ".counting", "sessions", "-Users-you-old-name", "s1.jsonl")
      write('{"cwd":"/Users/you/app"}', home, ".counting", "sessions", "-Users-you-old-name", "s2.jsonl")
      write('{"cwd":"/Users/you/app"}', home, ".counting", "sessions", "-Users-you-old-name", "s3.jsonl")
      write('{"cwd":"/Users/you/app"}', home, ".counting", "sessions", "-Users-you-app", "s4.jsonl")

      adapter = counting.new(env: env)
      found = adapter.sessions_for_project("/Users/you/app").force
      assert_equal 4, found.size
      assert_equal 2, adapter.probe_count # two distinct directories, not four sessions

      adapter.sessions_for_project("/Users/you/app").force
      assert_equal 2, adapter.probe_count, "a repeated call must not re-read directories already resolved"
    end
  end

  # A directory whose representative session cannot say its cwd (corrupt or
  # truncated) must not crash and must not match everything — it falls back
  # to the name comparison, never worse than pre-fix behavior.
  def test_sessions_for_project_falls_back_to_name_when_the_probe_finds_no_cwd
    unreadable = Class.new(AgentSessions::Adapters::Base) do
      agent :unreadable
      base_dir default: "~/.unreadable"
      store :sessions, dir: "sessions", glob: "*/*.jsonl", format: :jsonl

      def encode_project(dir) = dir.gsub(/[^a-zA-Z0-9]/, "-")
      def project_path_for(_path) = nil # e.g. corrupt first session
    end

    with_home do |home, env|
      touch(home, ".unreadable", "sessions", "-Users-you-app", "s1.jsonl")
      touch(home, ".unreadable", "sessions", "-Users-you-other", "s2.jsonl")
      found = unreadable.new(env: env).sessions_for_project("/Users/you/app").force
      assert_equal ["s1"], found.map(&:id)
    end
  end

  def test_sessions_for_project_falls_back_to_reading_project_paths
    reading = Class.new(AgentSessions::Adapters::Base) do
      agent :slow
      label "Slow"
      documented true
      verified_on "2026-07-01"
      base_dir default: "~/.slow"
      store :sessions, dir: "sessions", glob: "*.json", format: :json

      def project_path_for(path) = read_json(path)["cwd"]
    end

    with_home do |home, env|
      write('{"cwd":"/Users/you/app"}', home, ".slow", "sessions", "s1.json")
      write('{"cwd":"/Users/you/other"}', home, ".slow", "sessions", "s2.json")
      found = reading.new(env: env).sessions_for_project("/Users/you/app").force
      assert_equal ["s1"], found.map(&:id)
    end
  end

  def test_project_paths_reads_distinct_recorded_projects
    reading = Class.new(AgentSessions::Adapters::Base) do
      agent :slow
      label "Slow"
      documented true
      verified_on "2026-07-01"
      base_dir default: "~/.slow"
      store :sessions, dir: "sessions", glob: "*.json", format: :json

      def project_path_for(path) = read_json(path)["cwd"]
    end

    with_home do |home, env|
      write('{"cwd":"/Users/you/app"}', home, ".slow", "sessions", "s1.json")
      write('{"cwd":"/Users/you/app"}', home, ".slow", "sessions", "s2.json")
      write("{}", home, ".slow", "sessions", "s3.json") # unknowable — excluded, not nil
      assert_equal ["/Users/you/app"], reading.new(env: env).project_paths
    end
  end

  # Glob order is not project order, and an adapter answering from a database
  # would impose its own. A stable order is what makes the output diffable.
  def test_project_paths_are_sorted_rather_than_left_in_glob_order
    reading = Class.new(AgentSessions::Adapters::Base) do
      agent :slow
      base_dir default: "~/.slow"
      store :sessions, dir: "sessions", glob: "*.json", format: :json

      def project_path_for(path) = read_json(path)["cwd"]
    end

    with_home do |home, env|
      write('{"cwd":"/Users/you/zebra"}', home, ".slow", "sessions", "s1.json")
      write('{"cwd":"/Users/you/app"}', home, ".slow", "sessions", "s2.json")
      assert_equal ["/Users/you/app", "/Users/you/zebra"], reading.new(env: env).project_paths
    end
  end

  # cursor_ide already ships the counter-shape — projects/<name>/agent-transcripts/*
  # — where matching the immediate parent would find nothing, silently.
  def test_sessions_for_project_asks_the_adapter_which_directory_holds_the_encoding
    nested = Class.new(AgentSessions::Adapters::Base) do
      agent :nested
      base_dir default: "~/.nested"
      store :sessions, dir: "projects", glob: "*/transcripts/*.jsonl", format: :jsonl

      def encode_project(dir) = File.basename(dir)
      def project_dir_name(path) = File.basename(File.dirname(File.dirname(path)))
    end

    with_home do |home, env|
      touch(home, ".nested", "projects", "app", "transcripts", "s1.jsonl")
      touch(home, ".nested", "projects", "other", "transcripts", "s2.jsonl")
      found = nested.new(env: env).sessions_for_project("/Users/you/app").force
      assert_equal ["s1"], found.map(&:id)
    end
  end

  # Both time hooks take the stat the enumerator already holds, so a session costs
  # one syscall rather than two — and an adapter overriding both to read the same
  # metadata file sees one arity, not two.
  def test_time_hooks_receive_the_stat_the_enumerator_already_took
    timed = Class.new(AgentSessions::Adapters::Base) do
      agent :timed
      base_dir default: "~/.timed"
      store :sessions, dir: "sessions", glob: "*.jsonl", format: :jsonl

      def started_at_for(_path, stat) = stat.mtime - 60
    end

    with_home do |home, env|
      path = touch(home, ".timed", "sessions", "s1.jsonl")
      session = timed.new(env: env).sessions.first
      assert_equal File.mtime(path) - 60, session.started_at
      assert_equal File.mtime(path), session.updated_at
    end
  end

  # Enumeration is lazy, so the window between the glob and a stat spans the whole
  # listing — and agents rotate and compact these logs while a caller reads them.
  def test_sessions_skip_files_that_vanish_after_the_glob
    with_home do |home, env|
      gone = touch(home, ".fake", "sessions", "gone.jsonl")
      touch(home, ".fake", "sessions", "kept.jsonl")
      sessions = FakeAdapter.new(env: env).sessions
      FileUtils.rm(gone)
      assert_equal ["kept"], sessions.force.map(&:id)
    end
  end

  # The vanished-file rescue must not extend to the hooks. If it did, an adapter
  # whose started_at_for raised EACCES would return an empty listing instead of
  # failing — a misdeclared adapter erasing sessions, which is exactly the silent
  # under-reporting this gem treats as its worst outcome.
  def test_a_raising_hook_surfaces_instead_of_erasing_the_session
    broken = Class.new(AgentSessions::Adapters::Base) do
      agent :broken
      label "Broken"
      documented true
      verified_on "2026-07-01"
      base_dir default: "~/.broken"
      store :sessions, dir: "sessions", glob: "*.jsonl", format: :jsonl

      def started_at_for(_path, _stat) = raise(Errno::EACCES, "metadata")
    end

    with_home do |home, env|
      touch(home, ".broken", "sessions", "a.jsonl")
      assert_raises(Errno::EACCES) { broken.new(env: env).sessions.force }
    end
  end

  # Location#enumerable? exists so "no layout to enumerate" and "enumerated, found
  # none" stay apart. Returning [] here would make the first look like the second.
  def test_sessions_refuse_a_primary_store_with_no_known_layout
    shapeless = Class.new(AgentSessions::Adapters::Base) do
      agent :shapeless
      base_dir default: "~/.shapeless"
      store :sessions, dir: "sessions", format: :json # no glob: no way in
    end

    error = assert_raises(AgentSessions::Error) { shapeless.new(env: { "HOME" => "/h" }).sessions }
    assert_includes error.message, "shapeless"
    assert_includes error.message, "sessions"
  end

  # --- scan_jsonl_for_key: the shared bounded read every Layer 2 adapter uses ---

  def test_scan_jsonl_finds_a_record_on_a_later_line
    with_home do |home|
      path = write(%({"a":1}\n{"cwd":"/p"}\n), home, "s.jsonl")
      assert_equal "/p", scan(path, "cwd")["cwd"]
    end
  end

  def test_scan_jsonl_stops_at_the_line_limit
    with_home do |home|
      lines = Array.new(29) { '{"a":1}' } + ['{"cwd":"/p"}']
      path = write("#{lines.join("\n")}\n", home, "s.jsonl")
      assert_nil scan(path, "cwd")
      assert_equal "/p", scan(path, "cwd", limit: 30)["cwd"]
    end
  end

  def test_scan_jsonl_survives_lines_that_are_not_json
    with_home do |home|
      path = write(%(not json at all\n\n{"cwd":"/p"}\n), home, "s.jsonl")
      assert_equal "/p", scan(path, "cwd")["cwd"]
    end
  end

  # A JSONL log is not guaranteed to hold only objects, and #key? on an array or
  # a scalar raised NoMethodError straight out of the method.
  def test_scan_jsonl_survives_json_lines_that_are_not_objects
    with_home do |home|
      path = write(%([1,2,3]\nnull\n42\n"str"\ntrue\n{"cwd":"/p"}\n), home, "s.jsonl")
      assert_equal "/p", scan(path, "cwd")["cwd"]
    end
  end

  # The line limit bounds iterations, not bytes: one record carrying a pasted file
  # is routinely tens of MB. Reading it as MAX_LINE_BYTES chunks caps the memory,
  # and those chunks count against the limit — which is what this pins. Unchunked,
  # the blob is a single line and the record below it is found within any limit.
  def test_scan_jsonl_reads_an_over_long_line_in_bounded_chunks
    with_home do |home|
      blob = "x" * ((AgentSessions::Adapters::Base::MAX_LINE_BYTES * 2) + 100)
      path = write(%({"junk":"#{blob}"}\n{"cwd":"/p"}\n), home, "s.jsonl")
      assert_nil scan(path, "cwd", limit: 2)
      assert_equal "/p", scan(path, "cwd")["cwd"]
    end
  end

  def test_scan_jsonl_returns_nil_for_a_file_that_is_not_there
    assert_nil scan("/no/such/session.jsonl", "cwd")
  end

  # Presence of the key alone is not "found": without a predicate, a null
  # value still stops the scan and the caller gets a record whose value is
  # unusable — this is the shadowing bug item 3 of the 2026-08-05 review
  # caught, reproduced at the shared-helper level so all seven adapters see
  # the same fix.
  def test_scan_jsonl_without_a_predicate_stops_at_a_null_valued_key
    with_home do |home|
      path = write(%({"cwd":null}\n{"cwd":"/p"}\n), home, "s.jsonl")
      record = scan(path, "cwd")
      refute_nil record
      assert_nil record["cwd"]
    end
  end

  def test_scan_jsonl_predicate_skips_a_null_value_and_finds_the_later_record
    with_home do |home|
      path = write(%({"cwd":null}\n{"cwd":"/p"}\n), home, "s.jsonl")
      record = scan(path, "cwd") { |r| r["cwd"].is_a?(String) }
      assert_equal "/p", record["cwd"]
    end
  end

  def test_scan_jsonl_predicate_skips_wrong_typed_values
    with_home do |home|
      path = write(%({"cwd":42}\n{"cwd":{"x":1}}\n{"cwd":"/p"}\n), home, "s.jsonl")
      record = scan(path, "cwd") { |r| r["cwd"].is_a?(String) }
      assert_equal "/p", record["cwd"]
    end
  end

  def test_scan_jsonl_predicate_rejecting_everything_returns_nil
    with_home do |home|
      path = write(%({"cwd":1}\n{"cwd":2}\n), home, "s.jsonl")
      assert_nil scan(path, "cwd") { |r| r["cwd"].is_a?(String) }
    end
  end

  private

  # scan_jsonl_for_key is private — it is an adapter's tool, not a public API.
  def scan(path, key, **options, &block)
    FakeAdapter.new(env: {}).send(:scan_jsonl_for_key, path, key, **options, &block)
  end
end
