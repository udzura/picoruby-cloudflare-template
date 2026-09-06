# frozen_string_literal: true

require_relative "lib/picoruby/cloudflare/template/version"

Gem::Specification.new do |spec|
  spec.name = "picoruby-cloudflare-template"
  spec.version = Picoruby::Cloudflare::Template::VERSION
  spec.authors = ["Uchio Kondo"]
  spec.email = ["udzura@udzura.jp"]
  spec.license = "MIT"

  spec.summary = "Generate and build PicoRuby applications for Cloudflare Workers"
  spec.description = "Generate Rack-based Cloudflare Worker projects and configure PicoRuby cross builds. " \
                     "Export matching WebAssembly, ES modules, application bytecode, and binding registries for Wrangler."
  spec.homepage = "https://github.com/udzura/picoruby-cloudflare-template"
  spec.required_ruby_version = ">= 3.2.0"
  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["source_code_uri"] = "#{spec.homepage}/tree/main"
  spec.metadata["documentation_uri"] = "#{spec.homepage}#readme"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"

  spec.files = Dir.chdir(__dir__) { Dir["lib/**/*", "exe/*", "templates/**/*", "sig/**/*", "README*.md", "LICENSE*"].select { File.file?(_1) } }
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "rake", "~> 13.0"
end
