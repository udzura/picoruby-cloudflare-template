# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "picoruby/cloudflare/template/exporter"

class ExporterTest < Test::Unit::TestCase
  class TestExporter < Picoruby::Cloudflare::Template::Exporter
    def check_assets!; end
    def verify_emscripten!; end
    def export(js, wasm)
      write("manifest.json", File.read(js) + File.read(wasm))
    end
  end

  setup do
    @tmp = Dir.mktmpdir("exporter-test")
    @old_rake = Rake.application
    Rake.application = Rake::Application.new
    @config = File.join(@tmp, "build_config.rb")
    @app = File.join(@tmp, "app.rb")
    File.write(@config, "")
    File.write(@app, "APP")
    compiler = File.join(@tmp, "mrbc")
    File.write(compiler, "#!/usr/bin/env ruby\nFile.binwrite(ARGV[0].delete_prefix('-o'), File.binread(ARGV[1]))\n")
    File.chmod(0o755, compiler)
    @build = Struct.new(:name, :build_dir, :mrbcfile, :products).new("worker", File.join(@tmp, "build"), compiler, [])
    @js = File.join(@build.build_dir, "bin/picoruby-worker.js")
    @wasm = File.join(@build.build_dir, "bin/picoruby-worker.wasm")
    @links = 0
    Rake::FileTask.define_task(@js) do
      FileUtils.mkdir_p(File.dirname(@js))
      File.write(@js, "JS")
      File.write(@wasm, "WASM")
      @links += 1
    end
    @exporter = TestExporter.new(@build, @tmp, app: "app.rb", output_dir: "generated/worker",
      wrangler_config: "wrangler.jsonc", project_root: @tmp, config: @config)
    @exporter.define_tasks
  end

  teardown do
    Rake.application = @old_rake
    FileUtils.remove_entry(@tmp)
  end

  def build
    Rake.application.tasks.each(&:reenable)
    Rake::Task[@build.products.first].invoke
  end

  def verify_compiler(version, exit_status: 0)
    if version
      compiler = File.join(@tmp, "emcc")
      File.write(compiler, "#!/bin/sh\nprintf '%s\\n' 'emcc (Emscripten gcc/clang-like replacement) #{version}'\nexit #{exit_status}\n")
      File.chmod(0o755, compiler)
    end
    previous_path = ENV["PATH"]
    begin
      ENV["PATH"] = @tmp
      Picoruby::Cloudflare::Template::Exporter.instance_method(:verify_emscripten!).bind_call(@exporter)
    ensure
      ENV["PATH"] = previous_path
    end
  end

  test "compiler check accepts Emscripten 5 and later" do
    %w[5.0.0 5.0.7 6.0.8 6.0.9 6.0.9-git 7.0.0 10.0.0].each do |version|
      assert_nothing_raised { verify_compiler(version) }
    end
  end

  test "compiler check rejects older or unrecognized versions" do
    %w[4.99.99 unknown].each do |version|
      error = assert_raise(Picoruby::Cloudflare::Template::Error) { verify_compiler(version) }
      assert_include error.message, "Expected Emscripten >= 5.0.0"
    end
  end

  test "compiler check rejects failed commands even with a supported version" do
    assert_raise(Picoruby::Cloudflare::Template::Error) { verify_compiler("6.0.9", exit_status: 1) }
  end

  test "compiler check reports missing emcc" do
    error = assert_raise(Picoruby::Cloudflare::Template::Error) { verify_compiler(nil) }
    assert_include error.message, "emcc is not on PATH; on macOS, run brew install emscripten"
    assert_include error.message, "expected >= 5.0.0"
  end

  test "export assets are read from the worker templates directory" do
    assets = %w[
      templates/runtime/runtime.js
      templates/runtime/host-bridge.js
      templates/runtime/durable-object.js
      templates/tools/cloudflare-binding-registry.mjs
      templates/tools/generate-bindings.mjs
    ]
    assets.each do |path|
      FileUtils.mkdir_p(File.dirname(File.join(@tmp, path)))
      File.write(File.join(@tmp, path), path)
    end

    assert_nothing_raised do
      Picoruby::Cloudflare::Template::Exporter.instance_method(:check_assets!).bind_call(@exporter)
    end
    File.unlink(File.join(@tmp, assets.last))
    error = assert_raise(Picoruby::Cloudflare::Template::Error) do
      Picoruby::Cloudflare::Template::Exporter.instance_method(:check_assets!).bind_call(@exporter)
    end
    assert_include error.message, assets.last
  end

  test "export uses target compiler, preserves unchanged artifacts and repairs missing Wasm" do
    build
    bytecode = File.join(@tmp, "generated/worker/app.bin")
    assert_equal "APP", File.read(bytecode)
    assert_equal "JSWASM", File.read(@build.products.first)
    first_mtime = File.mtime(bytecode)
    manifest_mtime = File.mtime(@build.products.first)
    build
    assert_equal 1, @links
    assert_equal first_mtime, File.mtime(bytecode)
    assert_equal manifest_mtime, File.mtime(@build.products.first)
    File.unlink(@wasm)
    build
    assert_equal 2, @links
    assert_path_exist @wasm
  end

  test "an app-only change recompiles bytecode without relinking" do
    build
    File.write(@app, "CHANGED")
    future = Time.now + 2
    File.utime(future, future, @app)
    build
    assert_equal "CHANGED", File.read(File.join(@tmp, "generated/worker/app.bin"))
    assert_equal 1, @links
  end

  test "a failed compiler does not replace existing bytecode" do
    build
    File.write(@build.mrbcfile, "#!/usr/bin/env ruby\nexit 1\n")
    future = Time.now + 2
    File.utime(future, future, @app)
    assert_raise(RuntimeError) { build }
    assert_equal "APP", File.read(File.join(@tmp, "generated/worker/app.bin"))
  end

  test "symlink outputs cannot overwrite files outside the export directory" do
    build
    manifest = @build.products.first
    File.unlink(manifest)
    original = File.join(@tmp, "keep")
    File.write(original, "mine")
    File.symlink(original, manifest)
    assert_raise(Picoruby::Cloudflare::Template::Error) { build }
    assert_equal "mine", File.read(original)
  end
  def plugin_build(*paths)
    Struct.new(:gems).new(paths.map { |path| Struct.new(:dir).new(path) })
  end

  def plugin_exporter(build)
    Picoruby::Cloudflare::Template::Exporter.new(build, @tmp,
      app: "app.rb", output_dir: "plugins-output", wrangler_config: "wrangler.jsonc",
      project_root: @tmp, config: @config)
  end

  def make_plugin(id = "ai-sdk.openai", dependencies = { "ai" => "^7.0.123" })
    path = File.join(@tmp, id)
    FileUtils.mkdir_p(File.join(path, "templates"))
    File.write(File.join(path, "templates/plugin.js"), "export const createPlugin = () => ({});\n")
    File.write(File.join(path, "cloudflare-plugin.json"), JSON.generate({
      format_version: 1, id: id, js_template: "templates/plugin.js", npm_dependencies: dependencies,
    }))
    path
  end

  test "plugins are discovered from resolved gems and unused plugins emit nothing" do
    exporter = plugin_exporter(plugin_build)
    assert_equal [], exporter.send(:worker_plugins)
    assert_equal [], exporter.send(:export_plugins, [])
    assert_false File.exist?(File.join(@tmp, "plugins-output/plugins.js"))

    path = make_plugin
    exporter = plugin_exporter(plugin_build(path))
    plugins = exporter.send(:worker_plugins)
    assert_equal ["ai-sdk.openai"], plugins.map { |plugin| plugin.fetch("id") }
    artifacts = exporter.send(:export_plugins, plugins)
    assert_equal ["runtime/plugins/ai-sdk.openai.js", "plugins.js"], artifacts
    assert_include File.read(File.join(@tmp, "plugins-output/plugins.js")), "plugin0()"
    assert_equal({ "ai" => "^7.0.123" }, exporter.send(:plugin_dependencies, plugins))

    File.write(File.join(@tmp, "plugins-output/manifest.json"), JSON.generate({ sha256: artifacts.to_h { |name| [name, "digest"] } }))
    exporter.send(:export_plugins, [])
    artifacts.each { |name| assert_false File.exist?(File.join(@tmp, "plugins-output", name)) }
  end

  test "duplicate plugin ids and conflicting dependencies are rejected" do
    path = make_plugin
    assert_raise(Picoruby::Cloudflare::Template::Error) do
      plugin_exporter(plugin_build(path, path)).send(:worker_plugins)
    end
    other = make_plugin("ai-sdk.other", { "ai" => "^6.0.0" })
    assert_raise(Picoruby::Cloudflare::Template::Error) do
      plugin_exporter(plugin_build(path, other)).send(:worker_plugins)
    end
  end

  test "plugin templates cannot escape their gem directory" do
    path = make_plugin
    manifest = File.join(path, "cloudflare-plugin.json")
    data = JSON.parse(File.read(manifest))
    data["js_template"] = "../app.rb"
    File.write(manifest, JSON.generate(data))
    assert_raise(Picoruby::Cloudflare::Template::Error) do
      plugin_exporter(plugin_build(path)).send(:worker_plugins)
    end
  end

  test "plugin cleanup refuses symlink outputs" do
    path = make_plugin
    exporter = plugin_exporter(plugin_build(path))
    artifacts = exporter.send(:export_plugins, exporter.send(:worker_plugins))
    output = File.join(@tmp, "plugins-output")
    File.write(File.join(output, "manifest.json"), JSON.generate({ sha256: artifacts.to_h { |name| [name, "digest"] } }))
    File.unlink(File.join(output, "plugins.js"))
    File.symlink(@app, File.join(output, "plugins.js"))
    assert_raise(Picoruby::Cloudflare::Template::Error) { exporter.send(:export_plugins, []) }
    assert_equal "APP", File.read(@app)
  end

end

class ExporterTest
  test "Pondro manifest requires configuration and emits configured factory arguments" do
    path = make_plugin("pondro", {})
    assert_raise(Picoruby::Cloudflare::Template::Error) do
      plugin_exporter(plugin_build(path)).send(:worker_plugins)
    end
    exporter = Picoruby::Cloudflare::Template::Exporter.new(plugin_build(path), @tmp,
      app: "app.rb", output_dir: "plugins-output", wrangler_config: "wrangler.jsonc",
      project_root: @tmp, config: @config, pondro: { binding: "ACTORS", classes: ["Counter"] })
    plugins = exporter.send(:worker_plugins)
    exporter.send(:export_plugins, plugins)
    assert_include File.read(File.join(@tmp, "plugins-output/plugins.js")), 'plugin0({"binding":"ACTORS","classes":["Counter"]})'
    assert_equal({}, exporter.send(:plugin_dependencies, plugins))
    missing = Picoruby::Cloudflare::Template::Exporter.new(plugin_build, @tmp,
      app: "app.rb", output_dir: "plugins-output", wrangler_config: "wrangler.jsonc",
      project_root: @tmp, config: @config, pondro: { classes: ["Counter"] })
    assert_raise(Picoruby::Cloudflare::Template::Error) { missing.send(:worker_plugins) }
  end

  test "disabling Pondro removes its generated wrapper as well as plugin assets" do
    exporter = plugin_exporter(plugin_build)
    output = File.join(@tmp, "plugins-output")
    FileUtils.mkdir_p(output)
    File.write(File.join(output, "entry.js"), "generated")
    File.write(File.join(output, "manifest.json"), JSON.generate({ sha256: { "entry.js" => "digest" } }))
    exporter.send(:export_plugins, [])
    assert_false File.exist?(File.join(output, "entry.js"))
  end
end
