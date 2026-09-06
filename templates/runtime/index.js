import createPicoRuby from "./picoruby-worker.js";
import wasm from "./picoruby-worker.wasm";
import { createCloudflareBindings, handleRequest, RequestBodyTooLargeError } from "./runtime.js";

export function createWorker({ app, bindingTypes }) {
  return {
    async fetch(request, env) {
      try {
        return await handleRequest(createPicoRuby, wasm, app, request, createCloudflareBindings(env, bindingTypes));
      } catch (error) {
        // Do not log host error messages: upstream services may include secrets.
        if (error instanceof RequestBodyTooLargeError) {
          return new Response("Request body too large", { status: 413 });
        }
        console.error("PicoRuby Worker request failed");
        return new Response("PicoRuby Worker runtime error", { status: 500 });
      }
    },
  };
}

export { createCloudflareBindings, createRuntime, dispatch, closeRuntime } from "./runtime.js";
