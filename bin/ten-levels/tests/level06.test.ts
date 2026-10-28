import test from "node:test";
import assert from "node:assert/strict";
import * as l6 from "../src/levels/level06/index.ts";

test("write: lexical roots reject escapes and the root itself", () => {
  assert.equal(l6.insideRepo("docs/x.md", "/repo"), true);
  assert.equal(l6.insideRepo("../x.md", "/repo"), false);
  assert.equal(l6.insideRepo("/repo", "/repo"), false);
});
