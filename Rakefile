# frozen_string_literal: true

require "bundler/gem_tasks"
require "fileutils"
require "minitest/test_task"
require "yard-markdown"

# yard-markdown 0.9.1 adds a positional-argument separator after keyword names.
module YardMarkdownKeywordSignatures
  def method_signature(method_object)
    parameters = Array(method_object.parameters).map do |name, default|
      name = name.to_s
      default = default.to_s
      next name if default.empty?

      "#{name}#{name.end_with?(":") ? " " : " = "}#{default}"
    end

    "(#{parameters.join(", ")})"
  end
end

YARD::Markdown::MethodPresentationHelper.singleton_class.prepend(YardMarkdownKeywordSignatures)

Minitest::TestTask.create

YARD::Rake::YardocTask.new do |task|
  task.before = -> { FileUtils.rm_rf(File.expand_path("doc", __dir__)) }
end

task default: :test
