# frozen_string_literal: true

require "test_helper"

load File.expand_path("../bin/generate_llm.rb", __dir__)

class LlmGeneratorTest < Minitest::Test
  include FixtureHelpers

  def setup
    @root = Dir.mktmpdir("agent_sessions_llm_generator")
    @stdout = StringIO.new
    @stderr = StringIO.new
  end

  def teardown
    FileUtils.remove_entry(root)
  end

  def test_writes_sorted_documentation_links_and_replaces_the_stale_index
    write("# Agent Sessions\n\nOverview.\n\n# Documentation\n\n- [Stale](stale.md)\n", main_document)
    write("# Message\n", root, "doc", "Agent", "Sessions", "Message.md")
    write("# Advanced\n", root, "doc", "Agent", "Sessions", "Guides", "Advanced.md")
    write("# Adapter\n", root, "doc", "Agent", "Sessions", "Adapter.md")
    write("# Unrelated\n", root, "doc", "Unrelated.md")

    assert generator.call

    assert_equal <<~MARKDOWN, File.read(main_document)
      # Agent Sessions

      Overview.

      # Documentation

      - [Sessions/Adapter.md](Sessions/Adapter.md)
      - [Sessions/Guides/Advanced.md](Sessions/Guides/Advanced.md)
      - [Sessions/Message.md](Sessions/Message.md)
    MARKDOWN
    assert_equal <<~MARKDOWN, File.read(File.join(root, "llm.txt"))
      # Agent Sessions

      Overview.

      # Documentation

      - [doc/Agent/Sessions/Adapter.md](doc/Agent/Sessions/Adapter.md)
      - [doc/Agent/Sessions/Guides/Advanced.md](doc/Agent/Sessions/Guides/Advanced.md)
      - [doc/Agent/Sessions/Message.md](doc/Agent/Sessions/Message.md)
    MARKDOWN
    assert_equal "Updated #{main_document} (3 links)\n", stdout.string
    assert_empty stderr.string
  end

  def test_replaces_only_the_documentation_section_before_the_next_level_one_heading
    write(<<~MARKDOWN, main_document)
      # Agent Sessions

      # Documentation

      - [Stale](stale.md)

      # Examples

      This content must remain.
    MARKDOWN
    write("# Message\n", root, "doc", "Agent", "Sessions", "Message.md")

    assert generator.call

    assert_equal <<~MARKDOWN, File.read(main_document)
      # Agent Sessions

      # Documentation

      - [Sessions/Message.md](Sessions/Message.md)

      # Examples

      This content must remain.
    MARKDOWN
  end

  def test_escapes_labels_and_percent_encodes_destinations_for_unusual_filenames
    write("# Agent Sessions\n", main_document)
    write("# Unusual\n", root, "doc", "Agent", "Sessions", "A [draft] (v1)\nnotes.md")

    assert generator.call

    assert_equal <<~'MARKDOWN', File.read(main_document)
      # Agent Sessions

      # Documentation

      - [Sessions/A \[draft\] (v1)\nnotes.md](Sessions/A%20%5Bdraft%5D%20%28v1%29%0Anotes.md)
    MARKDOWN
    assert_equal <<~'MARKDOWN', File.read(File.join(root, "llm.txt"))
      # Agent Sessions

      # Documentation

      - [doc/Agent/Sessions/A \[draft\] (v1)\nnotes.md](doc/Agent/Sessions/A%20%5Bdraft%5D%20%28v1%29%0Anotes.md)
    MARKDOWN
  end

  def test_replaces_a_crlf_documentation_section_and_normalizes_generated_output_to_lf
    write("# Agent Sessions\r\n\r\n# Documentation\r\n\r\n- [Stale](stale.md)\r\n", main_document)
    write("# Message\n", root, "doc", "Agent", "Sessions", "Message.md")

    assert generator.call

    assert_equal <<~MARKDOWN, File.read(main_document)
      # Agent Sessions

      # Documentation

      - [Sessions/Message.md](Sessions/Message.md)
    MARKDOWN
    assert_equal <<~MARKDOWN, File.read(File.join(root, "llm.txt"))
      # Agent Sessions

      # Documentation

      - [doc/Agent/Sessions/Message.md](doc/Agent/Sessions/Message.md)
    MARKDOWN
  end

  def test_is_byte_for_byte_idempotent
    write("# Agent Sessions\n", main_document)
    write("# Message\n", root, "doc", "Agent", "Sessions", "Message.md")

    assert generator.call
    first_main = File.binread(main_document)
    first_llm = File.binread(File.join(root, "llm.txt"))

    assert generator.call
    assert_equal first_main, File.binread(main_document)
    assert_equal first_llm, File.binread(File.join(root, "llm.txt"))
  end

  def test_returns_false_without_writing_llm_txt_when_the_main_document_is_missing
    write("existing llm content\n", root, "llm.txt")

    refute generator.call

    assert_equal "existing llm content\n", File.read(File.join(root, "llm.txt"))
    assert_empty stdout.string
    assert_equal "Missing #{main_document}\n", stderr.string
  end

  def test_reports_an_absolute_main_document_path_for_a_relative_root
    relative_root = File.join("tmp", "missing-agent-sessions-project")
    relative_stderr = StringIO.new

    refute LlmGenerator.new(root: relative_root, stdout: StringIO.new, stderr: relative_stderr).call

    expected_main_document = File.expand_path(File.join(relative_root, "doc", "Agent", "Sessions.md"))
    assert_equal "Missing #{expected_main_document}\n", relative_stderr.string
  end

  private

  attr_reader :root, :stdout, :stderr

  def main_document
    File.join(root, "doc", "Agent", "Sessions.md")
  end

  def generator
    LlmGenerator.new(root: root, stdout: stdout, stderr: stderr)
  end
end
