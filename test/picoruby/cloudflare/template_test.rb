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
    assert_equal "0.1.0-rc1", version
    assert_equal "0.1.0.pre.rc1", Gem::Version.new(version).to_s
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
    assert_include File.read(File.join(destination, "Gemfile")), '"~> 0.1.0-rc1"'
    assert_include File.read(File.join(destination, ".gitignore")), "/.dev.vars"
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
