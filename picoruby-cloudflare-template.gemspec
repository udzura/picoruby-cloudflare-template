# frozen_string_literal: true

require_relative "lib/picoruby/cloudflare/template/version"

Gem::Specification.new do |spec|
  spec.name = "picoruby-cloudflare-template"
  spec.version = Picoruby::Cloudflare::Template::VERSION
  spec.authors = ["Uchio Kondo"]
  spec.email = ["udzura@udzura.jp"]

  spec.summary = "Generate and build PicoRuby applications for Cloudflare Workers"
  spec.homepage = "https://github.com/udzura/picoruby-cloudflare-template"
  spec.required_ruby_version = ">= 3.2.0"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage

  spec.files = Dir.chdir(__dir__) { Dir["lib/**/*", "exe/*", "templates/**/*", "sig/**/*", "README*.md"].select { File.file?(_1) } }
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "rake", "~> 13.0"
end
