# frozen_string_literal: true

require "erb"
require "fileutils"
require_relative "../template"

module Picoruby::Cloudflare::Template
  class Generator
    TEMPLATES = File.expand_path("../../../../templates", __dir__)

    def initialize(destination, name: nil, gem_path: nil)
      @destination = File.expand_path(destination)
      @name = name || File.basename(@destination)
      @gem_path = File.expand_path(gem_path) if gem_path
      unless @name.match?(/\A[a-z0-9][a-z0-9-]{0,62}\z/)
        raise Error, "Worker name must be 1–63 lowercase letters, digits or hyphens, starting with a letter or digit"
      end
      if @gem_path && !File.file?(File.join(@gem_path, "picoruby-cloudflare-template.gemspec"))
        raise Error, "--gem-path must point to picoruby-cloudflare-template"
      end
    end

    def generate
      if File.exist?(@destination) || File.symlink?(@destination)
        raise Error, "Destination already exists: #{@destination}; choose a new directory"
      end
      # Render everything before creating the project. Never overwrite an existing project.
      files = Dir[File.join(TEMPLATES, "project", "**", "*.erb")].sort.to_h do |source|
        relative = source.delete_prefix("#{TEMPLATES}/project/").delete_suffix(".erb")
        relative = ".gitignore" if relative == "gitignore"
        [relative, ERB.new(File.read(source), trim_mode: "-").result(binding)]
      end
      raise Error, "Project templates are missing from the installed gem" if files.empty?
      FileUtils.mkdir_p(File.dirname(@destination))
      Dir.mkdir(@destination)
      files.each do |relative, content|
        path = File.join(@destination, relative)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, content)
      end
      @destination
    end
  end
end
