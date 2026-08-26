# frozen_string_literal: true

require "test_helper"
require "open3"
require "rbconfig"

class DocumentationTaskTest < Minitest::Test
  include FixtureHelpers

  def test_yard_task_rebuilds_public_markdown_documentation
    with_project_copy do |copy_dir|
      stale_document = write("stale", copy_dir, "doc", "stale.md")

      stdout, stderr, status = run_yard_task(copy_dir)
      output = stdout + stderr

      assert status.success?, "expected YARD task to succeed, stderr: #{stderr.inspect}, stdout: #{stdout.inspect}"
      refute_includes output, "[warn]:", "expected YARD task to emit no warnings"
      refute File.exist?(stale_document), "expected stale documentation to be removed"
      refute Dir.exist?(File.join(copy_dir, "doc", "docs")), "expected internal docs to be excluded"
      assert File.file?(File.join(copy_dir, "doc", "Agent.md"))
      sessions_document = File.join(copy_dir, "doc", "Agent", "Sessions.md")
      assert File.file?(sessions_document)

      message_document = File.join(copy_dir, "doc", "Agent", "Sessions", "Message.md")
      part_document = File.join(copy_dir, "doc", "Agent", "Sessions", "Part.md")
      assert File.file?(message_document)
      assert File.file?(part_document)
      assert_includes File.read(message_document), "### `ROLES`", "expected Message documentation to include the ROLES constant heading"
      assert_includes File.read(part_document), "### `TYPES`", "expected Part documentation to include the TYPES constant heading"
      assert_includes File.read(sessions_document), "### `all(env: ENV)`"

      generated_markdown = Dir.glob(File.join(copy_dir, "doc", "**", "*.md")).map { File.read(_1) }.join("\n")
      refute_match(/\b[a-z_][a-z0-9_]*: = /i, generated_markdown)
    end
  end

  private

  def run_yard_task(copy_dir)
    gemfile = File.expand_path("../Gemfile", __dir__)

    Open3.capture3(
      {"BUNDLE_GEMFILE" => gemfile},
      RbConfig.ruby,
      "-S",
      "bundle",
      "exec",
      "rake",
      "yard",
      chdir: copy_dir
    )
  end

  def with_project_copy
    Dir.mktmpdir("agent_sessions_documentation") do |copy_dir|
      project_root = File.expand_path("..", __dir__)
      project_inputs = %w[.yardopts Gemfile agent_sessions.gemspec Rakefile README.md lib]

      project_inputs.each do |entry|
        FileUtils.cp_r(File.join(project_root, entry), File.join(copy_dir, entry))
      end

      yield copy_dir
    end
  end
end
