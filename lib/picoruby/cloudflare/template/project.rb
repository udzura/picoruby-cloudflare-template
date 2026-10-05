# frozen_string_literal: true

require "open3"
require "rbconfig"
require "rake"
require "fileutils"
require_relative "../template"

module Picoruby::Cloudflare::Template
  class Project
    include Rake::DSL
    def initialize(root:)
      @root = File.expand_path(root)
    end

    def picoruby_root
      path = ENV["PICORUBY_ROOT"]
      raise Error, "Set PICORUBY_ROOT to a PicoRuby checkout with initialized submodules" if path.nil? || path.empty?
      Picoruby::Cloudflare::Template.validate_build_path!(@root)
      Picoruby::Cloudflare::Template.validate_build_path!(File.expand_path(path, @root))
    end

    def doctor(out: $stdout)
      root = picoruby_root
      %w[Rakefile lib/picoruby/build.rb mrbgems/picoruby-mruby/lib/mruby/lib/mruby/build.rb mrbgems/mruby-compiler/lib/prism/include/prism.h].each do |file|
        raise Error, "Missing #{file} in #{root}; initialize PicoRuby submodules" unless File.file?(File.join(root, file))
      end
      %w[emcc emar node].each do |command|
        hint = command == "node" ? "install Node.js supported by Wrangler" : "on macOS, run brew install emscripten and add its bin directory to PATH (see README)"
        output, status = Open3.capture2e(command, "--version")
        raise Error, "#{command} is unavailable: #{output}; #{hint}" unless status.success?
        out.puts output.lines.first
      rescue Errno::ENOENT
        raise Error, "#{command} is not on PATH; #{hint}"
      end
      _, status = Open3.capture2e("node", "-e", "require('jsonc-parser')", chdir: @root)
      raise Error, "jsonc-parser is missing; run npm install in #{@root}" unless status.success?
      out.puts "PicoRuby: #{root}\nReady (compiler version and runtime assets are checked during build)."
      true
    end

    def build
      config = File.join(@root, "build_config.rb")
      raise Error, "Missing #{config}" unless File.file?(config)
      root = picoruby_root
      raise Error, "Missing PicoRuby Rakefile: #{root}" unless File.file?(File.join(root, "Rakefile"))
      env = {
        "MRUBY_CONFIG" => config, "CONFIG" => config,
        "MRUBY_BUILD_DIR" => File.join(@root, ".picoruby-build"),
      }
      library = File.expand_path("../../..", __dir__)
      command = [RbConfig.ruby, "-I", library, Gem.bin_path("rake", "rake"), "-f", File.join(root, "Rakefile"), "all"]
      raise Error, "PicoRuby build failed" unless system(env, *command, chdir: root)
    end

    def wrangler(command, *arguments)
      build
      executable = File.join(@root, "node_modules/.bin/wrangler")
      raise Error, "Wrangler is missing; run npm install in #{@root}" unless File.executable?(executable)
      generated = File.join(@root, ".picoruby-cloudflare-wrangler.jsonc")
      config = File.file?(generated) ? generated : File.join(@root, "wrangler.jsonc")
      args = [executable, command, "--config", config, *arguments]
      args.concat(["--env", ENV["CLOUDFLARE_ENV"]]) if ENV["CLOUDFLARE_ENV"] && !ENV["CLOUDFLARE_ENV"].empty?
      raise Error, "Wrangler #{command} failed" unless system(*args, chdir: @root)
    end

    def clean
      FileUtils.rm_rf(File.join(@root, ".picoruby-build"))
    end

    def define_tasks
      desc "Build PicoRuby and export the Worker ES module"
      task(:build) { build }
      desc "Remove PicoRuby build artifacts"
      task(:clean) { clean }
      desc "Check local Worker build prerequisites"
      task(:doctor) { doctor }
      desc "Build and run the Worker with generated optional integrations"
      task(:dev) { wrangler("dev") }
      desc "Build and validate the Worker bundle without deploying"
      task(:check) { wrangler("deploy", "--dry-run") }
      desc "Build and deploy the Worker with generated optional integrations"
      task(:deploy) { wrangler("deploy") }
      task default: :build
    end
  end
end
