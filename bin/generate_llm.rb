#!/usr/bin/env ruby
# frozen_string_literal: true

require "uri"

class LlmGenerator
  MAIN_DOCUMENT = File.join("doc", "Agent", "Sessions.md")
  DOCUMENTATION_HEADING = /^# Documentation[ \t]*$/

  def initialize(root: File.expand_path("..", __dir__), stdout: $stdout, stderr: $stderr)
    @root = File.expand_path(root)
    @stdout = stdout
    @stderr = stderr
  end

  def call
    unless File.file?(main_document)
      stderr.puts "Missing #{main_document}"
      return false
    end

    files = documentation_files
    relative_links = files.map { _1.delete_prefix("#{File.dirname(main_document)}/") }
    updated_document = with_documentation_links(File.read(main_document), relative_links)

    File.write(main_document, updated_document)
    File.write(llm_document, with_documentation_links(updated_document, root_links(files)))
    stdout.puts "Updated #{main_document} (#{files.size} links)"
    true
  end

  private

  attr_reader :root, :stdout, :stderr

  def main_document
    File.join(root, MAIN_DOCUMENT)
  end

  def llm_document
    File.join(root, "llm.txt")
  end

  def documentation_files
    Dir.glob(File.join(root, "doc", "Agent", "Sessions", "**", "*.md"))
      .select { File.file?(_1) }
      .sort
  end

  def root_links(files)
    files.map { _1.delete_prefix("#{root}/") }
  end

  def with_documentation_links(content, links)
    content = content.gsub(/\r\n?/, "\n")
    body, following_content = content_around_documentation(content)
    body = body.rstrip
    section = ["# Documentation", "", *links.map { documentation_link(_1) }].join("\n")
    generated_content = body.empty? ? section : "#{body}\n\n#{section}"

    return "#{generated_content}\n" unless following_content

    result = "#{generated_content}\n\n#{following_content}"
    result.end_with?("\n") ? result : "#{result}\n"
  end

  def documentation_link(path)
    label = path.gsub(/[\[\]\\\r\n]/) do |character|
      { "[" => "\\[", "]" => "\\]", "\\" => "\\\\", "\r" => "\\r", "\n" => "\\n" }.fetch(character)
    end
    destination = path.split("/", -1).map { URI.encode_uri_component(_1) }.join("/")

    "- [#{label}](#{destination})"
  end

  def content_around_documentation(content)
    section_start = content.enum_for(:scan, DOCUMENTATION_HEADING).map { Regexp.last_match.begin(0) }.last
    return [content, nil] unless section_start

    heading_end = content.index("\n", section_start) || content.length
    following_heading = content.index(/^# .+$/, heading_end + 1)

    [content[0...section_start], following_heading ? content[following_heading..] : nil]
  end
end

exit(LlmGenerator.new.call ? 0 : 1) if $PROGRAM_NAME == __FILE__
