class App
  def self.call(env)
    value = case env["PATH_INFO"]
    when "/access/middleware"
      env["cloudflare.identity"].email
    when "/kv"
      kv = Cloudflare::KV.from_env(env, "CACHE_KV")
      kv.put("key", "stored", ttl: 60)
      env["cloudflare.env"].CACHE_KV.get("key")
    when "/queue"
      Cloudflare::Queue.from_env(env, "EVENTS").send("created")
      "queued"
    when "/access"
      begin
        identity = Cloudflare::Access.get_identity(env["rack.input"].read, team: ENV["CF_ACCESS_TEAM"])
        JSON.generate([identity.email, identity.user_uuid, identity.raw_data,
                       identity.is_a?(Rack::Cloudflare::AccessIdentity)])
      rescue => error
        error.class.to_s
      end
    when "/fetch"
      response = Cloudflare.fetch("https://example.test/api", method: "POST",
        headers: { "content-type" => "text/plain" }, body: "hello\u0000world")
      JSON.generate([response.status, response.headers["x-example"], response.body])
    else
      ENV["GREETING"] || "missing"
    end
    [200, { "content-type" => "text/plain" }, [value + "\n"]]
  end
end

protected_app = Rack::Builder.new do
  use Rack::Cloudflare::Access, team: "my-team"
  run App
end
Rackup::Handler::CloudflareWorker.run(lambda do |env|
  env["PATH_INFO"] == "/access/middleware" ? protected_app.call(env) : App.call(env)
end)
