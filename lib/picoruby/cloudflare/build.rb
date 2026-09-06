# frozen_string_literal: true

require_relative "template/exporter"

unless defined?(MRuby::CrossBuild)
  raise Picoruby::Cloudflare::Template::Error, "Require picoruby/cloudflare/build from a PicoRuby build_config.rb, after its build system is loaded"
end

module Picoruby::Cloudflare::Template
  module CrossBuild
    WORKER_REVISION = "e6235bca616dbd4cec619cc0141facdea59a5541"
    RACK_REVISION = "05ba46eb0ab490a624a5f2dcb33249670933ff6b"
    CORE_GEMS = %w[mruby-array-ext mruby-catch mruby-class-ext mruby-enum-ext
                   mruby-hash-ext mruby-kernel-ext mruby-metaprog mruby-method
                   mruby-numeric-ext mruby-object-ext mruby-proc-ext mruby-sprintf
                   mruby-string-ext mruby-struct mruby-regexp].freeze

    def cloudflare_worker(worker: nil, rack: nil)
      raise Error, "cloudflare_worker may only be configured once per target" if @cloudflare_configured
      Picoruby::Cloudflare::Template.validate_build_path!(MRUBY_ROOT)
      Picoruby::Cloudflare::Template.validate_build_path!(build_dir)
      @cloudflare_configured = true
      toolchain :clang
      cc.command = linker.command = "emcc"
      archiver.command = "emar"
      [cc, linker].each { _1.flags.concat(%w[-sSUPPORT_LONGJMP=wasm -sWASM_LEGACY_EXCEPTIONS=0]) }
      cc.defines.concat(%w[PICORB_PLATFORM_WASM PICORB_PLATFORM_CLOUDFLARE_WORKERS MRB_32BIT MRB_INT64 MRB_NO_BOXING MRB_UTF8_STRING])
      ports :worker_wasm
      picoruby(alloc_estalloc: false)
      core_dir = File.join(MRUBY_ROOT, "mrbgems/picoruby-mruby/lib/mruby/mrbgems")
      CORE_GEMS.each { gem gemdir: File.join(core_dir, _1) }
      gem(rack || cloudflare_gem_source("MRUBY_RACK_GEM_DIR", "udzura/mruby-rack", "master", RACK_REVISION))
      target = self
      gem(worker || cloudflare_gem_source("PICORUBY_WORKER_WASM_GEM_DIR", "udzura/picoruby-cloudflare-worker-wasm", "bindings", WORKER_REVISION)) do |spec|
        # This runs during gems.setup, after all build_config DSL calls and mrbc resolution.
        target.send(:setup_cloudflare_export, spec)
      end
    end

    def worker_export(app:, output_dir:, wrangler_config:, environment: nil, project_root: nil)
      raise Error, "Call cloudflare_worker before worker_export" unless @cloudflare_configured
      raise Error, "worker_export may only be configured once per target" if @cloudflare_export
      config = File.expand_path(defined?(::MRUBY_CONFIG) ? ::MRUBY_CONFIG : ENV["MRUBY_CONFIG"] || ENV.fetch("CONFIG"))
      @cloudflare_export = {
        app: app, output_dir: output_dir, wrangler_config: wrangler_config,
        environment: environment, project_root: project_root || File.dirname(config), config: config,
      }
    end

    private

    def cloudflare_gem_source(key, github, branch, revision)
      if ENV[key]
        { gemdir: File.expand_path(ENV[key]) }
      else
        { github: github, branch: branch, checksum_hash: revision }
      end
    end

    def setup_cloudflare_export(spec)
      Exporter.new(self, spec.dir, **@cloudflare_export).define_tasks if @cloudflare_export
    end
  end
end

MRuby::CrossBuild.include(Picoruby::Cloudflare::Template::CrossBuild)
