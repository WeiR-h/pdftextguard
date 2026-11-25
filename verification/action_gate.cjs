// Keep comparison outputs available before the composite action enforces the result.
const { appendFileSync, existsSync, mkdtempSync, writeFileSync } = require('node:fs');
const { join } = require('node:path');

const { PDFTEXTGUARD_BUNDLE, PDFTEXTGUARD_BASELINE, PDFTEXTGUARD_CANDIDATE, PDFTEXTGUARD_PAIRS, PDFTEXTGUARD_MARKDOWN,
  RUNNER_TEMP, GITHUB_OUTPUT } = process.env;
if (PDFTEXTGUARD_PAIRS ? (PDFTEXTGUARD_BASELINE || PDFTEXTGUARD_CANDIDATE)
  : (!PDFTEXTGUARD_BASELINE || !PDFTEXTGUARD_CANDIDATE)) {
  throw Error('Provide either baseline and candidate together or pairs-file.');
}
if (!['true', 'false'].includes(PDFTEXTGUARD_MARKDOWN)) {
  throw Error("markdown-report must be 'true' or 'false'.");
}

const directory = mkdtempSync(join(RUNNER_TEMP, 'pdftextguard-report-'));
const writeMarkdown = PDFTEXTGUARD_MARKDOWN === 'true';
let report, output, markdown;
const outputs = [];
if (PDFTEXTGUARD_PAIRS) {
  const { runSuite } = require(join(PDFTEXTGUARD_BUNDLE, 'verification/suite.cjs'));
  const result = runSuite(PDFTEXTGUARD_PAIRS, join(directory, 'suite'), writeMarkdown);
  report = result.summary;
  output = result.reportPath;
  markdown = result.markdownPath;
  outputs.push(`report-dir=${result.directory}`);
} else {
  const { check } = require(join(PDFTEXTGUARD_BUNDLE, 'verification/gate.cjs'));
  output = join(directory, 'report.json');
  markdown = writeMarkdown ? join(directory, 'report.md') : undefined;
  report = check(PDFTEXTGUARD_BASELINE, PDFTEXTGUARD_CANDIDATE, markdown);
  writeFileSync(output, JSON.stringify(report, null, 2) + '\n', 'utf8');
}
outputs.push(`report-path=${output}`, `outcome=${report.outcome}`, `exit-code=${report.exit_code}`);
if (markdown && existsSync(markdown)) {
  outputs.push(`markdown-path=${markdown}`);
}
appendFileSync(GITHUB_OUTPUT, outputs.join('\n') + '\n', 'utf8');
console.log(`PDFTextGuard: ${report.outcome}. Report: ${output}`);
