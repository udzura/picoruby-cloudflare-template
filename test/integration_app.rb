class App
  def self.call(env)
    value = case env["PATH_INFO"]
    when "/kv"
      kv = Cloudflare::KV.from_env(env, "CACHE_KV")
      kv.put("key", "stored", ttl: 60)
      env["cloudflare.env"].CACHE_KV.get("key")
    when "/queue"
      Cloudflare::Queue.from_env(env, "EVENTS").send("created")
      "queued"
    else
      ENV["GREETING"] || "missing"
    end
    [200, { "content-type" => "text/plain" }, [value + "\n"]]
  end
end

Rackup::Handler::CloudflareWorker.run(App)
