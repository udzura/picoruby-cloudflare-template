# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "picoruby/cloudflare/template/project"

class ProjectWranglerTest < Test::Unit::TestCase
  class Project < Picoruby::Cloudflare::Template::Project
    attr_reader :built, :command
    def build
      @built = true
    end
    def system(*args, **options)
      @command = [args, options]
      true
    end
  end

  test "Wrangler uses the generated integration config and matching environment after building" do
    Dir.mktmpdir("project-wrangler-test") do |root|
      executable = File.join(root, "node_modules/.bin/wrangler")
      FileUtils.mkdir_p(File.dirname(executable))
      File.write(executable, "")
      File.chmod(0o755, executable)
      project = Project.new(root: root)
      previous = ENV["CLOUDFLARE_ENV"]
      begin
        ENV["CLOUDFLARE_ENV"] = "staging"
        project.wrangler("deploy", "--dry-run")
        assert_true project.built
        assert_equal [executable, "deploy", "--config", File.join(root, "wrangler.jsonc"), "--dry-run", "--env", "staging"], project.command.first
        generated = File.join(root, ".picoruby-cloudflare-wrangler.jsonc")
        File.write(generated, "generated")
        project.wrangler("dev")
        assert_equal [executable, "dev", "--config", generated, "--env", "staging"], project.command.first
        assert_equal({ chdir: root }, project.command.last)
      ensure
        ENV["CLOUDFLARE_ENV"] = previous
      end
    end
  end
end
