// Run real programs through the built playground runtime (web/dist/eigs.js)
// and require their exact output. A playground that links but cannot run a
// program must fail here, not deploy (hq#58 ES-OWF-1: the deployed v0.48.0
// playground aborted on every program while its check was green).
// Usage: node tools/playground_smoke.cjs [dist-dir]   (default web/dist)
'use strict';
const fs = require('fs');
const path = require('path');
const dist = path.resolve(process.argv[2] || 'web/dist');
for (const f of ['eigs.js', 'eigs.wasm']) {
  if (!fs.existsSync(path.join(dist, f))) { console.log(`FAIL: ${f} missing in ${dist}`); process.exit(1); }
}
// eigs.js is an Emscripten MODULARIZE build; load it as CommonJS.
const shim = path.join(dist, 'eigs.smoke.cjs');
fs.copyFileSync(path.join(dist, 'eigs.js'), shim);
const EigsModule = require(shim);
const cases = [
  ['print of "hello"', 'hello'],
  ['x is 2 + 3\nprint of x', '5'],
  ['define sq(n) as:\n    return n * n\nprint of (sq of 7)', '49'],
];
let out = [];
EigsModule({
  print: (t) => out.push(t),
  printErr: (t) => out.push('ERR: ' + t),
  locateFile: (f) => path.join(dist, f),
}).then((M) => {
  const run = M.cwrap('eigs_run_source', 'number', ['string']);
  let failed = 0;
  for (const [src, want] of cases) {
    out = [];
    let rc;
    try { rc = run(src); } catch (e) { rc = 'threw ' + e; }
    const got = out.join('\n');
    if (rc === 0 && got === want) {
      console.log(`PASS: ${JSON.stringify(src)} -> ${JSON.stringify(got)}`);
    } else {
      failed++;
      console.log(`FAIL: ${JSON.stringify(src)}: rc=${rc} out=${JSON.stringify(got)} want=${JSON.stringify(want)}`);
    }
  }
  fs.unlinkSync(shim);
  console.log(`PLAN: ${cases.length}`);
  process.exit(failed ? 1 : 0);
}).catch((e) => { console.log('FAIL: runtime did not initialise: ' + e); process.exit(1); });
