# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "rake"
require "tempfile"
require_relative "../template"
require_relative "pondro_export"

module Picoruby::Cloudflare::Template
  class Exporter
    include Rake::DSL

    def initialize(build, gem_dir, app:, output_dir:, wrangler_config:, project_root:, config:, environment: nil, pondro: nil)
      @build = build
      @gem_dir = gem_dir
      @root = File.expand_path(project_root)
      @app = File.expand_path(app, @root)
      @output = File.expand_path(output_dir, @root)
      @wrangler = File.expand_path(wrangler_config, @root)
      @config = config
      @environment = environment
      @pondro = PondroExport.new(pondro, root: @root, output: @output, wrangler: @wrangler, environment: environment)
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
      plugins = worker_plugins
      @pondro.validate_runtime!(@gem_dir)
      pondro_config = @pondro.configuration
      plugin_artifacts = export_plugins(plugins)
      %w[runtime.js host-bridge.js durable-object.js].each do |name|
        write(File.join("runtime", name), File.binread(File.join(@gem_dir, "templates/runtime", name)))
      end
      write("runtime/picoruby-worker.js", File.binread(runtime_js))
      write("runtime/picoruby-worker.wasm", File.binread(runtime_wasm))
      # Keep parser and runtime from the same mrbgem checkout. Scripts are copied
      # below the project so Node resolves its jsonc-parser dependency there.
      %w[cloudflare-binding-registry.mjs generate-bindings.mjs].each do |name|
        write(File.join("tools", name), File.binread(File.join(@gem_dir, "templates/tools", name)))
      end
      @pondro.write_config(pondro_config) if pondro_config
      Tempfile.create(["bindings", ".js"], @output) do |temp|
        temp.close
        registry_config = pondro_config ? @pondro.config_path : @wrangler
        args = ["node", File.join(@output, "tools/generate-bindings.mjs"), "--config", registry_config, "--output", temp.path]
        args.concat(["--env", @environment]) if @environment
        output, status = Open3.capture2e(*args, chdir: @root)
        raise Error, "Binding registry generation failed:\n#{output}" unless status.success?
        write("bindings.js", File.binread(temp.path))
      end
      index = File.read(File.join(templates, "runtime/index.js"))
      unless plugins.empty?
        index = "import { createPlugins } from \"../plugins.js\";\n" + index
        index = index.sub("runtime.createCloudflareBindings(env, bindingTypes)",
          "runtime.createCloudflareBindings(env, bindingTypes, { plugins: createPlugins() })")
      end
      write("runtime/index.js", index)
      if pondro_config
        write("entry.js", @pondro.entry(pondro_config))
        plugin_artifacts << "entry.js"
      else
        @pondro.remove_config
      end
      package = { private: true, type: "module", exports: "./runtime/index.js" }
      package[:dependencies] = plugin_dependencies(plugins) unless plugins.empty?
      write("package.json", JSON.pretty_generate(package) + "\n")
      artifacts = %w[app.bin bindings.js package.json runtime/index.js runtime/runtime.js runtime/host-bridge.js runtime/durable-object.js runtime/picoruby-worker.js runtime/picoruby-worker.wasm]
      artifacts.concat(plugin_artifacts)
      write("manifest.json", JSON.pretty_generate({
        plugins: plugins.map { |plugin| plugin.fetch("id") },
        pondro: @pondro.options,
        format_version: 1, generator_version: VERSION, environment: @environment,
        worker_revision: worker_revision,
        sha256: artifacts.to_h { [_1, Digest::SHA256.file(File.join(@output, _1)).hexdigest] },
      }) + "\n")
    end

    private

    def worker_plugins
      unless @build.respond_to?(:gems)
        raise Error, "Pondro configuration requires the picoruby-cloudflare-pondro mgem" if @pondro.enabled?
        return []
      end

      ids = {}
      plugins = @build.gems.filter_map do |gem|
        path = File.join(gem.dir, "cloudflare-plugin.json")
        next unless File.file?(path)

        plugin = JSON.parse(File.read(path))
        raise Error, "Invalid Worker plugin manifest: #{path}" unless plugin.is_a?(Hash)
        id = plugin["id"]
        dependencies = plugin["npm_dependencies"]
        unless plugin["format_version"] == 1 && id.is_a?(String) && id.match?(/\A[a-z][a-z0-9.-]*\z/) &&
            dependencies.is_a?(Hash) && dependencies.all? { |name, version|
              name.is_a?(String) && name.match?(/\A(?:@[a-z0-9._-]+\/)?[a-z0-9._-]+\z/) &&
                version.is_a?(String) && !version.empty?
            }
          raise Error, "Invalid Worker plugin manifest: #{path}"
        end
        raise Error, "Duplicate Worker plugin: #{id}" if ids[id]
        ids[id] = true
        template = plugin["js_template"]
        unless template.is_a?(String) && !template.empty?
          raise Error, "Missing JS template for Worker plugin #{id}"
        end
        source = File.expand_path(template, gem.dir)
        unless source.start_with?("#{File.expand_path(gem.dir)}/") && File.file?(source) &&
            File.realpath(source).start_with?("#{File.realpath(gem.dir)}/")
          raise Error, "Invalid JS template for Worker plugin #{id}"
        end
        if id == "pondro"
          raise Error, "Declare pondro: { binding:, classes: } in worker_export" unless @pondro.enabled?
          plugin = plugin.merge("options" => @pondro.plugin_options)
        end
        plugin.merge("source" => source)
      rescue JSON::ParserError => error
        raise Error, "Invalid Worker plugin manifest #{path}: #{error.message}"
      end
      if @pondro.enabled? && !ids["pondro"]
        raise Error, "Pondro configuration requires the picoruby-cloudflare-pondro mgem and its cloudflare-plugin.json"
      end
      plugin_dependencies(plugins)
      plugins.sort_by { |plugin| plugin.fetch("id") }
    end

    def plugin_dependencies(plugins)
      plugins.each_with_object({}) do |plugin, dependencies|
        plugin.fetch("npm_dependencies").each do |name, version|
          if dependencies.key?(name) && dependencies[name] != version
            raise Error, "Conflicting Worker plugin dependency: #{name}"
          end
          dependencies[name] = version
        end
      end
    end

    def export_plugins(plugins)
      artifacts = plugins.map { |plugin| "runtime/plugins/#{plugin.fetch('id')}.js" }
      unless plugins.empty?
        imports = plugins.each_with_index.map do |plugin, index|
          path = artifacts[index]
          write(path, File.binread(plugin.fetch("source")))
          "import { createPlugin as plugin#{index} } from #{('./' + path).to_json};"
        end
        factories = plugins.each_with_index.map { |plugin, index| "plugin#{index}(#{plugin["options"]&.to_json})" }.join(", ")
        write("plugins.js", imports.join("\n") + "\nexport const createPlugins = () => [#{factories}];\n")
        artifacts << "plugins.js"
      end
      previous = File.join(@output, "manifest.json")
      check_output_path!(previous)
      if File.file?(previous)
        old = JSON.parse(File.read(previous)).fetch("sha256", {}).keys
        old.each do |relative|
          next unless relative == "plugins.js" || relative == "entry.js" || relative.match?(/\Aruntime\/plugins\/[a-z][a-z0-9.-]*\.js\z/)
          next if artifacts.include?(relative) || (relative == "entry.js" && @pondro.enabled?)

          path = File.join(@output, relative)
          check_output_path!(path)
          File.unlink(path) if File.file?(path)
        end
      end
      artifacts
    end

    def templates
      File.expand_path("../../../../templates", __dir__)
    end

    def check_assets!
      %w[templates/runtime/runtime.js templates/runtime/host-bridge.js templates/runtime/durable-object.js templates/tools/cloudflare-binding-registry.mjs templates/tools/generate-bindings.mjs].each do |path|
        raise Error, "Worker mrbgem is missing export asset #{path}; use the documented runtime revision" unless File.file?(File.join(@gem_dir, path))
      end
    end

    def verify_emscripten!
      output, status = Open3.capture2e("emcc", "--version")
      actual = output[/emcc.*? (\d+\.\d+\.\d+)/, 1]
      raise Error, "Expected Emscripten >= 5.0.0, got #{actual || output.lines.first}; see README for brew install emscripten and PATH setup" unless status.success? && actual && actual.split('.').first.to_i >= 5
    rescue Errno::ENOENT
      raise Error, "emcc is not on PATH; on macOS, run brew install emscripten and add its bin directory to PATH (expected >= 5.0.0; see README)"
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
