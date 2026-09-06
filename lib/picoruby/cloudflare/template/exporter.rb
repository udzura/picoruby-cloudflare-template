# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "rake"
require "tempfile"
require_relative "../template"

module Picoruby::Cloudflare::Template
  class Exporter
    include Rake::DSL

    def initialize(build, gem_dir, app:, output_dir:, wrangler_config:, project_root:, config:, environment: nil)
      @build = build
      @gem_dir = gem_dir
      @root = File.expand_path(project_root)
      @app = File.expand_path(app, @root)
      @output = File.expand_path(output_dir, @root)
      @wrangler = File.expand_path(wrangler_config, @root)
      @config = config
      @environment = environment
      unless @output.start_with?("#{@root}/") && !@output.delete_prefix("#{@root}/").split("/").include?("node_modules")
        raise Error, "output_dir must be a subdirectory of the project, outside node_modules"
      end
      raise Error, "app must be outside output_dir" if @app.start_with?("#{@output}/")
    end

    def define_tasks
      Picoruby::Cloudflare::Template.validate_build_path!(@gem_dir)
      check_assets!
      verify_emscripten!
      bytecode = File.join(@output, "app.bin")
      check_output_path!(bytecode)
      file bytecode => [@app, @build.mrbcfile, @config, __FILE__] do
        check_output_path!(bytecode)
        FileUtils.mkdir_p(@output)
        Tempfile.create(["app", ".bin"], @output) do |temp|
          temp.close
          sh @build.mrbcfile, "-o#{temp.path}", @app
          File.rename(temp.path, bytecode)
        end
      end
      runtime_js = File.join(@build.build_dir, "bin/picoruby-worker.js")
      runtime_wasm = File.join(@build.build_dir, "bin/picoruby-worker.wasm")
      # The current mrbgem emits Wasm as a side effect of linking JS. Repair a
      # missing side output without using old artifacts or deleting the build.
      file runtime_wasm => runtime_js do
        Rake::Task[runtime_js].execute unless File.file?(runtime_wasm)
        raise Error, "Linker did not produce #{runtime_wasm}" unless File.file?(runtime_wasm)
      end
      prepare = "cloudflare:prepare:#{@build.name}"
      task prepare => [runtime_js, runtime_wasm, bytecode]
      manifest = File.join(@output, "manifest.json")
      # The task prerequisite deliberately runs export on every build: environment
      # selection is not a file timestamp. All writes are content-aware.
      file manifest => prepare do
        export(runtime_js, runtime_wasm)
      end
      @build.products << manifest
    end

    def export(runtime_js, runtime_wasm)
      %w[runtime.js host-bridge.js].each do |name|
        write(File.join("runtime", name), File.binread(File.join(@gem_dir, "spike/src", name)))
      end
      write("runtime/picoruby-worker.js", File.binread(runtime_js))
      write("runtime/picoruby-worker.wasm", File.binread(runtime_wasm))
      # Keep parser and runtime from the same mrbgem checkout. Scripts are copied
      # below the project so Node resolves its jsonc-parser dependency there.
      %w[cloudflare-binding-registry.mjs generate-bindings.mjs].each do |name|
        write(File.join("tools", name), File.binread(File.join(@gem_dir, "spike/scripts", name)))
      end
      Tempfile.create(["bindings", ".js"], @output) do |temp|
        temp.close
        args = ["node", File.join(@output, "tools/generate-bindings.mjs"), "--config", @wrangler, "--output", temp.path]
        args.concat(["--env", @environment]) if @environment
        output, status = Open3.capture2e(*args, chdir: @root)
        raise Error, "Binding registry generation failed:\n#{output}" unless status.success?
        write("bindings.js", File.binread(temp.path))
      end
      write("runtime/index.js", File.read(File.join(templates, "runtime/index.js")))
      write("package.json", JSON.pretty_generate({ private: true, type: "module", exports: "./runtime/index.js" }) + "\n")
      artifacts = %w[app.bin bindings.js package.json runtime/index.js runtime/runtime.js runtime/host-bridge.js runtime/picoruby-worker.js runtime/picoruby-worker.wasm]
      write("manifest.json", JSON.pretty_generate({
        format_version: 1, generator_version: VERSION, environment: @environment,
        worker_revision: worker_revision,
        sha256: artifacts.to_h { [_1, Digest::SHA256.file(File.join(@output, _1)).hexdigest] },
      }) + "\n")
    end

    private

    def templates
      File.expand_path("../../../../templates", __dir__)
    end

    def check_assets!
      %w[spike/src/runtime.js spike/src/host-bridge.js spike/scripts/cloudflare-binding-registry.mjs spike/scripts/generate-bindings.mjs spike/.emscripten-version].each do |path|
        raise Error, "Worker mrbgem is missing export asset #{path}; use the documented runtime revision" unless File.file?(File.join(@gem_dir, path))
      end
    end

    def verify_emscripten!
      expected = File.read(File.join(@gem_dir, "spike/.emscripten-version")).strip
      output, status = Open3.capture2e("emcc", "--version")
      actual = output[/emcc.*? (\d+\.\d+\.\d+)/, 1]
      raise Error, "Expected Emscripten #{expected}, got #{actual || output.lines.first}; activate the matching SDK" unless status.success? && actual == expected
    rescue Errno::ENOENT
      raise Error, "emcc is not on PATH; activate Emscripten #{expected}"
    end

    def worker_revision
      output, status = Open3.capture2e("git", "-C", @gem_dir, "rev-parse", "HEAD")
      status.success? ? output.strip : nil
    end

    def write(relative, content)
      path = File.join(@output, relative)
      check_output_path!(path)
      return if File.file?(path) && File.binread(path) == content.b
      FileUtils.mkdir_p(File.dirname(path))
      Tempfile.create(["export", ".tmp"], File.dirname(path)) do |temp|
        temp.binmode
        temp.write(content)
        temp.close
        File.rename(temp.path, path)
      end
    end

    def check_output_path!(path)
      current = path
      while current.start_with?("#{@root}/")
        raise Error, "Refusing to export through a symlink: #{current}" if File.symlink?(current)
        current = File.dirname(current)
      end
    end
  end
end
