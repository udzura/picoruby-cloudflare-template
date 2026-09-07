# frozen_string_literal: true

require_relative "template/exporter"

unless defined?(MRuby::CrossBuild)
  raise Picoruby::Cloudflare::Template::Error, "Require picoruby/cloudflare/build from a PicoRuby build_config.rb, after its build system is loaded"
end

module Picoruby::Cloudflare::Template
  module CrossBuild
    WORKER_REVISION = "e6235bca616dbd4cec619cc0141facdea59a5541".freeze
    RACK_REVISION = "05ba46eb0ab490a624a5f2dcb33249670933ff6b".freeze
    CORE_GEMS = %w[mruby-array-ext mruby-catch mruby-class-ext mruby-enum-ext
                   mruby-hash-ext mruby-kernel-ext mruby-metaprog mruby-method
                   mruby-numeric-ext mruby-object-ext mruby-proc-ext mruby-sprintf
                   mruby-string-ext mruby-struct mruby-regexp].freeze

    attr_accessor :picoruby_cloudflare_worker_wasm_mgem_dir, :mruby_rack_mgem_dir
    attr_writer :picoruby_cloudflare_worker_wasm_revision, :mruby_rack_mgem_revision

    def picoruby_cloudflare_worker_wasm_revision
      @picoruby_cloudflare_worker_wasm_revision.nil? ? WORKER_REVISION : @picoruby_cloudflare_worker_wasm_revision
    end

    def mruby_rack_mgem_revision
      @mruby_rack_mgem_revision.nil? ? RACK_REVISION : @mruby_rack_mgem_revision
    end

    def cloudflare_worker!
      yield self if block_given?
      raise Error, "cloudflare_worker! may only be configured once per target" if @cloudflare_configured
      Picoruby::Cloudflare::Template.validate_build_path!(MRUBY_ROOT)
      Picoruby::Cloudflare::Template.validate_build_path!(build_dir)
      worker = cloudflare_gem_source(picoruby_cloudflare_worker_wasm_mgem_dir,
        "udzura/picoruby-cloudflare-worker-wasm", picoruby_cloudflare_worker_wasm_revision)
      rack = cloudflare_gem_source(mruby_rack_mgem_dir, "udzura/mruby-rack", mruby_rack_mgem_revision)
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
      gem(rack)
      target = self
      gem(worker) do |spec|
        # This runs during gems.setup, after all build_config DSL calls and mrbc resolution.
        target.send(:setup_cloudflare_export, spec)
      end
    end

    def worker_export(app:, output_dir:, wrangler_config:, environment: nil, project_root: nil)
      raise Error, "Call cloudflare_worker! before worker_export" unless @cloudflare_configured
      raise Error, "worker_export may only be configured once per target" if @cloudflare_export
      config = cloudflare_build_config
      @cloudflare_export = {
        app: app, output_dir: output_dir, wrangler_config: wrangler_config,
        environment: environment, project_root: project_root || File.dirname(config), config: config,
      }
    end

    private

    def cloudflare_gem_source(gem_dir, github, revision)
      if gem_dir
        path = File.expand_path(gem_dir, File.dirname(cloudflare_build_config))
        { gemdir: Picoruby::Cloudflare::Template.validate_build_path!(path) }
      else
        raise Error, "Revision for #{github} must be a nonempty String" unless revision.is_a?(String) && !revision.empty?
        { github: github, checksum_hash: revision }
      end
    end

    def cloudflare_build_config
      File.expand_path(defined?(::MRUBY_CONFIG) ? ::MRUBY_CONFIG : ENV["MRUBY_CONFIG"] || ENV.fetch("CONFIG"))
    end

    def setup_cloudflare_export(spec)
      Exporter.new(self, spec.dir, **@cloudflare_export).define_tasks if @cloudflare_export
    end
  end
end

MRuby::CrossBuild.include(Picoruby::Cloudflare::Template::CrossBuild)
