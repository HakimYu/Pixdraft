const assert = require('node:assert/strict');
globalThis.self = globalThis;
globalThis.window = globalThis;
const requests = [];
const aborts = [];
globalThis.fetch = async (url, options) => {
  requests.push(url);
  assert.equal(options.redirect, 'manual');
  assert.equal(options.credentials, 'omit');
  assert.equal(options.mode, 'cors');
  options.signal.addEventListener('abort', () => aborts.push(url));
  switch (new URL(url).pathname) {
    case '/stream':
      assert.equal(options.method, 'POST');
      assert.equal(options.headers.get('authorization'), 'Bearer mock');
      assert.deepEqual(JSON.parse(new TextDecoder().decode(options.body)), {prompt: 'mock'});
      return new Response(new ReadableStream({start(controller) {
        options.signal.addEventListener('abort', () => controller.error(options.signal.reason));
        controller.enqueue(new TextEncoder().encode('data: preview\n\n'));
      }}), {headers: {'content-type': 'text/event-stream'}});
    case '/redirect':
      return {type: 'opaqueredirect'};
    case '/timeout':
      return new Promise((_, reject) => {
        options.signal.addEventListener('abort', () => reject(options.signal.reason));
      });
    default:
      throw new Error(`Unexpected request ${url}`);
  }
};
process.once('beforeExit', () => {
  assert.equal(requests.length, 3);
  assert.deepEqual(aborts, requests);
});
