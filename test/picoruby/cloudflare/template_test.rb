# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "stringio"
require "json"
require "open3"
require "picoruby/cloudflare/template/cli"
require "picoruby/cloudflare/template/exporter"

class Picoruby::Cloudflare::TemplateTest < Test::Unit::TestCase
  test "VERSION" do
    version = ::Picoruby::Cloudflare::Template::VERSION
    assert_equal "0.1.0.rc1", version
    assert_equal "0.1.0.rc1", Gem::Version.new(version).to_s
    assert Gem::Version.new(version).prerelease?
  end

  setup do
    @tmp = Dir.mktmpdir("picoruby-template-test")
  end

  teardown do
    FileUtils.remove_entry(@tmp)
  end

  test "generate a complete project without installing or building" do
    destination = File.join(@tmp, "my-worker")
    Picoruby::Cloudflare::Template::Generator.new(destination).generate
    %w[Gemfile Rakefile build_config.rb app.rb package.json wrangler.jsonc src/index.js .gitignore README.md].each do |name|
      assert_path_exist(File.join(destination, name))
    end
    assert_equal "my-worker", JSON.parse(File.read(File.join(destination, "package.json")))["name"]
    assert_include File.read(File.join(destination, "Gemfile")), '"~> 0.1.0.rc1"'
    assert_include File.read(File.join(destination, ".gitignore")), "/.dev.vars"
    assert_include File.read(File.join(destination, "README.md")), "brew install emscripten"
    app = File.read(File.join(destination, "app.rb"))
    assert_include app, "app = lambda do |env|"
    assert_include app, "rescue"
    assert_include app, "Internal Server Error"
    assert_not_include app, "Cloudflare::Queue"
    assert !File.exist?(File.join(destination, ".picoruby-cloudflare-template.json"))
    config = File.read(File.join(destination, "build_config.rb"))
    assert_include config, "conf.cloudflare_worker! do |cf|"
    assert_include config, "cf.picoruby_cloudflare_worker_wasm_mgem_dir"
    assert_include config, "cf.mruby_rack_mgem_dir"
    assert !File.exist?(File.join(destination, "node_modules"))
    %w[Gemfile Rakefile build_config.rb app.rb].each do |name|
      output, status = Open3.capture2e(RbConfig.ruby, "-c", File.join(destination, name))
      assert status.success?, output
    end
  end

  test "bindings flag generates KV and Queue examples with a regeneration manifest" do
    destination = File.join(@tmp, "bindings-worker")
    Picoruby::Cloudflare::Template::Generator.new(destination, bindings: true).generate
    app = File.read(File.join(destination, "app.rb"))
    wrangler = File.read(File.join(destination, "wrangler.jsonc"))
    assert_include app, 'Cloudflare::KV.from_env(env, "CACHE_KV")'
    assert_include app, 'Cloudflare::Queue.from_env(env, "EVENTS")'
    assert_include wrangler, '"kv_namespaces"'
    assert_include wrangler, '"queues"'
    manifest = JSON.parse(File.read(File.join(destination, ".picoruby-cloudflare-template.json")))
    assert_equal 1, manifest["format_version"]
    assert_equal %w[kv queue], manifest["features"]
    assert_equal %w[app.rb wrangler.jsonc], manifest["files"].keys
  end

  test "bindings can be added and safely regenerated without overwriting edits" do
    destination = File.join(@tmp, "existing-worker")
    Picoruby::Cloudflare::Template::Generator.new(destination).generate
    statuses = []
    Picoruby::Cloudflare::Template::BindingsGenerator.new(destination).generate do |status, file|
      statuses << [status, file]
    end
    assert_equal [
      [:update, "app.rb"], [:update, "wrangler.jsonc"],
      [:generate, ".picoruby-cloudflare-template.json"],
    ], statuses

    statuses.clear
    Picoruby::Cloudflare::Template::BindingsGenerator.new(destination).generate do |status, file|
      statuses << [status, file]
    end
    assert statuses.all? { |status, _file| status == :identical }

    app = File.join(destination, "app.rb")
    File.write(app, File.read(app) + "# application edit\n")
    wrangler = File.read(File.join(destination, "wrangler.jsonc"))
    manifest = File.read(File.join(destination, ".picoruby-cloudflare-template.json"))
    error = assert_raise(Picoruby::Cloudflare::Template::Error) do
      Picoruby::Cloudflare::Template::BindingsGenerator.new(destination).generate
    end
    assert_include error.message, "modified files: app.rb"
    assert_equal wrangler, File.read(File.join(destination, "wrangler.jsonc"))
    assert_equal manifest, File.read(File.join(destination, ".picoruby-cloudflare-template.json"))
  end

  test "existing destinations including empty directories are not overwritten" do
    destination = File.join(@tmp, "existing")
    Dir.mkdir(destination)
    File.write(File.join(destination, "keep"), "mine")
    assert_raise(Picoruby::Cloudflare::Template::Error) do
      Picoruby::Cloudflare::Template::Generator.new(destination).generate
    end
    assert_equal ["keep"], Dir.children(destination)
    assert_equal "mine", File.read(File.join(destination, "keep"))
  end

  test "reject symlink destinations even if their target is absent" do
    destination = File.join(@tmp, "symlink")
    File.symlink(File.join(@tmp, "missing"), destination)
    assert_raise(Picoruby::Cloudflare::Template::Error) do
      Picoruby::Cloudflare::Template::Generator.new(destination).generate
    end
  end

  test "validate worker names and local gem paths" do
    ["Bad Name", "../escape", 'quote"', "x" * 64].each do |name|
      assert_raise(Picoruby::Cloudflare::Template::Error) do
        Picoruby::Cloudflare::Template::Generator.new(File.join(@tmp, "app"), name: name)
      end
    end
    assert_raise(Picoruby::Cloudflare::Template::Error) do
      Picoruby::Cloudflare::Template::Generator.new(File.join(@tmp, "app"), gem_path: @tmp)
    end
  end

  test "local gem paths are Ruby escaped, not evaluated" do
    gem_path = File.join(@tmp, 'gem with #{unsafe} "quotes"')
    Dir.mkdir(gem_path)
    File.write(File.join(gem_path, "picoruby-cloudflare-template.gemspec"), "")
    destination = File.join(@tmp, "app")
    Picoruby::Cloudflare::Template::Generator.new(destination, gem_path: gem_path).generate
    assert_include File.read(File.join(destination, "Gemfile")), gem_path.dump
  end

  test "top-level help lists subcommands and succeeds without running them" do
    [[], ["-h"], ["--help"]].each do |argv|
      out = StringIO.new
      err = StringIO.new
      original = argv.dup
      status = Picoruby::Cloudflare::Template::CLI.run(argv, out: out, err: err)
      assert_equal 0, status
      assert_include out.string, "Usage: picoruby-cloudflare COMMAND [OPTIONS]"
      assert_include out.string, "Commands:"
      assert_include out.string, "new PATH"
      assert_include out.string, "bindings PROJECT"
      assert_include out.string, "doctor [PROJECT]"
      assert_include out.string, "-h, --help"
      assert_equal "", err.string
      assert_equal original, argv
    end
    assert_equal [], Dir.children(@tmp)
  end

  test "a leading help flag is handled before subcommand option parsing" do
    %w[-h --help].each do |flag|
      out = StringIO.new
      err = StringIO.new
      status = Picoruby::Cloudflare::Template::CLI.run([flag, "--unknown"], out: out, err: err)
      assert_equal 0, status
      assert_include out.string, "Commands:"
      assert_equal "", err.string
    end
  end

  test "CLI errors are actionable and do not create a destination" do
    err = StringIO.new
    status = Picoruby::Cloudflare::Template::CLI.run(["new", File.join(@tmp, "app"), "--unknown"], err: err)
    assert_equal 1, status
    assert_match(/invalid option/, err.string)
    assert_equal [], Dir.children(@tmp)
  end

  test "project defines build and doctor tasks without loading MRuby" do
    old = Rake.application
    Rake.application = Rake::Application.new
    Picoruby::Cloudflare::Template::Project.new(root: @tmp).define_tasks
    assert_equal ["build"], Rake::Task[:default].prerequisites
    assert Rake::Task.task_defined?(:doctor)
    assert !defined?(MRuby::CrossBuild)
  ensure
    Rake.application = old
  end

  test "new command recommends Homebrew" do
    out = StringIO.new
    status = Picoruby::Cloudflare::Template::CLI.run(["new", File.join(@tmp, "app")], out: out)
    assert_equal 0, status
    assert_include out.string, "brew install emscripten"
    assert_not_include out.string, "\e["
  end

  test "new command accepts the bindings flag" do
    destination = File.join(@tmp, "bindings-worker")
    out = StringIO.new
    status = Picoruby::Cloudflare::Template::CLI.run(["new", destination, "--bindings"], out: out)
    assert_equal 0, status
    assert_include out.string, File.join(destination, ".picoruby-cloudflare-template.json")
    assert_include File.read(File.join(destination, "app.rb")), "Cloudflare::KV"
  end

  test "bindings command upgrades an unedited generated project" do
    destination = File.join(@tmp, "existing-worker")
    Picoruby::Cloudflare::Template::Generator.new(destination).generate
    out = StringIO.new
    status = Picoruby::Cloudflare::Template::CLI.run(["bindings", destination], out: out)
    assert_equal 0, status
    assert_include out.string, "update  #{File.join(destination, 'app.rb')}"
    assert_include out.string, "Bindings ready"
    assert_include File.read(File.join(destination, "wrangler.jsonc")), '"kv_namespaces"'
  end

  test "new command lists generated files and colors terminal instructions" do
    out = StringIO.new
    out.define_singleton_method(:tty?) { true }
    destination = "./app"
    absolute_destination = nil
    status = Dir.chdir(@tmp) do
      absolute_destination = File.expand_path(destination)
      Picoruby::Cloudflare::Template::CLI.run(["new", destination], out: out)
    end
    assert_equal 0, status
    %w[Gemfile README.md Rakefile app.rb build_config.rb .gitignore package.json src/index.js wrangler.jsonc].each do |file|
      assert_include out.string, "\e[1;32mgenerate\e[0m  #{File.join(destination, file)}"
    end
    ["cd #{absolute_destination}", "brew install emscripten", "bundle install", "npm install", "bundle exec rake doctor", "npm run dev"].each do |command|
      assert_include out.string, "\e[36m#{command}\e[0m"
    end
  end

  test "doctor gives dependency-specific installation guidance" do
    %w[Rakefile lib/picoruby/build.rb mrbgems/picoruby-mruby/lib/mruby/lib/mruby/build.rb mrbgems/mruby-compiler/lib/prism/include/prism.h].each do |file|
      path = File.join(@tmp, file)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "")
    end
    previous_path = ENV["PATH"]
    previous_root = ENV["PICORUBY_ROOT"]
    begin
      ENV["PATH"] = ENV["PICORUBY_ROOT"] = @tmp
      %w[emcc emar node].each do |command|
        error = assert_raise(Picoruby::Cloudflare::Template::Error) do
          Picoruby::Cloudflare::Template::Project.new(root: @tmp).doctor(out: StringIO.new)
        end
        assert_include error.message, "#{command} is not on PATH"
        assert_include error.message, command == "node" ? "install Node.js" : "brew install emscripten"
        path = File.join(@tmp, command)
        File.write(path, "#!/bin/sh\necho available\n")
        File.chmod(0o755, path)
      end
    ensure
      ENV["PATH"] = previous_path
      ENV["PICORUBY_ROOT"] = previous_root
    end
  end

  test "build extension reports a misplaced require" do
    library = File.expand_path("../../../lib", __dir__)
    output, status = Open3.capture2e(RbConfig.ruby, "-I", library, "-rpicoruby/cloudflare/build", "-e", "")
    assert !status.success?
    assert_match(/from a PicoRuby build_config.rb/, output)
  end

  test "output must be below the project and outside node_modules" do
    [@tmp, File.dirname(@tmp), "node_modules/runtime"].each do |path|
      assert_raise(Picoruby::Cloudflare::Template::Error) do
        Picoruby::Cloudflare::Template::Exporter.new(nil, @tmp, app: "app.rb", output_dir: path,
          wrangler_config: "wrangler.jsonc", project_root: @tmp, config: "build_config.rb")
      end
    end
  end

  test "gem artifact file list includes CLI, dotfile template and runtime entry" do
    spec = Gem::Specification.load(File.expand_path("../../../picoruby-cloudflare-template.gemspec", __dir__))
    assert_equal ["MIT"], spec.licenses
    %w[LICENSE exe/picoruby-cloudflare templates/project/gitignore.erb templates/runtime/index.js lib/picoruby/cloudflare/build.rb].each do |name|
      assert_include spec.files, name
    end
  end

  test "upstream shell build paths reject metacharacters" do
    ["/tmp/app with spaces", "/tmp/app;bad", '/tmp/$(bad)', "/tmp/app\nnext"].each do |path|
      assert_raise(Picoruby::Cloudflare::Template::Error) do
        Picoruby::Cloudflare::Template.validate_build_path!(path)
      end
    end
    assert_equal "/tmp/a-b_c.1", Picoruby::Cloudflare::Template.validate_build_path!("/tmp/a-b_c.1")
  end
end
