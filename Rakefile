# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
end

task default: :test

namespace :test do
  desc "Generate a project, build Wasm and check Wrangler (requires PicoRuby, Emscripten and Node)"
  task :integration do
    ruby "test/integration.rb"
  end
end
