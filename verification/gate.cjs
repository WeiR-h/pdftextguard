const { readFileSync, writeFileSync } = require('node:fs');
const { join } = require('node:path');
const { spawnSync } = require('node:child_process');

function check(baseline, candidate) {
  const manifest = readFileSync(join(__dirname, '../moon.mod'), 'utf8');
  const version = manifest.match(/^version = "([0-9.]+)"$/m)[1];
  const binary = join(__dirname, '../dist', 'pdftextguard-v' + version + '.cjs');
  const result = spawnSync(process.execPath, [binary, 'check', baseline, candidate, '--json'], {
    encoding: 'utf8', timeout: 60_000, maxBuffer: 4 * 1024 * 1024,
  });
  if (result.error) throw result.error;
  if (![0, 1, 2].includes(result.status)) {
    throw Error('PDFTextGuard did not produce a report: ' + result.stderr);
  }
  const report = JSON.parse(result.stdout);
  if (report.schema_version !== 1 || report.tool_version !== version ||
      report.exit_code !== result.status ||
      report.outcome !== ['pass', 'regression', 'inconclusive'][result.status]) {
    throw Error('Unexpected PDFTextGuard report');
  }
  return report;
}

if (require.main === module) {
  const [baseline, candidate, output, ...extra] = process.argv.slice(2);
  if (!baseline || !candidate || !output || extra.length) {
    throw Error('Usage: node verification/gate.cjs baseline.pdf candidate.pdf report.json');
  }
  const report = check(baseline, candidate);
  writeFileSync(output, JSON.stringify(report, null, 2) + '\n', 'utf8');
  console.log('PDFTextGuard: ' + report.outcome + '. Report: ' + output);
  process.exitCode = report.exit_code;
}

module.exports = { check };
