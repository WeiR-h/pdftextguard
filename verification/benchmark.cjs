// End-to-end CLI wall time. Interleave versions, validate every timed result.
const assert = require('node:assert/strict');
const { createHash } = require('node:crypto');
const { readFileSync, writeFileSync } = require('node:fs');
const { join } = require('node:path');
const { cpus } = require('node:os');
const { spawnSync } = require('node:child_process');
const { performance } = require('node:perf_hooks');

const root = join(__dirname, '..');
const versions = process.argv.slice(2);
if (!versions.length || versions.some(v => !/^v0\.0\.\d+$/.test(v))) {
  throw Error('Usage: node verification/benchmark.cjs v0.0.1 [v0.0.x ...]');
}
const repetitions = 9;
const digest = file => createHash('sha256').update(readFileSync(file)).digest('hex');
const inputs = JSON.parse(readFileSync(join(root, '.work/benchmark/inputs.json'), 'utf8'));
const builds = versions.map(version => {
  const binary = join(root, 'dist', 'pdftextguard-' + version + '.cjs');
  return {version, binary, sha256: digest(binary)};
});

function check(build, input) {
  const command = [build.binary, 'check', join(root, input.baseline), join(root, input.candidate), '--json'];
  const start = performance.now();
  const output = spawnSync(process.execPath, command, {
    encoding: 'utf8', timeout: 60_000, maxBuffer: 2 * 1024 * 1024,
  });
  const elapsed = performance.now() - start;
  if (output.error) throw output.error;
  assert.equal(output.status, 0, output.stdout + output.stderr);
  const report = JSON.parse(output.stdout);
  assert.equal('v' + report.tool_version, build.version);
  assert.equal(report.aligned_glyphs, input.glyph_occurrences);
  assert.equal(report.compared_glyphs, input.glyph_occurrences);
  assert.equal(report.mismatched_occurrences, 0);
  return Math.round(elapsed * 100) / 100;
}

const result = inputs.map(input => {
  assert.deepEqual([input.baseline, input.candidate].map(p => digest(join(root, p))), input.input_sha256);
  const measurements = builds.map(build => ({
    version: build.version, binary_sha256: build.sha256, samples_ms: [],
  }));
  for (const build of builds) check(build, input); // untimed warm-up per version
  for (let i = 0; i < repetitions; i++) {
    for (let j = 0; j < builds.length; j++) {
      const index = (i + j) % builds.length;
      measurements[index].samples_ms.push(check(builds[index], input));
    }
  }
  for (const m of measurements) {
    const sorted = [...m.samples_ms].sort((a, b) => a - b);
    m.median_ms = sorted[Math.floor(sorted.length / 2)];
    m.min_ms = sorted[0];
    m.max_ms = sorted.at(-1);
    console.log(input.name, m.version, m.median_ms + ' ms');
  }
  return {...input, measurements};
});
const stage = versions.length === 1 ? 'baseline' : 'comparison';
writeFileSync(join(root, '.work/benchmark', stage + '.json'), JSON.stringify({
  metric: 'end-to-end CLI wall time including Node startup and input I/O',
  repetitions, node: process.version, platform: process.platform, cpu: cpus()[0]?.model,
  workloads: result,
}, null, 2) + '\n');
