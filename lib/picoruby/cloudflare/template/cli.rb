# frozen_string_literal: true

require "optparse"
require_relative "generator"
require_relative "project"

module Picoruby::Cloudflare::Template
  class CLI
    BOLD_GREEN = "\e[1;32m"
    CYAN = "\e[36m"
    RESET = "\e[0m"

    HELP = <<~TEXT.freeze
      Usage: picoruby-cloudflare COMMAND [OPTIONS]

      Commands:
        new PATH          Generate a PicoRuby Cloudflare Worker project
        doctor [PROJECT]  Check local Worker build prerequisites (default: current directory)

      Options:
        -h, --help        Show this help

      Run `picoruby-cloudflare new --help` for project generation options.
    TEXT

    def self.run(argv, out: $stdout, err: $stderr)
      argv = argv.dup
      command = argv.shift
      if command.nil? || command == "-h" || command == "--help"
        out.puts HELP
        return 0
      end

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
        path = Generator.new(argv.first, **options).generate do |file|
          out.puts "    #{style("generate", BOLD_GREEN, out)}  #{file}"
        end
        out.puts "\nCreated #{path}\nNext:"
        out.puts "  #{style("cd #{path}", CYAN, out)}"
        out.puts "  # On macOS (see README for PATH setup):"
        out.puts "  #{style("brew install emscripten", CYAN, out)}"
        out.puts "  #{style("bundle install", CYAN, out)}"
        out.puts "  #{style("npm install", CYAN, out)}"
        out.puts "  # Set PICORUBY_ROOT, then:"
        out.puts "  #{style("bundle exec rake doctor", CYAN, out)}"
        out.puts "  #{style("npm run dev", CYAN, out)}"
      when "doctor"
        raise Error, parser.to_s unless argv.length <= 1 && options.empty?
        Project.new(root: argv.first || Dir.pwd).doctor(out: out)
      else
        raise Error, parser.to_s
      end
      0
    rescue Error, OptionParser::ParseError => e
      err.puts e.message
      1
    end

    def self.style(text, escape, out)
      return text unless out.respond_to?(:tty?) && out.tty?
      "#{escape}#{text}#{RESET}"
    end
  end
end
