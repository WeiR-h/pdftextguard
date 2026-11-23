// Keep comparison outputs available before the composite action enforces the result.
const { appendFileSync, mkdtempSync, writeFileSync } = require('node:fs');
const { join } = require('node:path');

const { PDFTEXTGUARD_BUNDLE, PDFTEXTGUARD_BASELINE, PDFTEXTGUARD_CANDIDATE,
  RUNNER_TEMP, GITHUB_OUTPUT } = process.env;
if (!PDFTEXTGUARD_BASELINE || !PDFTEXTGUARD_CANDIDATE) {
  throw Error('The baseline and candidate PDF paths are both required.');
}

const { check } = require(join(PDFTEXTGUARD_BUNDLE, 'verification/gate.cjs'));
const directory = mkdtempSync(join(RUNNER_TEMP, 'pdftextguard-report-'));
const output = join(directory, 'report.json');
const report = check(PDFTEXTGUARD_BASELINE, PDFTEXTGUARD_CANDIDATE);
writeFileSync(output, JSON.stringify(report, null, 2) + '\n', 'utf8');
appendFileSync(GITHUB_OUTPUT,
  `report-path=${output}\noutcome=${report.outcome}\nexit-code=${report.exit_code}\n`, 'utf8');
console.log(`PDFTextGuard: ${report.outcome}. Report: ${output}`);
