# frozen_string_literal: true

require "open3"
require "rbconfig"
require "rake"
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
        output, status = Open3.capture2e(command, "--version")
        raise Error, "#{command} is unavailable: #{output}" unless status.success?
        out.puts output.lines.first
      rescue Errno::ENOENT
        raise Error, "#{command} is not on PATH; activate Emscripten / install Node.js"
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
      # Normalize local overrides before changing cwd to PicoRuby.
      %w[PICORUBY_WORKER_WASM_GEM_DIR MRUBY_RACK_GEM_DIR].each do |key|
        env[key] = Picoruby::Cloudflare::Template.validate_build_path!(File.expand_path(ENV[key], @root)) if ENV[key]
      end
      library = File.expand_path("../../..", __dir__)
      command = [RbConfig.ruby, "-I", library, Gem.bin_path("rake", "rake"), "-f", File.join(root, "Rakefile"), "all"]
      raise Error, "PicoRuby build failed" unless system(env, *command, chdir: root)
    end

    def define_tasks
      desc "Build PicoRuby and export the Worker ES module"
      task(:build) { build }
      desc "Check local Worker build prerequisites"
      task(:doctor) { doctor }
      task default: :build
    end
  end
end
