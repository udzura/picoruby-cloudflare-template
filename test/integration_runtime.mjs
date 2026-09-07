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
async function request(pathname, bindings = env) {
  const response = await handleRequest(create, wasm, app, new Request(`https://example.test${pathname}`), createCloudflareBindings(bindings, types));
  assert.equal(response.status, 200);
  return response.text();
}
assert.equal(await request("/"), "integration\n");
assert.equal(await request("/kv"), "stored\n");
assert.equal(await request("/queue"), "queued\n");
assert.deepEqual(messages, ["created"]);
assert.deepEqual(await Promise.all([request("/", { ...env, GREETING: "a" }), request("/", { ...env, GREETING: "b" })]), ["a\n", "b\n"]);
console.log("Generated Wasm: ENV, KV ttl, Queue and concurrent request isolation passed");
