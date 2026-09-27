import createPicoRuby from "./picoruby-worker.js";
import wasm from "./picoruby-worker.wasm";
import * as runtime from "./runtime.js";

export function createWorker({ app, bindingTypes, rackEnv, afterRequest }) {
  return {
    async fetch(request, env, ctx) {
      try {
        const bindings = runtime.createCloudflareBindings(env, bindingTypes);
        if (rackEnv === undefined && afterRequest === undefined) {
          return await runtime.handleRequest(createPicoRuby, wasm, app, request, bindings);
        }
        if (typeof runtime.handleRequestWithOptions !== "function") {
          throw new Error("This Worker runtime does not support rackEnv or afterRequest; update the Worker revision");
        }
        const options = { env, ctx };
        if (rackEnv !== undefined) {
          if (typeof rackEnv !== "function") throw new TypeError("rackEnv must be a function");
          options.rackEnv = await rackEnv(request, env, ctx);
        }
        if (afterRequest !== undefined) options.afterRequest = afterRequest;
        return await runtime.handleRequestWithOptions(createPicoRuby, wasm, app, request, options, bindings);
      } catch (error) {
        console.error("PicoRuby Worker request failed", error);
        if (error instanceof runtime.RequestBodyTooLargeError) {
          return new Response("Request body too large", { status: 413 });
        }
        return new Response("PicoRuby Worker runtime error", { status: 500 });
      }
    },
  };
}

export { createCloudflareBindings, createRuntime, dispatch, closeRuntime } from "./runtime.js";
export { PicoRubyDurableObject } from "./durable-object.js";
