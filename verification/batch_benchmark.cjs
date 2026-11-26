const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const { createHash } = require('node:crypto');
const { mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } = require('node:fs');
const { cpus, tmpdir } = require('node:os');
const { dirname, join, resolve, relative } = require('node:path');

const output = process.argv[2];
if (!output || process.argv.length !== 3) throw Error('Usage: node verification/batch_benchmark.cjs result.json');

const root = resolve(__dirname, '..');
const version = readFileSync(join(root, 'moon.mod'), 'utf8').match(/^version = "([\d.]+)"$/m)[1];
const sample = join(root, 'examples', 'quote-pairs.json');
const { pairs: controls } = JSON.parse(readFileSync(sample, 'utf8'));
assert.equal(controls.length, 3);
const pairs = Array.from({length: 20}, (_, index) => {
  const pair = controls[index % controls.length];
  return {
    id: `报价单-${index + 1}`,
    baseline: resolve(dirname(sample), pair.baseline),
    candidate: resolve(dirname(sample), pair.candidate),
  };
});
const digest = path => createHash('sha256').update(readFileSync(path)).digest('hex');
const temp = realpathSync(tmpdir());
const directory = mkdtempSync(join(temp, 'pdftextguard-batch-benchmark-'));
assert.equal(dirname(directory), temp);
try {
  const manifest = join(directory, 'pairs.json');
  const reports = join(directory, 'reports');
  writeFileSync(manifest, JSON.stringify({schema_version: 1, pairs}), 'utf8');
  const start = performance.now();
  const result = spawnSync(process.execPath, [join(__dirname, 'suite.cjs'), manifest, reports, '--markdown'], {
    encoding: 'utf8', timeout: 120_000,
  });
  const elapsed = performance.now() - start;
  if (result.error) throw result.error;
  assert.equal(result.status, 2, result.stderr);
  const summary = JSON.parse(readFileSync(join(reports, 'summary.json'), 'utf8'));
  assert.equal(summary.tool_version, version);
  assert.deepEqual(summary.pairs.map(pair => pair.exit_code), pairs.map((_, index) => index % 3));
  for (const pair of summary.pairs) {
    assert.ok(readFileSync(join(reports, pair.report_path)).length);
    assert.ok(readFileSync(join(reports, pair.markdown_path)).length);
  }
  const inputs = new Set(pairs.flatMap(pair => [pair.baseline, pair.candidate]));
  const proof = {
    schema_version: 1,
    metric: 'elapsed CLI time for 20 sequential quote pairs including Node startup, JSON and Markdown',
    toolVersion: version,
    artifactSha256: digest(join(root, 'dist', `pdftextguard-v${version}.cjs`)),
    platform: process.platform,
    node: process.version,
    cpu: cpus()[0].model.trim(),
    pairs: pairs.length,
    counts: summary.counts,
    elapsed_ms: Number(elapsed.toFixed(2)),
    inputSha256: Object.fromEntries([...inputs].map(path => [relative(root, path).split('\\').join('/'), digest(path)])),
  };
  writeFileSync(output, JSON.stringify(proof, null, 2) + '\n', 'utf8');
  console.log(`20 quote pairs with JSON and Markdown: ${proof.elapsed_ms} ms.`);
} finally {
  rmSync(directory, {recursive: true, force: true});
}
