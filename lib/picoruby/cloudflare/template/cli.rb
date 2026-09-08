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
        new PATH [--bindings]  Generate a PicoRuby Cloudflare Worker project
        bindings PROJECT      Add or refresh KV and Queue binding examples
        doctor [PROJECT]       Check local Worker build prerequisites (default: current directory)

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
        opts.banner = "Usage: picoruby-cloudflare new PATH [--bindings] [--name NAME] [--gem-path PATH]\n       picoruby-cloudflare bindings PROJECT\n       picoruby-cloudflare doctor [PROJECT]"
        opts.on("--bindings", "Generate KV and Queue binding examples") { options[:bindings] = true }
        opts.on("--name NAME", "Worker name (defaults to directory name)") { options[:name] = _1 }
        opts.on("--gem-path PATH", "Use an unpublished local template gem") { options[:gem_path] = _1 }
      end
      parser.parse!(argv)
      case command
      when "new"
        raise Error, parser.to_s unless argv.length == 1
        destination = argv.first
        path = Generator.new(destination, **options).generate do |file|
          out.puts "    #{style("generate", BOLD_GREEN, out)}  #{File.join(destination, file)}"
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
      when "bindings"
        raise Error, parser.to_s unless argv.length == 1 && options.empty?
        destination = argv.first
        path = BindingsGenerator.new(destination).generate do |status, file|
          out.puts "    #{style(status, BOLD_GREEN, out)}  #{File.join(destination, file)}"
        end
        out.puts "\nBindings ready in #{path}"
        out.puts "  #{style("cd #{path}", CYAN, out)}"
        out.puts "  #{style("bundle exec rake", CYAN, out)}"
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
