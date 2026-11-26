// Keep comparison outputs available before the composite action enforces the result.
const { appendFileSync, existsSync, mkdtempSync, readFileSync, writeFileSync } = require('node:fs');
const { join } = require('node:path');

const { PDFTEXTGUARD_BUNDLE, PDFTEXTGUARD_BASELINE, PDFTEXTGUARD_CANDIDATE, PDFTEXTGUARD_PAIRS, PDFTEXTGUARD_MARKDOWN,
  RUNNER_TEMP, GITHUB_OUTPUT, GITHUB_STEP_SUMMARY } = process.env;
if (PDFTEXTGUARD_PAIRS ? (PDFTEXTGUARD_BASELINE || PDFTEXTGUARD_CANDIDATE)
  : (!PDFTEXTGUARD_BASELINE || !PDFTEXTGUARD_CANDIDATE)) {
  throw Error('Provide either baseline and candidate together or pairs-file.');
}
if (!['true', 'false'].includes(PDFTEXTGUARD_MARKDOWN)) {
  throw Error("markdown-report must be 'true' or 'false'.");
}

const directory = mkdtempSync(join(RUNNER_TEMP, 'pdftextguard-report-'));
const writeMarkdown = PDFTEXTGUARD_MARKDOWN === 'true';
function appendJobSummary(makeText) {
  if (!GITHUB_STEP_SUMMARY) return;
  try {
    appendFileSync(GITHUB_STEP_SUMMARY, makeText(), 'utf8');
  } catch (error) {
    console.warn('Could not append the GitHub job summary: ' + (error.code || error.name));
  }
}

let report, output, markdown;
const outputs = [];
if (PDFTEXTGUARD_PAIRS) {
  const { runSuite, markdownSummary } = require(join(PDFTEXTGUARD_BUNDLE, 'verification/suite.cjs'));
  let publishedDirectory;
  try {
    const result = runSuite(PDFTEXTGUARD_PAIRS, join(directory, 'suite'), writeMarkdown, reportDir => {
      appendFileSync(GITHUB_OUTPUT, `report-dir=${reportDir}\n`, 'utf8');
      publishedDirectory = reportDir;
    });
    report = result.summary;
    output = result.reportPath;
    markdown = result.markdownPath;
    appendJobSummary(() => markdownSummary(report, false));
  } catch (error) {
    if (publishedDirectory) {
      appendJobSummary(() => {
        const file = join(publishedDirectory, 'execution-error.json');
        const heading = '# PDFTextGuard suite interrupted\n\nSee the retained reports for completed pairs.\n';
        if (!existsSync(file)) return heading;
        const failure = JSON.parse(readFileSync(file, 'utf8'));
        const pair = failure.pair ? ` for pair ${failure.pair.index}` : '';
        return heading + `\nCompleted pairs · ${failure.completed_pairs}. Failed at ${failure.stage}${pair}.\n`;
      });
    }
    throw error;
  }
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
