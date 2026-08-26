# frozen_string_literal: true

require "test_helper"

load File.expand_path("../bin/prepare_release", __dir__)

class PrepareReleaseTest < Minitest::Test
  def test_runs_tests_and_builds_from_the_repository_root
    events = []
    runner = lambda do |command, working_directory|
      events << [:command, command, working_directory]
      true
    end
    builder = lambda do |working_directory|
      events << [:build, working_directory]
      true
    end

    assert ReleasePreparer.new(root: root, ruby: ruby, runner: runner, builder: builder).call
    assert_equal [
      *expected_commands.map { [:command, _1, root] },
      [:build, root]
    ], events
  end

  def test_stops_before_building_when_tests_fail
    stderr = StringIO.new
    builder = ->(_working_directory) { flunk "builder should not run after failed tests" }

    result = ReleasePreparer.new(
      root: root,
      ruby: ruby,
      runner: ->(_command, _working_directory) { false },
      builder: builder,
      stderr: stderr
    ).call

    refute result
    assert_equal "Release preparation failed: #{expected_commands.first.join(" ")}\n", stderr.string
  end

  def test_stops_when_documentation_generation_fails
    assert_stops_after_failed_command(expected_commands[1])
  end

  def test_stops_when_llm_generation_fails
    assert_stops_after_failed_command(expected_commands[2])
  end

  def test_reports_a_failed_gem_build
    stderr = StringIO.new

    result = ReleasePreparer.new(
      root: root,
      ruby: ruby,
      runner: ->(_command, _working_directory) { true },
      builder: ->(_working_directory) { false },
      stderr: stderr
    ).call

    refute result
    assert_equal "Release preparation failed: build agent_sessions.gemspec\n", stderr.string
  end

  def test_reports_an_exception_raised_while_building_the_gem
    stderr = StringIO.new
    builder = lambda do |_working_directory|
      fail Gem::InvalidSpecificationException, "invalid gem metadata"
    end

    result = ReleasePreparer.new(
      root: root,
      ruby: ruby,
      runner: ->(_command, _working_directory) { true },
      builder: builder,
      stderr: stderr
    ).call

    refute result
    assert_equal <<~MESSAGE, stderr.string
      Release preparation failed: build agent_sessions.gemspec (Gem::InvalidSpecificationException: invalid gem metadata)
    MESSAGE
  end

  private

  def root = "/project"

  def ruby = "/ruby"

  def expected_commands
    [
      [ruby, "-S", "bundle", "exec", "rake", "test"],
      [ruby, "-S", "bundle", "exec", "rake", "yard"],
      [ruby, File.join(root, "bin", "generate_llm.rb")]
    ]
  end

  def assert_stops_after_failed_command(failed_command)
    commands = []
    stderr = StringIO.new
    runner = lambda do |command, _working_directory|
      commands << command
      command != failed_command
    end
    builder = ->(_working_directory) { flunk "builder should not run after failed documentation generation" }

    result = ReleasePreparer.new(
      root: root,
      ruby: ruby,
      runner: runner,
      builder: builder,
      stderr: stderr
    ).call

    refute result
    assert_equal expected_commands.take(expected_commands.index(failed_command) + 1), commands
    assert_equal "Release preparation failed: #{failed_command.join(" ")}\n", stderr.string
  end
end
