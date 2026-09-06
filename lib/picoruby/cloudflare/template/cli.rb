# frozen_string_literal: true

require "optparse"
require_relative "generator"
require_relative "project"

module Picoruby::Cloudflare::Template
  class CLI
    def self.run(argv, out: $stdout, err: $stderr)
      argv = argv.dup
      command = argv.shift
      options = {}
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: picoruby-cloudflare new PATH [--name NAME] [--gem-path PATH]\n       picoruby-cloudflare doctor [PROJECT]"
        opts.on("--name NAME", "Worker name (defaults to directory name)") { options[:name] = _1 }
        opts.on("--gem-path PATH", "Use an unpublished local template gem") { options[:gem_path] = _1 }
      end
      parser.parse!(argv)
      case command
      when "new"
        raise Error, parser.to_s unless argv.length == 1
        path = Generator.new(argv.first, **options).generate
        out.puts "Created #{path}\nNext: cd #{path}\n  bundle install\n  npm install\n  # Set PICORUBY_ROOT and activate Emscripten, then:\n  bundle exec rake doctor\n  npm run dev"
      when "doctor"
        raise Error, parser.to_s unless argv.length <= 1 && options.empty?
        Project.new(root: argv.first || Dir.pwd).doctor(out: out)
      when "--help", "-h", nil
        out.puts parser
      else
        raise Error, parser.to_s
      end
      0
    rescue Error, OptionParser::ParseError => e
      err.puts e.message
      1
    end
  end
end
