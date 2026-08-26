# frozen_string_literal: true

require "test_helper"
require "bundler"
require "json"
require "open3"
require "rbconfig"
require "rubygems/package"
require "uri"

class PackagingTest < Minitest::Test
  PROJECT_COPY_ENTRIES = %w[
    CHANGELOG.md
    Gemfile
    LICENSE.txt
    README.md
    Rakefile
    agent_sessions.gemspec
    bin
    doc
    exe
    lib
    llm.txt
    test
  ].freeze
  EXPECTED_SOURCE_FILES = %w[
    CHANGELOG.md
    LICENSE.txt
    README.md
    exe/agent-sessions
    lib/agent/sessions.rb
    lib/agent/sessions/adapters/amp.rb
    lib/agent/sessions/adapters/base.rb
    lib/agent/sessions/adapters/claude.rb
    lib/agent/sessions/adapters/codex.rb
    lib/agent/sessions/adapters/copilot.rb
    lib/agent/sessions/adapters/cursor.rb
    lib/agent/sessions/adapters/cursor_ide.rb
    lib/agent/sessions/adapters/enumeration.rb
    lib/agent/sessions/adapters/gemini.rb
    lib/agent/sessions/adapters/grok.rb
    lib/agent/sessions/adapters/opencode.rb
    lib/agent/sessions/adapters/pi.rb
    lib/agent/sessions/adapters/qwen.rb
    lib/agent/sessions/audit.rb
    lib/agent/sessions/check.rb
    lib/agent/sessions/cli.rb
    lib/agent/sessions/compaction.rb
    lib/agent/sessions/env_override.rb
    lib/agent/sessions/error.rb
    lib/agent/sessions/home_expansion.rb
    lib/agent/sessions/location.rb
    lib/agent/sessions/message.rb
    lib/agent/sessions/missing_dependency.rb
    lib/agent/sessions/node.rb
    lib/agent/sessions/part.rb
    lib/agent/sessions/readers/amp.rb
    lib/agent/sessions/readers/base.rb
    lib/agent/sessions/readers/claude.rb
    lib/agent/sessions/readers/codex.rb
    lib/agent/sessions/readers/copilot.rb
    lib/agent/sessions/readers/gemini.rb
    lib/agent/sessions/readers/grok.rb
    lib/agent/sessions/readers/opencode.rb
    lib/agent/sessions/readers/pi.rb
    lib/agent/sessions/readers/qwen.rb
    lib/agent/sessions/session.rb
    lib/agent/sessions/sqlite.rb
    lib/agent/sessions/store.rb
    lib/agent/sessions/unknown_agent.rb
    lib/agent/sessions/unreadable_store.rb
    lib/agent/sessions/unsupported_format.rb
    lib/agent/sessions/usage.rb
    lib/agent/sessions/version.rb
    lib/agent_sessions.rb
  ].freeze

  def test_gemspec_exposes_release_metadata_and_dependencies
    spec = specification

    assert_equal "agent_sessions", spec.name
    assert_equal "0.3.1", spec.version.to_s
    assert_equal "Locate, verify, and read AI coding agent session logs", spec.summary
    assert_equal "MIT", spec.license
    assert_equal "https://github.com/lucianghinda/agent_sessions", spec.homepage
    assert_equal ">= 3.2.0", spec.required_ruby_version.to_s
    assert_equal spec.homepage, spec.metadata["source_code_uri"]
    assert_equal "#{spec.homepage}/issues", spec.metadata["bug_tracker_uri"]
    assert_equal "#{spec.homepage}/blob/main/CHANGELOG.md", spec.metadata["changelog_uri"]
    assert_equal "true", spec.metadata["rubygems_mfa_required"]

    dependencies = spec.runtime_dependencies.to_h do |dependency|
      [dependency.name, dependency.requirement.to_s]
    end
    assert_equal({"agent_homedir" => "~> 0.3", "zeitwerk" => "~> 2.8"}, dependencies)
  end

  def test_current_release_is_documented
    assert_includes File.read(File.expand_path("../CHANGELOG.md", __dir__)), "## 0.3.1 (2026-08-26)"
  end

  def test_release_artifacts_are_ignored
    patterns = File.readlines(File.expand_path("../.gitignore", __dir__), chomp: true)

    assert_includes patterns, "*.gem"
  end

  def test_manifest_is_exact_and_buildable_without_git
    with_non_git_copy do |copy_dir|
      assert File.file?(File.join(copy_dir, "Gemfile"))
      assert File.file?(File.join(copy_dir, "Gemfile.lock"))
      assert File.file?(File.join(copy_dir, "Rakefile"))
      assert Dir.exist?(File.join(copy_dir, "bin"))
      assert Dir.exist?(File.join(copy_dir, "test"))

      result = build_gem(copy_dir)
      files = result.fetch("files")

      assert_equal expected_packaged_files, files
      refute files.any? { |path| path.start_with?("bin/", "docs/", "test/") }
      refute_includes files, "Gemfile"
      refute_includes files, "Gemfile.lock"
      refute_includes files, "Rakefile"
      assert result.fetch("built")
    end
  end

  def test_every_local_link_in_packaged_documentation_is_packaged
    project_root = File.expand_path("..", __dir__)
    packaged_files = specification.files
    documents = (packaged_files.select { File.extname(_1) == ".md" } + ["llm.txt"]).uniq
    link_count = 0
    invalid_links = []

    documents.each do |source|
      source_path = File.join(project_root, source)
      assert File.file?(source_path), "expected packaged Markdown source #{source} to exist"

      File.read(source_path).scan(/\]\(([^)]+)\)/).flatten.each do |destination|
        next if destination.start_with?("#", "/") || destination.match?(/\A[a-z][a-z0-9+.-]*:/i)

        link_count += 1
        target = resolve_local_destination(source_path, destination)
        link = "#{source} -> #{destination}"
        within_project = target == project_root || target.start_with?("#{project_root}/")

        unless within_project
          invalid_links << "#{link} resolves outside the project to #{target}"
          next
        end
        unless File.file?(target)
          invalid_links << "#{link} resolves to missing file #{target}"
          next
        end

        packaged_target = target.delete_prefix("#{project_root}/")
        unless packaged_files.include?(packaged_target)
          invalid_links << "#{link} resolves to unpackaged file #{packaged_target}"
        end
      end
    end

    assert_operator link_count, :>, 0
    assert_empty invalid_links, "invalid packaged documentation links:\n#{invalid_links.join("\n")}"
  end

  def test_local_destination_uses_the_uri_path
    source = File.join(File::SEPARATOR, "project", "doc", "README.md")

    assert_equal File.join(File::SEPARATOR, "project", "doc", "guide.md"),
      resolve_local_destination(source, "guide.md?plain=1#usage")
  end

  def test_query_only_destination_resolves_to_the_containing_document
    source = File.join(File::SEPARATOR, "project", "doc", "README.md")

    assert_equal source, resolve_local_destination(source, "?plain=1#usage")
  end

  def test_built_gem_installs_and_runs_its_cli_in_isolation
    with_non_git_copy do |copy_dir|
      built_gem = build_gem(copy_dir).fetch("gem")
      gem_home = File.join(copy_dir, "tmp", "gems")
      FileUtils.mkdir_p(gem_home)
      %w[agent_homedir zeitwerk].each do |name|
        copy_installed_gem(Gem::Specification.find_by_name(name), gem_home)
      end

      install_gem(File.join(copy_dir, built_gem), gem_home)
      stdout, stderr, status = run_isolated_cli(gem_home, "version")

      assert status.success?, "expected installed CLI to run, stderr: #{stderr.inspect}, stdout: #{stdout.inspect}"
      assert_equal "0.3.1\n", stdout
      assert_empty stderr
    end
  end

  private

  def resolve_local_destination(source, destination)
    path = URI.decode_uri_component(URI.parse(destination).path)

    path.empty? ? source : File.expand_path(path, File.dirname(source))
  end

  def specification
    Gem::Specification.load(File.expand_path("../agent_sessions.gemspec", __dir__))
  end

  def expected_packaged_files
    documentation_files = Dir.glob(File.expand_path("../doc/**/*.{csv,md}", __dir__))
      .select { File.file?(_1) }
      .map { _1.delete_prefix("#{File.expand_path("..", __dir__)}/") }

    (EXPECTED_SOURCE_FILES + ["llm.txt"] + documentation_files).sort
  end

  def build_gem(copy_dir)
    script = <<~'RUBY'
      require "json"
      require "rubygems/package"

      spec = Gem::Specification.load("agent_sessions.gemspec")
      built_gem = Gem::Package.build(spec)
      puts JSON.generate(files: spec.files.sort, gem: built_gem, built: File.exist?(built_gem))
    RUBY
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-e", script, chdir: copy_dir)

    assert status.success?, "expected gem build to succeed, stderr: #{stderr.inspect}, stdout: #{stdout.inspect}"
    JSON.parse(stdout.lines.last)
  end

  def install_gem(gem_file, gem_home)
    stdout = stderr = status = nil
    Bundler.with_unbundled_env do
      stdout, stderr, status = Open3.capture3(
        {"GEM_HOME" => gem_home, "GEM_PATH" => gem_home},
        RbConfig.ruby,
        "-S",
        "gem",
        "install",
        "--install-dir",
        gem_home,
        "--local",
        "--ignore-dependencies",
        "--no-document",
        gem_file
      )
    end
    assert status.success?, "expected gem install to succeed, stderr: #{stderr.inspect}, stdout: #{stdout.inspect}"
  end

  def run_isolated_cli(gem_home, *arguments)
    Bundler.with_unbundled_env do
      Open3.capture3(
        {"GEM_HOME" => gem_home, "GEM_PATH" => gem_home},
        RbConfig.ruby,
        File.join(gem_home, "bin", "agent-sessions"),
        *arguments
      )
    end
  end

  def copy_installed_gem(spec, gem_home)
    gems_dir = File.join(gem_home, "gems")
    specifications_dir = File.join(gem_home, "specifications")
    FileUtils.mkdir_p(gems_dir)
    FileUtils.mkdir_p(specifications_dir)
    FileUtils.cp_r(spec.full_gem_path, File.join(gems_dir, spec.full_name))
    FileUtils.cp(spec.spec_file, File.join(specifications_dir, "#{spec.full_name}.gemspec"))
  end

  def with_non_git_copy
    Dir.mktmpdir do |dir|
      project_root = File.expand_path("..", __dir__)

      PROJECT_COPY_ENTRIES.each do |entry|
        FileUtils.cp_r(File.join(project_root, entry), File.join(dir, entry))
      end
      File.write(File.join(dir, "Gemfile.lock"), "# packaging exclusion fixture\n")

      yield dir
    end
  end
end
