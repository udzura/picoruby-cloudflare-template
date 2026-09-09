import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const root = path.resolve(process.argv[2], "generated/worker");
const { default: create } = await import(pathToFileURL(path.join(root, "runtime/picoruby-worker.js")));
const { handleRequest, createCloudflareBindings } = await import(pathToFileURL(path.join(root, "runtime/runtime.js")));
const { cloudflareBindingTypes: types } = await import(pathToFileURL(path.join(root, "bindings.js")));
assert.deepEqual({ ...types }, { CACHE_KV: "kv", EVENTS: "queue" });
const wasm = new WebAssembly.Module(fs.readFileSync(path.join(root, "runtime/picoruby-worker.wasm")));
const app = fs.readFileSync(path.join(root, "app.bin"));
const values = new Map();
const messages = [];
const env = {
  GREETING: "integration",
  CACHE_KV: {
    async put(key, bytes, options) {
      assert.deepEqual(options, { expirationTtl: 60 });
      values.set(key, bytes);
    },
    async get(key, type) {
      assert.equal(type, "arrayBuffer");
      return values.get(key) ?? null;
    },
  },
  EVENTS: { async send(message, options) { assert.deepEqual(options, { contentType: "text" }); messages.push(message); } },
};
async function request(pathname, bindings = env, options) {
  const response = await handleRequest(create, wasm, app, new Request(`https://example.test${pathname}`, options), createCloudflareBindings(bindings, types));
  assert.equal(response.status, 200);
  return response.text();
}
assert.equal(await request("/"), "integration\n");
assert.equal(await request("/kv"), "stored\n");
assert.equal(await request("/queue"), "queued\n");
assert.deepEqual(messages, ["created"]);
assert.deepEqual(await Promise.all([request("/", { ...env, GREETING: "a" }), request("/", { ...env, GREETING: "b" })]), ["a\n", "b\n"]);
const originalFetch = globalThis.fetch;
try {
  globalThis.fetch = async request => {
    const token = request.headers.get("cookie").slice("CF_Authorization=".length);
    assert.equal(request.url, "https://my-team.cloudflareaccess.com/cdn-cgi/access/get-identity");
    if (token === "forbidden") return new Response("", { status: 403 });
    if (token === "malformed") return new Response("not JSON");
    if (token === "array") return Response.json([]);
    if (token === "network") throw new Error("test failure");
    return Response.json({ email: token + "@example.test", user_uuid: token, groups: ["developers"] });
  };
  const access = token => request("/access", { ...env, CF_ACCESS_TEAM: "my-team" }, { method: "POST", body: token });
  const identities = await Promise.all(["alice", "bob"].map(access));
  assert.equal(await request("/access/middleware", env, { headers: { Cookie: "CF_Authorization=alice" } }), "alice@example.test\n");
  for (const [index, token] of ["alice", "bob"].entries()) {
    assert.deepEqual(JSON.parse(identities[index]), [
      token + "@example.test", token,
      { email: token + "@example.test", user_uuid: token, groups: ["developers"] }, true,
    ]);
  }
  assert.equal(await access("forbidden"), "Cloudflare::Access::Unauthorized\n");
  assert.equal(await access("network"), "Cloudflare::HostError\n");
  for (const token of ["malformed", "array"]) assert.equal(await access(token), "Cloudflare::ProtocolError\n");
  for (const token of ["x; other=y", "x\0y", "", "x".repeat(16385)]) assert.equal(await access(token), "ArgumentError\n");
  assert.equal(await request("/access", { ...env, CF_ACCESS_TEAM: "https://evil.test" }, { method: "POST", body: "test" }), "ArgumentError\n");
  globalThis.fetch = async request => {
    assert.equal(request.url, "https://example.test/api");
    assert.equal(request.method, "POST");
    assert.equal(request.headers.get("content-type"), "text/plain");
    assert.equal(await request.text(), "hello\u0000world");
    return new Response("こんにちは\u0000\nworld", { status: 201, headers: { "x-example": "yes" } });
  };
  assert.deepEqual(JSON.parse(await request("/fetch")), [201, "yes", "こんにちは\u0000\nworld"]);
} finally {
  globalThis.fetch = originalFetch;
}
console.log("Generated Wasm: ENV, KV ttl, Queue, Access identity/errors and concurrent request isolation passed");
