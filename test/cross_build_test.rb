# frozen_string_literal: true

require "test_helper"
require "open3"
require "rbconfig"

class CrossBuildTest < Test::Unit::TestCase
  BUILD_STUB = <<~'RUBY'
      MRUBY_ROOT = "/picoruby"
      module MRuby
        class CrossBuild
          Command = Struct.new(:command, :flags, :defines)
          attr_reader :cc, :linker, :archiver, :gems
          def initialize
            @cc = Command.new(nil, [], [])
            @linker = Command.new(nil, [], [])
            @archiver = Command.new(nil, [], [])
            @gems = []
          end
          def toolchain(value); end
          def ports(value); raise unless value == :worker_wasm; end
          def picoruby(alloc_estalloc:); raise if alloc_estalloc; end
          def gem(source, &block); @gems << [source, block]; end
          def mrbcfile; raise "must not be read during config"; end
          def build_dir; "/project/build/worker"; end
        end
      end
      require "picoruby/cloudflare/build"
  RUBY

  def check_config(source, env: {})
    library = File.expand_path("../lib", __dir__)
    output, status = Open3.capture2e({"MRUBY_CONFIG" => "/project/build_config.rb"}.merge(env),
      RbConfig.ruby, "-I", library, "-e", BUILD_STUB + source)
    assert status.success?, output
  end

  test "DSL configures the target and defers export until the compiler is bound" do
    check_config <<~'RUBY'
      conf = MRuby::CrossBuild.new
      conf.picoruby_cloudflare_worker_wasm_mgem_dir = "/worker"
      conf.mruby_rack_mgem_dir = "/rack"
      conf.cloudflare_worker!
      conf.worker_export(app: "app.rb", output_dir: "generated", wrangler_config: "wrangler.jsonc")
      raise unless conf.cc.command == "emcc" && conf.archiver.command == "emar"
      raise unless conf.cc.defines.include?("MRB_INT64")
      raise unless conf.linker.flags.include?("-sSUPPORT_LONGJMP=wasm")
      raise unless conf.gems.last.first == {gemdir: "/worker"}
      raise unless conf.gems[-2].first == {gemdir: "/rack"}
      raise unless conf.gems.last.last
      begin
        conf.cloudflare_worker!
        raise "duplicate allowed"
      rescue Picoruby::Cloudflare::Template::Error
      end
    RUBY
  end

  test "configuration block receives self once before validation and build setup" do
    check_config <<~'RUBY'
      conf = MRuby::CrossBuild.new
      conf.picoruby_cloudflare_worker_wasm_mgem_dir = "invalid;before-block"
      calls = 0
      conf.cloudflare_worker! do |cf|
        calls += 1
        raise unless cf.equal?(conf)
        raise unless cf.gems.empty? && cf.cc.command.nil?
        cf.picoruby_cloudflare_worker_wasm_mgem_dir = "vendor/worker"
        cf.mruby_rack_mgem_revision = "rack-revision"
        :ignored_return_value
      end
      raise unless calls == 1
      raise unless conf.cc.command == "emcc"
      raise unless conf.gems.last.first == {gemdir: "/project/vendor/worker"}
      raise unless conf.gems[-2].first == {github: "udzura/mruby-rack", checksum_hash: "rack-revision"}
    RUBY
  end

  test "a block exception propagates without starting build setup" do
    check_config <<~'RUBY'
      conf = MRuby::CrossBuild.new
      error = RuntimeError.new("configuration failed")
      begin
        conf.cloudflare_worker! { raise error }
        raise "exception swallowed"
      rescue RuntimeError => caught
        raise unless caught.equal?(error)
      end
      raise unless conf.gems.empty? && conf.cc.command.nil?
      conf.cloudflare_worker!
      raise unless conf.cc.command == "emcc"
    RUBY
  end

  test "nil directories declare GitHub gems at built-in revisions and ignore legacy environment overrides" do
    source = <<~'RUBY'
      conf = MRuby::CrossBuild.new
      defaults = Picoruby::Cloudflare::Template::CrossBuild
      raise unless conf.picoruby_cloudflare_worker_wasm_mgem_dir.nil?
      raise unless conf.mruby_rack_mgem_dir.nil?
      raise unless conf.picoruby_cloudflare_worker_wasm_revision == defaults::WORKER_REVISION
      raise unless conf.mruby_rack_mgem_revision == defaults::RACK_REVISION
      conf.cloudflare_worker!
      raise unless conf.gems[-2].first == {github: "udzura/mruby-rack", checksum_hash: defaults::RACK_REVISION}
      raise unless conf.gems.last.first == {github: "udzura/picoruby-cloudflare-worker-wasm", checksum_hash: defaults::WORKER_REVISION}
      raise if conf.respond_to?(:cloudflare_worker)
    RUBY
    check_config source, env: {"PICORUBY_WORKER_WASM_GEM_DIR" => "/ignored-worker", "MRUBY_RACK_GEM_DIR" => "/ignored-rack"}
  end

  test "default Worker source is pinned to the built-in revision" do
    check_config <<~'RUBY'
      conf = MRuby::CrossBuild.new
      revision = Picoruby::Cloudflare::Template::CrossBuild::WORKER_REVISION
      raise unless revision == "67aaa676d8247beaf19cbbeaeecb78115e490529"
      raise unless conf.picoruby_cloudflare_worker_wasm_revision == revision
      conf.cloudflare_worker!
      raise unless conf.gems.last.first == {github: "udzura/picoruby-cloudflare-worker-wasm", checksum_hash: revision}
    RUBY
  end

  test "revision attributes override defaults independently for each target" do
    check_config <<~'RUBY'
      conf = MRuby::CrossBuild.new
      conf.picoruby_cloudflare_worker_wasm_revision = "worker-revision"
      conf.mruby_rack_mgem_revision = "rack-revision"
      conf.cloudflare_worker!
      raise unless conf.gems.last.first == {github: "udzura/picoruby-cloudflare-worker-wasm", checksum_hash: "worker-revision"}
      raise unless conf.gems[-2].first == {github: "udzura/mruby-rack", checksum_hash: "rack-revision"}
      other = MRuby::CrossBuild.new
      defaults = Picoruby::Cloudflare::Template::CrossBuild
      raise unless other.picoruby_cloudflare_worker_wasm_revision == defaults::WORKER_REVISION
      raise unless other.mruby_rack_mgem_revision == defaults::RACK_REVISION
    RUBY
  end

  test "local directory takes precedence over revision and is relative to build_config" do
    check_config <<~'RUBY'
      conf = MRuby::CrossBuild.new
      conf.picoruby_cloudflare_worker_wasm_mgem_dir = "vendor/worker"
      conf.picoruby_cloudflare_worker_wasm_revision = "unused"
      conf.mruby_rack_mgem_revision = "rack-revision"
      Dir.chdir("/") { conf.cloudflare_worker! }
      raise unless conf.gems.last.first == {gemdir: "/project/vendor/worker"}
      raise unless conf.gems[-2].first == {github: "udzura/mruby-rack", checksum_hash: "rack-revision"}
    RUBY
  end

  test "setting attributes back to nil restores GitHub sources and default revisions" do
    check_config <<~'RUBY'
      conf = MRuby::CrossBuild.new
      conf.picoruby_cloudflare_worker_wasm_mgem_dir = "vendor/worker"
      conf.mruby_rack_mgem_dir = "vendor/rack"
      conf.picoruby_cloudflare_worker_wasm_revision = "worker-revision"
      conf.mruby_rack_mgem_revision = "rack-revision"
      conf.picoruby_cloudflare_worker_wasm_mgem_dir = conf.mruby_rack_mgem_dir = nil
      conf.picoruby_cloudflare_worker_wasm_revision = conf.mruby_rack_mgem_revision = nil
      conf.cloudflare_worker!
      defaults = Picoruby::Cloudflare::Template::CrossBuild
      raise unless conf.gems.last.first == {github: "udzura/picoruby-cloudflare-worker-wasm", checksum_hash: defaults::WORKER_REVISION}
      raise unless conf.gems[-2].first == {github: "udzura/mruby-rack", checksum_hash: defaults::RACK_REVISION}
    RUBY
  end

  test "invalid source attributes fail before mutating the build" do
    check_config <<~'RUBY'
      [[:picoruby_cloudflare_worker_wasm_mgem_dir, "bad;path"],
       [:mruby_rack_mgem_dir, "bad path"],
       [:picoruby_cloudflare_worker_wasm_revision, ""],
       [:picoruby_cloudflare_worker_wasm_revision, false],
       [:mruby_rack_mgem_revision, 42]].each do |attribute, value|
        conf = MRuby::CrossBuild.new
        conf.public_send("#{attribute}=", value)
        begin
          conf.cloudflare_worker!
          raise "invalid source accepted"
        rescue Picoruby::Cloudflare::Template::Error
          raise unless conf.gems.empty? && conf.cc.command.nil?
        end
      end
    RUBY
  end
end
