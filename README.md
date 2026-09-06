# picoruby-cloudflare-template

English | [日本語](README.ja.md)

A CRuby gem for generating PicoRuby Cloudflare Worker projects, configuring CrossBuild, and exporting local ES modules.
It is not needed at Wasm runtime, and publishing an npm package is not required.

## Quick start (before publication)

Run the following from this repository:

```sh
bundle install
bundle exec ruby exe/picoruby-cloudflare new ../my-worker --gem-path "$PWD"
cd ../my-worker
bundle install
npm install

export PICORUBY_ROOT=/path/to/picoruby
# Set local mrbgem paths in build_config.rb as shown below before building

# Activate Emscripten 5.0.7 before running these commands
bundle exec rake doctor
bundle exec rake
npm run dev
```

Use a PicoRuby checkout with its submodules initialized. This gem does not initialize submodules or install the SDK.
`doctor` checks key PicoRuby files, emcc, emar, Node.js, and jsonc-parser.
The build also checks the Emscripten version required by the mrbgem. Use a Node.js version supported by Wrangler.
Build paths containing spaces or shell metacharacters are rejected because of upstream shell command expansion limitations.

To try a packaged gem, run `gem build picoruby-cloudflare-template.gemspec`, followed by
`gem install ./picoruby-cloudflare-template-0.1.0.gem` and
`picoruby-cloudflare new my-worker`. Use `bundle install --local` in the generated project to resolve the unpublished version.
Once the gem is published to RubyGems, you can start with the usual `gem install picoruby-cloudflare-template`.

## Generated files and build configuration

`new PATH [--name NAME] [--gem-path PATH]` generates a Gemfile, Rakefile, build_config.rb, a minimal Rack app in app.rb,
src/index.js, package.json, wrangler.jsonc, .gitignore, and README.md.
An existing destination is never overwritten, even if it is an empty directory. Commit Gemfile.lock and package-lock.json in your application repository.

```ruby
require "picoruby/cloudflare/build"

MRuby::CrossBuild.new("worker") do |conf|
  # Optional: local checkouts take precedence over revisions.
  # conf.picoruby_cloudflare_worker_wasm_mgem_dir = "/path/to/picoruby-cloudflare-worker-wasm"
  # conf.mruby_rack_mgem_dir = "/path/to/mruby-rack"
  # conf.picoruby_cloudflare_worker_wasm_revision = "<commit SHA>"
  # conf.mruby_rack_mgem_revision = "<commit SHA>"
  conf.cloudflare_worker!
  # conf.gem gemdir: File.join(__dir__, "vendor/my-gem")
  conf.worker_export(
    app: "app.rb",
    output_dir: "generated/worker",
    wrangler_config: "wrangler.jsonc",
    environment: ENV["CLOUDFLARE_ENV"],
    project_root: __dir__,
  )
end
```

Place this require in build_config.rb, after PicoRuby has loaded its build system.
`cloudflare_worker!` configures Emscripten, Wasm longjmp, the Worker HAL, PicoRuby, Rack, and the required core mrbgems.
Add frameworks such as Sinatra in your application configuration. ABI-specific final link settings, such as JSPI exports, belong to the runtime library.
Set the attributes above **before** calling `cloudflare_worker!`. The `!` marks its changes to the build configuration.
Both directory attributes default to `nil`; in that case the gem is declared with `github:` and `checksum_hash:` using its revision attribute.
A directory takes precedence over its revision, and relative directory paths are resolved against the build_config directory.
Revision attributes default to the values bundled in this gem; assigning `nil` restores those defaults.
Dependency source selection no longer reads `PICORUBY_WORKER_WASM_GEM_DIR` or `MRUBY_RACK_GEM_DIR`, or accepts `worker:` / `rack:` arguments.

The default Worker revision is pinned to `e6235bca616dbd4cec619cc0141facdea59a5541`,
and Rack to `05ba46eb0ab490a624a5f2dcb33249670933ff6b`.
Use a local checkout if a revision has not been published to the remote repository. Before publishing this gem, verify that a fresh checkout can fetch the pinned revisions.

Relative paths passed to `worker_export` are resolved against `project_root`, which defaults to the build_config directory.
The generated Rakefile runs PicoRuby's Rake in a separate process and keeps build output in the application's `.picoruby-build/` directory.
The application is compiled with the `mrbcfile` resolved by CrossBuild, without relying on an existing `build/host/bin/mrbc`.

## ES module output and responsibilities

```text
generated/worker/
  app.bin
  bindings.js
  package.json            # private: true, type: module
  manifest.json           # Generator version, Worker revision, artifact SHA256 hashes
  runtime/
    index.js              # createWorker({ app, bindingTypes })
    runtime.js
    host-bridge.js
    picoruby-worker.js
    picoruby-worker.wasm
  tools/                  # Binding registry generation scripts
```

The runtime library owns the Ruby/C code, HAL, and shared JS bridge. This gem owns the templates, CrossBuild DSL, export logic, and thin createWorker entry point.
Shared JS and registry generation scripts are copied from **the same mrbgem checkout** used to build Wasm.
Their current locations are `spike/src/` and `spike/scripts/`. This gem does not maintain a separate copy of those implementations.
If that layout changes, update the exporter and pinned revision together.

`createWorker` creates and closes a VM for each request, without sharing env between requests.
The low-level `createRuntime` / `dispatch` / `closeRuntime` functions are also re-exported.
If you explicitly reuse a VM, the runtime library serializes dispatches to that VM.
The output is intended to be bundled with Wrangler; it does not make `.wasm` / `.bin` imports directly usable in Node.js.
Check the license requirements of the original mrbgems and any additional dependencies before redistributing artifacts.

Rake dependencies determine when to recompile the application, and export leaves files unchanged when their content is identical.
The registry is validated and generated on every build to reflect environment changes. A missing Wasm file in the original build output also triggers relinking.
However, the tested PicoRuby version rewrites src/version.c on every build, so that file is recompiled and the runtime is relinked even when nothing else has changed.

## Bindings, environments, and Wrangler

The type registry is generated from `kv_namespaces` / `queues.producers` in wrangler.jsonc.
JSONC comments and trailing commas are supported. Invalid configuration, duplicate binding names, and nonexistent environments cause build errors.
Variable values and secrets are not embedded in build artifacts.

```ruby
kv = Cloudflare::KV.from_env(env, "CACHE_KV")
kv.put("key", "value", ttl: 60)
value = env["cloudflare.env"].CACHE_KV.get("key")
Cloudflare::Queue.from_env(env, "EVENTS").send("created")
token = ENV["API_TOKEN"]
```

Queue sending currently supports UTF-8 strings only, matching the runtime API. Manage secrets through .dev.vars or `wrangler secret put`, and keep them out of Git.
With `npm run dev` / `npm run deploy`, Wrangler's custom build runs Rake.
`build.watch_dir` covers app.rb and build_config.rb. Update the watch list when adding Ruby files.

```sh
CLOUDFLARE_ENV=staging npm run dev
CLOUDFLARE_ENV=staging npm run deploy
```

Selecting a named environment with only `--env staging` does not pass the environment name to the custom build.
Make sure Wrangler and the exporter use the same `CLOUDFLARE_ENV` value.
Define resource bindings for each environment; they are not inherited from the top-level configuration.

## Tests and reproduction

```sh
bundle exec rake test

PICORUBY_ROOT=/path/to/picoruby \
PICORUBY_WORKER_WASM_GEM_DIR=/path/to/picoruby-cloudflare-worker-wasm \
MRUBY_RACK_GEM_DIR=/path/to/mruby-rack \
bundle exec rake test:integration
```

The mrbgem environment variables in this test command are inputs to the integration harness only.
It writes explicit directory attributes into the generated build_config and clears those variables before invoking the build.

Unit tests cover the CLI, overwrite protection, path validation, DSL, compiler selection, incremental export, missing-Wasm recovery, and preservation of bytecode after compilation failures.
Integration tests cover project generation, dependency installation, builds, Wrangler dry-run, local HTTP and hot reload, ENV/KV TTL/Queue through actual Wasm,
env isolation between concurrent requests, environment switching, and missing-Wasm recovery.
Integration tests require a Node.js version with JSPI support. They do not deploy Workers or create Cloudflare resources.
All artifacts and step-by-step logs are retained in the temporary directory printed by the test for troubleshooting.

Tested with PicoRuby `33540f66d9aba633d4d3ebd6707d5c12baebb652`, the Worker/Rack revisions above,
Ruby 4.0.5, Emscripten 5.0.7, Node.js 26.8.1, and Wrangler 4.125.0.
The compatibility date is `2026-08-22`, tested with the pinned Wrangler version.
A dry-run does not start workerd, so verify local HTTP responses when updating Wrangler or the compatibility date.
Rerun the integration tests when PicoRuby or the mruby submodule's build API changes.
