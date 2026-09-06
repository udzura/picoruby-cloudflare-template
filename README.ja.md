# picoruby-cloudflare-template

[English](README.md) | 日本語

PicoRuby向けCloudflare Workerプロジェクトの生成、CrossBuild設定、ローカルES module出力を担当するCRuby gemです。
Wasm実行時には不要です。npmパッケージの公開も不要です。

## クイックスタート（未公開版の開発中）

このリポジトリで実行します。

```sh
bundle install
bundle exec ruby exe/picoruby-cloudflare new ../my-worker --gem-path "$PWD"
cd ../my-worker
bundle install
npm install

export PICORUBY_ROOT=/path/to/picoruby
# ビルド前に、下記の例に従ってbuild_config.rbのローカルmrbgemパスを設定

# Emscripten 5.0.7を有効化してから実行
bundle exec rake doctor
bundle exec rake
npm run dev
```

PicoRubyはsubmodule初期化済みのチェックアウトを指定します。初期化・SDK導入はgemでは行いません。
`doctor` はPicoRubyの主要ファイル、emcc、emar、Node.js、jsonc-parserを確認します。
ビルド時にはmrbgemが要求するEmscriptenの版も検査します。Node.jsはWranglerがサポートする版を使用してください。
上流のシェルコマンド展開の制限により、ビルド用パスでは空白やシェル特殊文字を拒否します。

配布gemを試す場合は `gem build picoruby-cloudflare-template.gemspec`、
`gem install ./picoruby-cloudflare-template-0.1.0.pre.rc1.gem` の後、
`picoruby-cloudflare new my-worker` を使えます。生成先で未公開版を解決するには `bundle install --local` を使用します。
このリリース候補版を公開した後は `gem install picoruby-cloudflare-template --pre --version 0.1.0-rc1` でインストールできます。
`VERSION` は `0.1.0-rc1` ですが、RubyGemsはメタデータとgemファイル名で `0.1.0.pre.rc1` に正規化します。

## 生成物とビルド設定

`new PATH [--name NAME] [--gem-path PATH]` はGemfile、Rakefile、build_config.rb、最小Rackアプリのapp.rb、
src/index.js、package.json、wrangler.jsonc、.gitignore、README.mdを生成します。
生成先が存在する場合は空ディレクトリでも上書きしません。Gemfile.lockとpackage-lock.jsonはアプリ側でコミットしてください。

```ruby
require "picoruby/cloudflare/build"

MRuby::CrossBuild.new("worker") do |conf|
  conf.cloudflare_worker! do |cf|
    # 任意: ローカルチェックアウトはrevision指定より優先されます。
    # cf.picoruby_cloudflare_worker_wasm_mgem_dir = "/path/to/picoruby-cloudflare-worker-wasm"
    # cf.mruby_rack_mgem_dir = "/path/to/mruby-rack"
    # cf.picoruby_cloudflare_worker_wasm_revision = "<commit SHA>"
    # cf.mruby_rack_mgem_revision = "<commit SHA>"
  end
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

このrequireはPicoRubyのビルドシステム読込後、build_config.rb内で行います。
`cloudflare_worker!` はEmscripten、Wasm longjmp、Worker HAL、PicoRuby、Rackと必要なcore mrbgemを設定します。
Sinatra等のフレームワークはアプリ側で追加します。ABI固有の最終リンク設定（JSPI export等）は実行時ライブラリが所有します。
属性は `cloudflare_worker!` のブロック内で設定します。ブロックにはCrossBuild自身が渡され、検証やビルド設定の本処理より先に実行されます。
ブロックなしでも呼べます。その場合は事前に属性を設定してください。`!` はビルド設定を書き換えることを示します。
両方のディレクトリ属性はデフォルト `nil` で、その場合はrevision属性を使い、`github:` と `checksum_hash:` でgemを宣言します。
ディレクトリ指定はrevision指定より優先され、相対ディレクトリはbuild_configのディレクトリ基準で解決します。
revision属性のデフォルトはこのgemに組み込まれた値です。`nil` を代入するとデフォルトに戻ります。
取得先の選択で `PICORUBY_WORKER_WASM_GEM_DIR` / `MRUBY_RACK_GEM_DIR` は参照せず、`worker:` / `rack:` 引数も受け取りません。

既定のWorker revisionは `e6235bca616dbd4cec619cc0141facdea59a5541`、
Rackは `05ba46eb0ab490a624a5f2dcb33249670933ff6b` に固定しています。
revisionがリモート未公開の場合はローカル指定が必要です。gem公開前に、新規チェックアウトから固定revisionを取得できることも確認してください。

`worker_export` に渡す相対パスは `project_root` 基準（省略時はbuild_configのディレクトリ）です。
生成されたRakefileはPicoRubyのRakeを別プロセスで実行し、ビルドをアプリ内の `.picoruby-build/` に分離します。
アプリはCrossBuildが解決した `mrbcfile` でコンパイルし、既存の `build/host/bin/mrbc` には依存しません。

## ES module出力と責務

```text
generated/worker/
  app.bin
  bindings.js
  package.json            # private: true, type: module
  manifest.json           # generator版・Worker revision・成果物SHA256
  runtime/
    index.js              # createWorker({ app, bindingTypes })
    runtime.js
    host-bridge.js
    picoruby-worker.js
    picoruby-worker.wasm
  tools/                  # binding registry生成スクリプト
```

Ruby/C・HAL・共通JS bridgeは実行時ライブラリが、このgemはテンプレート・CrossBuild DSL・export処理・薄いcreateWorkerエントリを所有します。
共通JSとregistry生成スクリプトは、Wasmをビルドした**同じmrbgemチェックアウト**からコピーします。
現在の取得場所は `spike/src/` と `spike/scripts/` です。別コピーの実装をこのgemで管理しません。
レイアウト変更時はexporterと固定revisionを一緒に更新します。

`createWorker` はリクエストごとにVMを生成・破棄し、異なるリクエストのenvを共有しません。
低レベルの `createRuntime` / `dispatch` / `closeRuntime` も再exportします。
明示的にVMを再利用した場合、同じVMへのdispatchは実行時ライブラリが直列化します。
出力はWranglerでバンドルする前提です。Node.jsがそのまま `.wasm` / `.bin` importできるという意味ではありません。
再配布する場合は、元のmrbgemや追加依存のライセンス条件も確認してください。

アプリの再コンパイルはRakeの依存関係で判定し、exportは同じ内容なら書き直しません。
registryは環境変更を反映するため毎回検証・生成します。元ビルドのWasmが単独で欠けた場合も再リンクします。
ただし検証時のPicoRubyはsrc/version.cを毎回更新するため、無変更ビルドでもそのコンパイルと最終リンクが走ります。

## bindings・環境・Wrangler

wrangler.jsoncの `kv_namespaces` / `queues.producers` から型registryを生成します。
JSONCのコメント・末尾カンマに対応し、不正な設定・重複名・存在しない環境はビルドエラーにします。
varsの値やsecretはビルド成果物へ埋め込みません。

```ruby
kv = Cloudflare::KV.from_env(env, "CACHE_KV")
kv.put("key", "value", ttl: 60)
value = env["cloudflare.env"].CACHE_KV.get("key")
Cloudflare::Queue.from_env(env, "EVENTS").send("created")
token = ENV["API_TOKEN"]
```

Queueは現行APIに合わせてUTF-8文字列送信のみです。secretは.dev.varsまたは `wrangler secret put` で管理し、Gitへ追加しないでください。
`npm run dev` / `npm run deploy` ではWranglerのcustom buildがRakeを実行します。
`build.watch_dir` はapp.rbとbuild_config.rbです。Rubyファイルを増やしたときは監視対象も更新してください。

```sh
CLOUDFLARE_ENV=staging npm run dev
CLOUDFLARE_ENV=staging npm run deploy
```

名前付き環境を `--env staging` だけで選ぶとcustom buildに環境名が伝わりません。
Wranglerとexporterが同じ `CLOUDFLARE_ENV` を参照するようにしてください。
リソースbindingは環境ごとに定義し、トップレベルから継承しません。

## テスト・最小再現

```sh
bundle exec rake test

PICORUBY_ROOT=/path/to/picoruby \
PICORUBY_WORKER_WASM_GEM_DIR=/path/to/picoruby-cloudflare-worker-wasm \
MRUBY_RACK_GEM_DIR=/path/to/mruby-rack \
bundle exec rake test:integration
```

このテストコマンドのmrbgem環境変数は、統合テスト用ハーネスへの入力に限定しています。
ハーネスは生成したbuild_configへディレクトリ属性を明示的に書き込み、ビルド実行前にこれらの環境変数を解除します。

単体テスト: CLI、非上書き、パス検証、DSL、compiler選択、増分export、欠損Wasm復旧、コンパイル失敗時の保護。
統合テスト: 新規生成・依存インストール・ビルド・Wrangler dry-run・ローカルHTTPとhot reload・実Wasm経由のENV/KV TTL/Queue・
並行リクエスト間のenv分離・環境切り替え・欠損Wasm復旧。
統合テスト用Node.jsはJSPI対応が必要です。デプロイやCloudflareリソースの作成はしません。
調査用に、表示した一時ディレクトリへ全成果物とステップ別ログを残します。

検証対象: PicoRuby `33540f66d9aba633d4d3ebd6707d5c12baebb652`、上記Worker/Rack revision、
Ruby 4.0.5、Emscripten 5.0.7、Node.js 26.8.1、Wrangler 4.125.0。
compatibility dateは固定Wranglerと組み合わせて確認した `2026-08-22` を使います。
dry-runはworkerdを起動しないため、Wrangler/dateの更新時はローカルHTTP確認も必要です。
PicoRubyやmruby submoduleのビルドAPI変更時には統合テストを再実行してください。

## ライセンス

このgemは [MIT License](LICENSE) で公開しています。
