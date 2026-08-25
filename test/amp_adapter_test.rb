# frozen_string_literal: true

require_relative "test_helper"

class AmpAdapterTest < Minitest::Test
  include AdapterConformance

  def adapter_class = Agent::Sessions::Adapters::Amp

  # Real thread shape, verified 2026-08-05: created is epoch ms and
  # env.initial.trees[0].uri carries the project as a file:// URI.
  def build_fixture(home)
    thread = {
      v: 5, id: "T-0192aa", created: 1_752_484_323_000, title: "fixture",
      env: { initial: { trees: [{ displayName: "app", uri: "file:///Users/you/app" }] } },
      messages: []
    }
    write(JSON.generate(thread), home, ".local", "share", "amp", "threads", "T-0192aa.json")
  end

  def expected_session_id = "T-0192aa"
  def expected_project_path = "/Users/you/app"

  def expected_default_path(home) = File.join(home, ".local", "share", "amp", "threads")

  def override_env = { "XDG_DATA_HOME" => "/xdg/data" }
  def expected_override_path = "/xdg/data/amp/threads"

  def test_partly_documented_is_not_documented
    with_home do |_home, env|
      store = Agent::Sessions.locate(:amp, env: env)
      assert_equal :partly, store.documented
      refute store.documented?
    end
  end

  def test_warns_that_local_copy_is_partial
    with_home do |_home, env|
      store = Agent::Sessions.locate(:amp, env: env)
      assert(store.warnings.any? { |w| w.include?("canonical") })
    end
  end

  # secrets.json is optional (see verify_test) but must stay declared, so that audit
  # can still report a plaintext token file sitting inside a sync folder.
  def test_secrets_stays_a_layer_so_audit_can_see_it
    with_home do |_home, env|
      store = Agent::Sessions.locate(:amp, env: env)
      assert_includes store.layers.map(&:kind), :secrets
    end
  end

  def test_project_path_decodes_percent_escapes_in_the_file_uri
    with_home do |home, env|
      thread = { env: { initial: { trees: [{ uri: "file:///Users/you/My%20Drive/app" }] } } }
      write(JSON.generate(thread), home, ".local", "share", "amp", "threads", "T-b.json")
      session = Agent::Sessions::Adapters::Amp.new(env: env).sessions.first
      assert_equal "/Users/you/My Drive/app", session.project_path
    end
  end

  def test_threads_without_trees_have_no_project
    with_home do |home, env|
      write(JSON.generate({ id: "T-c", messages: [] }),
            home, ".local", "share", "amp", "threads", "T-c.json")
      assert_nil Agent::Sessions::Adapters::Amp.new(env: env).sessions.first.project_path
    end
  end

  def test_fidelity_is_messages
    assert_equal :messages, Agent::Sessions::Adapters::Amp.fidelity_value
  end

  # --- Malformed-shape guards -------------------------------------------------
  # project_path_for used to reach these via a single 5-key #dig, which raises
  # TypeError the instant an intermediate value is present but not itself
  # diggable — a real risk against a partial mirror, not a hypothetical one.
  # Each test below is one such intermediate gone wrong; presence alone (rule
  # 1) is not enough at any of these levels, only at the leaf.
  #
  # Each fixture below uses an Array or Integer, never a String, as the wrong
  # value. That distinction matters: hand-rolled `[]` does NOT raise on a
  # String intermediate the way #dig does — "not-a-hash"["trees"] is just a
  # substring search returning nil — so a String fixture happens to still
  # return the right answer even with its matching guard deleted, and a
  # mutation-testing pass proved exactly that: the original String-based
  # fixtures here did not discriminate. Array/Integer intermediates raise
  # TypeError (or NoMethodError, for `.first`) from plain `[]`/`.first` the
  # same way a String intermediate raises from `#dig`, so removing any one
  # guard below turns its test from a passing assertion into an uncaught
  # exception — proof the guard is load-bearing, not merely written.

  def test_project_path_returns_nil_when_the_whole_thread_is_not_a_hash
    with_home do |home, env|
      write(JSON.generate([1, 2, 3]), home, ".local", "share", "amp", "threads", "T-array.json")
      assert_nil Agent::Sessions::Adapters::Amp.new(env: env).sessions.first.project_path
    end
  end

  def test_project_path_returns_nil_when_env_is_not_a_hash
    with_home do |home, env|
      thread = { env: [1, 2] }
      write(JSON.generate(thread), home, ".local", "share", "amp", "threads", "T-env-array.json")
      assert_nil Agent::Sessions::Adapters::Amp.new(env: env).sessions.first.project_path
    end
  end

  def test_project_path_returns_nil_when_env_initial_is_not_a_hash
    with_home do |home, env|
      thread = { env: { initial: [1, 2] } }
      write(JSON.generate(thread), home, ".local", "share", "amp", "threads", "T-initial-array.json")
      assert_nil Agent::Sessions::Adapters::Amp.new(env: env).sessions.first.project_path
    end
  end

  def test_project_path_returns_nil_when_trees_is_not_an_array
    with_home do |home, env|
      thread = { env: { initial: { trees: 5 } } }
      write(JSON.generate(thread), home, ".local", "share", "amp", "threads", "T-trees-integer.json")
      assert_nil Agent::Sessions::Adapters::Amp.new(env: env).sessions.first.project_path
    end
  end

  def test_project_path_returns_nil_when_the_first_tree_is_not_a_hash
    with_home do |home, env|
      thread = { env: { initial: { trees: [[1, 2]] } } }
      write(JSON.generate(thread), home, ".local", "share", "amp", "threads", "T-tree-array.json")
      assert_nil Agent::Sessions::Adapters::Amp.new(env: env).sessions.first.project_path
    end
  end

  # Kept for the same defense-in-depth reason the adapter comment gives: every
  # JSON type this could realistically be (Hash included) makes URI.parse
  # raise URI::InvalidURIError, which the narrower rescue below already turns
  # into nil on its own — so, unlike the four guards above, this fixture does
  # NOT prove uri.is_a?(String) is load-bearing. It is here anyway to pin the
  # observable behavior (a non-String uri is a nil project, not a raise)
  # regardless of which layer ends up answering for it.
  def test_project_path_returns_nil_when_uri_is_not_a_string
    with_home do |home, env|
      thread = { env: { initial: { trees: [{ uri: { a: 1 } }] } } }
      write(JSON.generate(thread), home, ".local", "share", "amp", "threads", "T-uri-hash.json")
      assert_nil Agent::Sessions::Adapters::Amp.new(env: env).sessions.first.project_path
    end
  end

  # --- file:// URI edge cases --------------------------------------------------

  # Deliberately "https:///Users/you/x" (empty host), not
  # "https://example.com/x": a non-empty host would already be rejected by
  # the host check below, which would let this test pass even with the
  # scheme check deleted — proving nothing about the scheme check itself.
  # An empty-host, non-file scheme isolates it: without the scheme check,
  # this would decode to a wrong-but-present "/Users/you/x" instead of nil.
  def test_project_path_rejects_a_non_file_scheme
    with_home do |home, env|
      thread = { env: { initial: { trees: [{ uri: "https:///Users/you/x" }] } } }
      write(JSON.generate(thread), home, ".local", "share", "amp", "threads", "T-https.json")
      assert_nil Agent::Sessions::Adapters::Amp.new(env: env).sessions.first.project_path
    end
  end

  def test_project_path_accepts_the_localhost_authority_form
    with_home do |home, env|
      thread = { env: { initial: { trees: [{ uri: "file://localhost/Users/you/app" }] } } }
      write(JSON.generate(thread), home, ".local", "share", "amp", "threads", "T-localhost.json")
      session = Agent::Sessions::Adapters::Amp.new(env: env).sessions.first
      assert_equal "/Users/you/app", session.project_path
    end
  end

  def test_project_path_rejects_a_remote_host
    with_home do |home, env|
      thread = { env: { initial: { trees: [{ uri: "file://nas/share" }] } } }
      write(JSON.generate(thread), home, ".local", "share", "amp", "threads", "T-nas.json")
      assert_nil Agent::Sessions::Adapters::Amp.new(env: env).sessions.first.project_path
    end
  end

  def test_project_path_is_nil_for_an_opaque_relative_uri
    with_home do |home, env|
      thread = { env: { initial: { trees: [{ uri: "file:relative/path" }] } } }
      write(JSON.generate(thread), home, ".local", "share", "amp", "threads", "T-relative.json")
      assert_nil Agent::Sessions::Adapters::Amp.new(env: env).sessions.first.project_path
    end
  end

  def test_project_path_is_nil_for_an_empty_path
    with_home do |home, env|
      ["file:", "file://", "file://localhost"].each_with_index do |uri, i|
        thread = { env: { initial: { trees: [{ uri: uri }] } } }
        write(JSON.generate(thread), home, ".local", "share", "amp", "threads", "T-empty-#{i}.json")
      end

      sessions = Agent::Sessions::Adapters::Amp.new(env: env).sessions.force
      assert_equal 3, sessions.size
      assert_empty sessions.filter_map(&:project_path)
    end
  end

  # A workspace rooted at "/" is the one case where trailing-slash stripping
  # could regress a real path back into the empty string the test above rejects.
  # Nothing else pins the root guard in the strip.
  def test_a_root_workspace_stays_root_rather_than_becoming_empty
    with_home do |home, env|
      thread = { env: { initial: { trees: [{ uri: "file:///" }] } } }
      write(JSON.generate(thread), home, ".local", "share", "amp", "threads", "T-root.json")
      assert_equal "/", Agent::Sessions::Adapters::Amp.new(env: env).sessions.first.project_path
    end
  end

  # Multiple trailing separators, not just one: "/app//" would otherwise list
  # beside "/app" and be missed by sessions_for_project.
  def test_a_run_of_trailing_separators_is_stripped
    with_home do |home, env|
      thread = { env: { initial: { trees: [{ uri: "file:///Users/you/app//" }] } } }
      write(JSON.generate(thread), home, ".local", "share", "amp", "threads", "T-slashes.json")
      assert_equal "/Users/you/app", Agent::Sessions::Adapters::Amp.new(env: env).sessions.first.project_path
    end
  end

  # The multi-root caveat is a "here is what breaks, please send this back"
  # report, so it is gated on the store existing — a user with no Amp installed
  # cannot act on it. Its ungated sibling above is a permanent property of the
  # agent and is worth reading before adopting the gem.
  def test_multi_root_warning_appears_only_once_the_store_exists
    with_home do |home, env|
      refute(Agent::Sessions.locate(:amp, env: env).warnings.any? { |w| w.include?("workspace tree") })
      build_fixture(home)
      assert(Agent::Sessions.locate(:amp, env: env).warnings.any? { |w| w.include?("workspace tree") })
    end
  end

  def test_project_path_strips_a_trailing_slash
    with_home do |home, env|
      thread = { env: { initial: { trees: [{ uri: "file:///Users/you/app/" }] } } }
      write(JSON.generate(thread), home, ".local", "share", "amp", "threads", "T-trailing.json")
      session = Agent::Sessions::Adapters::Amp.new(env: env).sessions.first
      assert_equal "/Users/you/app", session.project_path
    end
  end

  def test_project_path_is_nil_for_an_unescaped_character_in_the_uri
    with_home do |home, env|
      thread = { env: { initial: { trees: [{ uri: "file:///Users/you/a b" }] } } }
      write(JSON.generate(thread), home, ".local", "share", "amp", "threads", "T-unescaped.json")
      assert_nil Agent::Sessions::Adapters::Amp.new(env: env).sessions.first.project_path
    end
  end

  def test_project_path_reports_the_first_of_several_trees
    with_home do |home, env|
      thread = { env: { initial: { trees: [
        { uri: "file:///Users/you/first" },
        { uri: "file:///Users/you/second" }
      ] } } }
      write(JSON.generate(thread), home, ".local", "share", "amp", "threads", "T-multi.json")
      session = Agent::Sessions::Adapters::Amp.new(env: env).sessions.first
      assert_equal "/Users/you/first", session.project_path
    end
  end

  # The blast-radius assertion that actually matters: malformed threads
  # alongside a good one cost exactly those sessions' project_paths, not the
  # whole store. Before the shape fix, TypeError propagating out of
  # project_path_for's #dig would abort Enumerator::Lazy#filter_map/#select
  # entirely, so `sessions` and `project_paths` returned nothing at all — for
  # every agent, not just this one malformed Amp thread. "file:relative/path"
  # is included here (not just as its own test above) because it was the
  # CRITICAL finding: decode_uri_component(nil) raising NoMethodError had the
  # identical total-store blast radius as the #dig bug this test was
  # originally written to pin.
  def test_a_malformed_thread_does_not_take_down_the_whole_store
    with_home do |home, env|
      build_fixture(home)
      write(JSON.generate([1, 2, 3]), home, ".local", "share", "amp", "threads", "T-malformed.json")
      write(JSON.generate({ env: { initial: { trees: [{ uri: "file:relative/path" }] } } }),
            home, ".local", "share", "amp", "threads", "T-bad-uri.json")

      adapter = Agent::Sessions::Adapters::Amp.new(env: env)
      sessions = adapter.sessions.force
      assert_equal 3, sessions.size, "expected the listing to survive both malformed threads"
      assert_equal [expected_project_path], adapter.project_paths
    end
  end
end
