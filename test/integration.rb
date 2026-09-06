# frozen_string_literal: true

# Opt-in: npm installation and a full Emscripten build. Never deploys.
require "tmpdir"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "net/http"
require "socket"
require_relative "../lib/picoruby/cloudflare/template/generator"

%w[PICORUBY_ROOT PICORUBY_WORKER_WASM_GEM_DIR].each { raise "Set #{_1}" unless ENV[_1] }
gem_root = File.expand_path("..", __dir__)
root = Dir.mktmpdir("picoruby-template-integration-")
project = File.join(root, "worker")
puts "Integration artifacts and logs: #{root}"
Picoruby::Cloudflare::Template::Generator.new(project, gem_path: gem_root).generate
environment = %w[PICORUBY_ROOT PICORUBY_WORKER_WASM_GEM_DIR MRUBY_RACK_GEM_DIR].to_h do |key|
  [key, ENV[key] && File.expand_path(ENV[key])]
end
environment.merge!("BUNDLE_GEMFILE" => File.join(project, "Gemfile"), "CLOUDFLARE_ENV" => nil, "WRANGLER_SEND_METRICS" => "false")
step = 0
run = lambda do |*command, env: {}|
  step += 1
  log = File.join(root, "#{step}.log")
  puts "#{step}: #{command.join(' ')}"
  # The generated Gemfile must be resolved separately from the test suite bundle.
  Bundler.with_unbundled_env do
    File.open(log, "w") do |output|
      success = system(environment.merge(env), *command, chdir: project, out: output, err: output)
      raise "Failed: #{command.join(' ')}; see #{log}\n#{File.read(log).lines.last(35).join}" unless success
    end
  end
end
require "bundler"
run.call("bundle", "install", "--local")
run.call("npm", "install", "--ignore-scripts", "--no-audit", "--no-fund")
run.call("bundle", "exec", "rake", "doctor", "build")
run.call("npx", "wrangler", "deploy", "--dry-run", "--outdir", ".wrangler/dry-run")

# Dry-run does not start workerd: catch compatibility-date and JSPI startup
# failures with an actual local request, then verify custom-build hot reload.
socket = TCPServer.new("127.0.0.1", 0)
port = socket.addr[1]
socket.close
dev_log = File.join(root, "dev.log")
pid = nil
original_app = File.read(File.join(project, "app.rb"))
begin
  Bundler.with_unbundled_env do
    File.open(dev_log, "w") do |output|
      pid = Process.spawn(environment, File.join(project, "node_modules/.bin/wrangler"), "dev",
        "--ip", "127.0.0.1", "--port", port.to_s, "--inspector-port", "0",
        chdir: project, out: output, err: output, pgroup: true)
    end
  end
  await_response = lambda do |expected|
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 60
    loop do
      raise "Local server did not respond; see #{dev_log}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      begin
        http = Net::HTTP.new("127.0.0.1", port, nil)
        http.open_timeout = http.read_timeout = 1
        response = http.get("/")
        break if response.code == "200" && response.body == expected
      rescue SystemCallError, IOError, Timeout::Error
        # Wait for the custom build and workerd startup/reload.
      end
      sleep 0.2
    end
  end
  await_response.call("Hello from PicoRuby on Cloudflare!\n")
  File.write(File.join(project, "app.rb"), original_app.sub('[message +', '["Reloaded: " + message +'))
  await_response.call("Reloaded: Hello from PicoRuby on Cloudflare!\n")
  puts "Local Wrangler HTTP and app hot reload passed"
ensure
  if pid
    begin
      Process.kill("TERM", -pid)
      25.times do
        break if Process.waitpid(pid, Process::WNOHANG)
        sleep 0.2
      end
      begin
        Process.kill("KILL", -pid)
      rescue Errno::ESRCH
      end
      Process.waitpid(pid)
    rescue Errno::ESRCH, Errno::ECHILD
    end
  end
  File.write(File.join(project, "app.rb"), original_app)
end

FileUtils.cp(File.join(__dir__, "integration_app.rb"), File.join(project, "app.rb"))
config = {
  name: "template-integration", main: "src/index.js", compatibility_date: "2026-08-22",
  build: { command: "bundle exec rake build" },
  rules: [{ type: "Data", globs: ["**/*.bin"], fallthrough: true }],
  kv_namespaces: [{ binding: "CACHE_KV", id: "test-only" }],
  queues: { producers: [{ binding: "EVENTS", queue: "test-only" }] },
  env: { staging: { kv_namespaces: [{ binding: "STAGING_KV", id: "test-only" }] } },
}
File.write(File.join(project, "wrangler.jsonc"), JSON.pretty_generate(config))
run.call("bundle", "exec", "rake")
run.call("node", File.join(__dir__, "integration_runtime.mjs"), project)
run.call("bundle", "exec", "rake", env: { "CLOUDFLARE_ENV" => "staging" })
registry = File.read(File.join(project, "generated/worker/bindings.js"))
raise "Environment registry is stale" unless registry.include?("STAGING_KV") && !registry.include?("CACHE_KV")
run.call("bundle", "exec", "rake")
run.call("node", File.join(__dir__, "integration_runtime.mjs"), project)
wasm = File.join(project, ".picoruby-build/worker/bin/picoruby-worker.wasm")
FileUtils.mv(wasm, "#{wasm}.before-repair")
run.call("bundle", "exec", "rake")
raise "Missing Wasm was not regenerated" unless File.file?(wasm)
run.call("node", File.join(__dir__, "integration_runtime.mjs"), project)
puts "Integration passed. Artifacts retained at #{root}"
