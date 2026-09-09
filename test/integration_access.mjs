import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const root = path.resolve(process.argv[2], "generated/worker");
const { default: create } = await import(pathToFileURL(path.join(root, "runtime/picoruby-worker.js")));
const { handleRequest, createCloudflareBindings } = await import(pathToFileURL(path.join(root, "runtime/runtime.js")));
const wasm = new WebAssembly.Module(fs.readFileSync(path.join(root, "runtime/picoruby-worker.wasm")));
const app = fs.readFileSync(path.join(root, "app.bin"));
const originalFetch = globalThis.fetch;
let calls = 0;
async function request(env, token) {
  return handleRequest(create, wasm, app, new Request("https://example.test/access", {
    headers: token === undefined ? {} : { Cookie: `other=value; CF_Authorization=${token}` },
  }), createCloudflareBindings(env, {}));
}
try {
  globalThis.fetch = async request => {
    calls++;
    assert.equal(request.url, "https://my-team.cloudflareaccess.com/cdn-cgi/access/get-identity");
    assert.equal(request.redirect, "manual");
    const token = request.headers.get("cookie").slice("CF_Authorization=".length);
    await Promise.resolve();
    return Response.json({ email: `${token}@example.test`, user_uuid: token });
  };
  assert.equal((await request({})).status, 503);
  assert.equal((await request({ CF_ACCESS_TEAM: "" })).status, 503);
  assert.equal((await request({ CF_ACCESS_TEAM: "my-team" })).status, 401);
  assert.equal(calls, 0);
  const responses = await Promise.all(["alice", "bob"].map(token => request({ CF_ACCESS_TEAM: "my-team" }, token)));
  for (const [index, token] of ["alice", "bob"].entries()) {
    assert.equal(responses[index].status, 200);
    assert.equal(await responses[index].text(), `${token}@example.test\n`);
  }
  globalThis.fetch = async () => new Response("rejected", { status: 403 });
  assert.equal((await request({ CF_ACCESS_TEAM: "my-team" }, "rejected")).status, 401);
  globalThis.fetch = async () => new Response("not json");
  assert.equal((await request({ CF_ACCESS_TEAM: "my-team" }, "malformed")).status, 502);
  globalThis.fetch = async () => { throw new Error("network failure"); };
  assert.equal((await request({ CF_ACCESS_TEAM: "my-team" }, "unavailable")).status, 502);
  console.log("Generated Access example: setup, cookies, identity, request isolation and errors passed");
} finally {
  globalThis.fetch = originalFetch;
}
