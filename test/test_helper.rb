# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "agent_sessions"

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "stringio"

module FixtureHelpers
  # Yields a throwaway HOME and an env hash pointing at it.
  # All Layer 1 tests resolve paths against this fake home, never the real one.
  def with_home
    Dir.mktmpdir("agent_sessions") do |home|
      yield home, { "HOME" => home }
    end
  end

  def touch(*segments)
    path = File.join(*segments)
    FileUtils.mkdir_p(File.dirname(path))
    FileUtils.touch(path)
    path
  end

  def write(content, *segments)
    path = File.join(*segments)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end
end
