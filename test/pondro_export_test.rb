# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "picoruby/cloudflare/template/exporter"

class PondroExportTest < Test::Unit::TestCase
  class FixtureExport < Picoruby::Cloudflare::Template::PondroExport
    def read_config
      JSON.parse(File.read(@wrangler))
    end
  end

  setup do
    @tmp = Dir.mktmpdir("pondro-export-test")
    FileUtils.mkdir_p(File.join(@tmp, "src"))
    File.write(File.join(@tmp, "src/index.js"), "export default {};\n")
    @source = File.join(@tmp, "wrangler.jsonc")
    @base = { "main" => "src/index.js", "durable_objects" => { "bindings" => [
      { "name" => "SESSIONS", "class_name" => "PicoRubyDurableObject" },
    ] }, "migrations" => [{ "tag" => "v1", "new_sqlite_classes" => ["PicoRubyDurableObject"] }] }
    write_source(@base)
  end

  teardown do
    FileUtils.remove_entry(@tmp)
  end

  def write_source(value)
    File.write(@source, JSON.pretty_generate(value))
  end

  def export(options = { classes: ["Counter"] }, environment: nil)
    FixtureExport.new(options, root: @tmp, output: File.join(@tmp, "generated/worker"), wrangler: @source, environment: environment)
  end

  test "adds Pondro while preserving source entry, existing sessions and migrations" do
    exporter = export
    original = File.read(@source)
    config = exporter.configuration
    assert_equal "generated/worker/entry.js", config["main"]
    assert_equal ["SESSIONS", "PONDRO"], config.dig("durable_objects", "bindings").map { _1["name"] }
    assert_equal ["v1", "pondro-v1"], config["migrations"].map { _1["tag"] }
    assert_equal original, File.read(@source)
    assert_include exporter.entry(config), 'export { default } from "../../src/index.js"'
    assert_include exporter.entry(config), 'export * from "../../src/index.js"'
    assert_include exporter.entry(config), 'export const PondroDurableObject'
    exporter.write_config(config)
    mtime = File.mtime(exporter.config_path)
    exporter.write_config(exporter.configuration)
    assert_equal mtime, File.mtime(exporter.config_path)
    assert_equal original, File.read(@source)
    exporter.remove_config
    assert_false File.exist?(exporter.config_path)
  end

  test "existing matching declarations are reused without duplicate migrations" do
    @base["durable_objects"]["bindings"] << { "name" => "PONDRO", "class_name" => "PondroDurableObject" }
    @base["migrations"] << { "tag" => "custom-v2", "new_sqlite_classes" => ["PondroDurableObject"] }
    write_source(@base)
    config = export.configuration
    assert_equal 2, config["durable_objects"]["bindings"].size
    assert_equal ["v1", "custom-v2"], config["migrations"].map { _1["tag"] }
  end

  test "named environments receive their own binding and preserve relative asset paths" do
    @base["assets"] = { "directory" => "./public" }
    @base["env"] = { "staging" => { "durable_objects" => { "bindings" => [{ "name" => "STAGING_SESSIONS", "class_name" => "PicoRubyDurableObject" }] } } }
    write_source(@base)
    config = export(environment: "staging").configuration
    assert_equal ["SESSIONS"], config.dig("durable_objects", "bindings").map { _1["name"] }
    assert_equal ["STAGING_SESSIONS", "PONDRO"], config.dig("env", "staging", "durable_objects", "bindings").map { _1["name"] }
    assert_equal "./public", config.dig("assets", "directory")
    assert_raise(Picoruby::Cloudflare::Template::Error) { export(environment: "missing").configuration }
  end

  test "conflicting existing bindings or migration tags fail before writing config" do
    @base["durable_objects"]["bindings"] << { "name" => "PONDRO", "class_name" => "OtherObject" }
    write_source(@base)
    assert_raise(Picoruby::Cloudflare::Template::Error) { export.configuration }
    @base["durable_objects"]["bindings"].pop
    @base["migrations"] << { "tag" => "pondro-v1", "new_sqlite_classes" => ["OtherObject"] }
    write_source(@base)
    assert_raise(Picoruby::Cloudflare::Template::Error) { export.configuration }
    config = export({ classes: ["Counter"], migration_tag: "objects-v2" }).configuration
    assert_equal "objects-v2", config["migrations"].last["tag"]
  end

  test "invalid class declarations and unsupported runtimes are rejected" do
    [false, {}, { classes: [] }, { classes: ["Counter", "Counter"] }, { classes: ["Counter"], class_name: "PicoRubyDurableObject" },
     { classes: ["Counter"], typo: true }, { classes: ["Counter"], binding: "bad-name" }].each do |options|
      assert_raise(Picoruby::Cloudflare::Template::Error) { export(options) }
    end
    FileUtils.mkdir_p(File.join(@tmp, "templates/runtime"))
    path = File.join(@tmp, "templates/runtime/runtime.js")
    File.write(path, "export function dispatch() {}")
    assert_raise(Picoruby::Cloudflare::Template::Error) { export.validate_runtime!(@tmp) }
    File.write(path, "export function dispatchEvent() {}")
    assert_nothing_raised { export.validate_runtime!(@tmp) }
  end

  test "generated config never overwrites unrelated files or symlinks" do
    exporter = export
    config = exporter.configuration
    File.write(exporter.config_path, "user content")
    assert_raise(Picoruby::Cloudflare::Template::Error) { exporter.write_config(config) }
    assert_raise(Picoruby::Cloudflare::Template::Error) { exporter.remove_config }
    assert_equal "user content", File.read(exporter.config_path)
    File.unlink(exporter.config_path)
    File.symlink(@source, exporter.config_path)
    assert_raise(Picoruby::Cloudflare::Template::Error) { exporter.write_config(config) }
    assert_raise(Picoruby::Cloudflare::Template::Error) { exporter.remove_config }
  end
end
