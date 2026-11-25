const { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } = require('node:fs');
const { dirname, join, resolve } = require('node:path');
const { check } = require('./gate.cjs');

const outcomes = ['pass', 'regression', 'inconclusive'];

function readPairs(filename) {
  const manifest = JSON.parse(readFileSync(filename, 'utf8').replace(/^\uFEFF/, ''));
  if (manifest?.schema_version !== 1 || !Array.isArray(manifest.pairs) || !manifest.pairs.length) {
    throw Error('Expected schema_version 1 and a nonempty pairs array.');
  }
  const directory = dirname(resolve(filename));
  const ids = new Set();
  return manifest.pairs.map((pair, index) => {
    const { id, baseline, candidate } = pair ?? {};
    if (![id, baseline, candidate].every(value => typeof value === 'string' && value.trim() && !value.includes('\0'))) {
      throw Error(`Pair ${index + 1} must contain nonempty id, baseline and candidate strings.`);
    }
    if (ids.has(id)) throw Error(`Pair ${index + 1} has a duplicate id.`);
    ids.add(id);
    return { id, baseline: resolve(directory, baseline), candidate: resolve(directory, candidate) };
  });
}

function markdownSummary(summary) {
  const lines = [
    '# PDFTextGuard suite',
    '',
    `Result **${summary.outcome}** (exit ${summary.exit_code}).`,
    ...outcomes.map(outcome => `- ${outcome}: ${summary.counts[outcome]}`),
    '',
    '| Pair | Outcome | Reports |',
    '| --- | --- | --- |',
  ];
  for (const row of summary.pairs) {
    const id = row.id.replace(/[\r\n]+/g, ' ')
      .replace(/[\p{P}\p{Cc}\p{Cf}<>=+|~$]/gu, letter => `&#${letter.codePointAt(0)};`);
    lines.push(`| ${id} | ${row.outcome} | [JSON](${row.report_path}) · [Markdown](${row.markdown_path}) |`);
  }
  return lines.join('\n') + '\n';
}

function runSuite(manifest, output, markdown = false) {
  const input = readPairs(manifest);
  const directory = resolve(output);
  mkdirSync(directory);
  const counts = {pass: 0, regression: 0, inconclusive: 0};
  let exitCode = 0;
  let version;
  const pairs = input.map((pair, index) => {
    const name = 'pair-' + String(index + 1).padStart(3, '0');
    const reportPath = name + '.json';
    const markdownPath = markdown ? name + '.md' : undefined;
    const sidecar = markdownPath && join(directory, markdownPath);
    const report = check(pair.baseline, pair.candidate, sidecar);
    if (sidecar && !existsSync(sidecar)) throw Error(`Could not write Markdown for pair ${index + 1}.`);
    writeFileSync(join(directory, reportPath), JSON.stringify(report, null, 2) + '\n', {flag: 'wx'});
    counts[report.outcome]++;
    exitCode = Math.max(exitCode, report.exit_code);
    version = report.tool_version;
    return {id: pair.id, outcome: report.outcome, exit_code: report.exit_code,
      report_path: reportPath, ...(markdownPath && {markdown_path: markdownPath})};
  });
  const summary = {
    schema_version: 1, kind: 'suite', tool_version: version, outcome: outcomes[exitCode],
    exit_code: exitCode, counts, pairs,
  };
  const markdownPath = markdown ? join(directory, 'summary.md') : undefined;
  if (markdownPath) writeFileSync(markdownPath, markdownSummary(summary), {flag: 'wx'});
  const reportPath = join(directory, 'summary.json');
  const pending = reportPath + '.tmp';
  writeFileSync(pending, JSON.stringify(summary, null, 2) + '\n', {flag: 'wx'});
  renameSync(pending, reportPath);
  return {summary, directory, reportPath, markdownPath};
}

if (require.main === module) {
  try {
    const [manifest, output, flag, ...extra] = process.argv.slice(2);
    if (!manifest || !output || (flag !== undefined && flag !== '--markdown') || extra.length) {
      throw Error('Usage: node verification/suite.cjs pairs.json reports [--markdown]');
    }
    const result = runSuite(manifest, output, flag === '--markdown');
    console.log(`PDFTextGuard suite: ${result.summary.outcome}. Report: ${result.reportPath}`);
    process.exitCode = result.summary.exit_code;
  } catch (error) {
    console.error('PDFTextGuard suite: ' + error.message);
    process.exitCode = 2;
  }
}

module.exports = { runSuite };
