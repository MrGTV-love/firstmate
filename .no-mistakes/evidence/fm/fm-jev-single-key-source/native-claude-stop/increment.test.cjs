const assert = require('node:assert/strict');
const test = require('node:test');
const { increment } = require('./increment.cjs');
test('increment adds one to integers including negative values', async () => {
  await new Promise(resolve => setTimeout(resolve, 4000));
  assert.equal(increment(0), 1);
  assert.equal(increment(41), 42);
  assert.equal(increment(-2), -1);
});
