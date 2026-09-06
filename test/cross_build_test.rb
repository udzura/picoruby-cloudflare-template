# frozen_string_literal: true

require "test_helper"
require "open3"
require "rbconfig"

class CrossBuildTest < Test::Unit::TestCase
  test "DSL configures the target and defers export until the compiler is bound" do
    source = <<~'RUBY'
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
      conf = MRuby::CrossBuild.new
      conf.cloudflare_worker(worker: {gemdir: "/worker"}, rack: {gemdir: "/rack"})
      conf.worker_export(app: "app.rb", output_dir: "generated", wrangler_config: "wrangler.jsonc")
      raise unless conf.cc.command == "emcc" && conf.archiver.command == "emar"
      raise unless conf.cc.defines.include?("MRB_INT64")
      raise unless conf.linker.flags.include?("-sSUPPORT_LONGJMP=wasm")
      raise unless conf.gems.last.first == {gemdir: "/worker"}
      raise unless conf.gems.last.last
      begin
        conf.cloudflare_worker
        raise "duplicate allowed"
      rescue Picoruby::Cloudflare::Template::Error
      end
    RUBY
    library = File.expand_path("../lib", __dir__)
    output, status = Open3.capture2e({"MRUBY_CONFIG" => "/project/build_config.rb"}, RbConfig.ruby, "-I", library, "-e", source)
    assert status.success?, output
  end
end
