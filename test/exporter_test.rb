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
end
