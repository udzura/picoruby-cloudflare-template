# frozen_string_literal: true

require "erb"
require "digest"
require "fileutils"
require "json"
require "tempfile"
require_relative "../template"

module Picoruby::Cloudflare::Template
  class Generator
    TEMPLATES = File.expand_path("../../../../templates", __dir__)
    BINDINGS_MANIFEST = ".picoruby-cloudflare-template.json"
    BINDINGS_FILES = %w[app.rb wrangler.jsonc].freeze
    BINDINGS_FEATURES = %w[kv queue].freeze

    def initialize(destination, name: nil, gem_path: nil, bindings: false)
      @destination = File.expand_path(destination)
      @name = name || File.basename(@destination)
      @gem_path = File.expand_path(gem_path) if gem_path
      @bindings = bindings
      unless @name.is_a?(String) && @name.match?(/\A[a-z0-9][a-z0-9-]{0,62}\z/)
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
      files = rendered_files
      raise Error, "Project templates are missing from the installed gem" if files.empty?
      FileUtils.mkdir_p(File.dirname(@destination))
      Dir.mkdir(@destination)
      files.each do |relative, content|
        path = File.join(@destination, relative)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, content)
        yield relative if block_given?
      end
      @destination
    end

    def rendered_files
      files = Dir[File.join(TEMPLATES, "project", "**", "*.erb")].sort.to_h do |source|
        relative = source.delete_prefix("#{TEMPLATES}/project/").delete_suffix(".erb")
        relative = ".gitignore" if relative == "gitignore"
        [relative, ERB.new(File.read(source), trim_mode: "-").result(binding)]
      end
      if @bindings
        hashes = BINDINGS_FILES.to_h { [_1, Digest::SHA256.hexdigest(files.fetch(_1))] }
        files[BINDINGS_MANIFEST] = JSON.pretty_generate({
          format_version: 1, generator_version: VERSION,
          features: BINDINGS_FEATURES, files: hashes,
        }) + "\n"
      end
      files
    end
  end

  class BindingsGenerator
    def initialize(destination)
      @destination = File.expand_path(destination)
    end

    def generate
      unless File.directory?(@destination) && !File.symlink?(@destination)
        raise Error, "Bindings target must be an existing project directory: #{@destination}"
      end
      package = read_json("package.json", "Generated project package.json is missing or invalid")
      name = package["name"]
      desired = Generator.new(@destination, name: name, bindings: true).rendered_files
      base = Generator.new(@destination, name: name).rendered_files
      previous = load_manifest
      changes = []
      conflicts = []

      Generator::BINDINGS_FILES.each do |relative|
        path = File.join(@destination, relative)
        current = read_regular_file(path, relative)
        wanted = desired.fetch(relative)
        previous_hash = previous&.dig("files", relative)
        safe = current == wanted || Digest::SHA256.hexdigest(current) == previous_hash || (!previous && current == base.fetch(relative))
        conflicts << relative unless safe
        changes << [relative, wanted, current == wanted ? :identical : :update]
      end
      unless conflicts.empty?
        raise Error, "Bindings regeneration conflicts with modified files: #{conflicts.join(', ')}; no files changed"
      end

      manifest = Generator::BINDINGS_MANIFEST
      manifest_path = File.join(@destination, manifest)
      current_manifest = File.file?(manifest_path) && !File.symlink?(manifest_path) ? File.binread(manifest_path) : nil
      manifest_status = if current_manifest.nil?
        :generate
      elsif current_manifest == desired.fetch(manifest)
        :identical
      else
        :update
      end
      changes << [manifest, desired.fetch(manifest), manifest_status]
      changes.each do |relative, content, status|
        write(relative, content) unless status == :identical
        yield status, relative if block_given?
      end
      @destination
    end

    private

    def load_manifest
      path = File.join(@destination, Generator::BINDINGS_MANIFEST)
      raise Error, "Bindings manifest must be a regular file" if File.symlink?(path)
      return unless File.exist?(path)
      raise Error, "Bindings manifest must be a regular file" unless File.file?(path)
      data = JSON.parse(File.read(path))
      unless data["format_version"] == 1 && data["files"].is_a?(Hash)
        raise Error, "Bindings manifest has an unsupported format"
      end
      data
    rescue JSON::ParserError
      raise Error, "Bindings manifest is invalid JSON"
    end

    def read_json(relative, message)
      JSON.parse(read_regular_file(File.join(@destination, relative), relative))
    rescue JSON::ParserError
      raise Error, message
    end

    def read_regular_file(path, relative)
      raise Error, "Generated project file is missing or unsafe: #{relative}" unless File.file?(path) && !File.symlink?(path)
      File.binread(path)
    end

    def write(relative, content)
      path = File.join(@destination, relative)
      Tempfile.create(["bindings", ".tmp"], @destination) do |temp|
        temp.binmode
        temp.write(content)
        temp.close
        File.rename(temp.path, path)
      end
    end
  end
end
