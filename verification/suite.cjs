const { closeSync, existsSync, mkdirSync, openSync, readFileSync, renameSync,
  unlinkSync, writeFileSync } = require('node:fs');
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

function writeJson(path, value) {
  const pending = path + '.tmp';
  const file = openSync(pending, 'wx');
  try {
    try {
      writeFileSync(file, JSON.stringify(value, null, 2) + '\n', 'utf8');
    } finally {
      closeSync(file);
    }
    renameSync(pending, path);
  } catch (error) {
    try {
      unlinkSync(pending);
    } catch {
      // Keep the original failure if cleanup is also unavailable.
    }
    throw error;
  }
}

function runSuite(manifest, output, markdown = false, onReportDirectory) {
  const input = readPairs(manifest);
  const directory = resolve(output);
  mkdirSync(directory);
  const counts = {pass: 0, regression: 0, inconclusive: 0};
  const pairs = [];
  let exitCode = 0;
  let version;
  let stage = 'publish_report_dir';
  let activePair;
  try {
    onReportDirectory?.(directory);
    for (const [index, pair] of input.entries()) {
      activePair = {index: index + 1, id: pair.id};
      const name = 'pair-' + String(activePair.index).padStart(3, '0');
      const reportPath = name + '.json';
      const markdownPath = markdown ? name + '.md' : undefined;
      const sidecar = markdownPath && join(directory, markdownPath);
      stage = 'check';
      const report = check(pair.baseline, pair.candidate, sidecar);
      stage = 'write_report';
      if (sidecar && !existsSync(sidecar)) throw Error('Could not write Markdown.');
      writeJson(join(directory, reportPath), report);
      counts[report.outcome]++;
      exitCode = Math.max(exitCode, report.exit_code);
      version = report.tool_version;
      pairs.push({id: pair.id, outcome: report.outcome, exit_code: report.exit_code,
        report_path: reportPath, ...(markdownPath && {markdown_path: markdownPath})});
    }
    activePair = undefined;
    stage = 'write_summary';
    const summary = {
      schema_version: 1, kind: 'suite', tool_version: version, outcome: outcomes[exitCode],
      exit_code: exitCode, counts, pairs,
    };
    const markdownPath = markdown ? join(directory, 'summary.md') : undefined;
    if (markdownPath) writeFileSync(markdownPath, markdownSummary(summary), {flag: 'wx'});
    const reportPath = join(directory, 'summary.json');
    writeJson(reportPath, summary);
    return {summary, directory, reportPath, markdownPath};
  } catch (error) {
    const failure = {schema_version: 1, kind: 'suite_execution_error', stage,
      completed_pairs: pairs.length, ...(activePair && {pair: activePair})};
    try {
      writeJson(join(directory, 'execution-error.json'), failure);
    } catch {
      // The report directory may no longer be writable.
    }
    const context = activePair ? `${stage} for pair ${activePair.index}` : stage;
    throw Error(`Suite failed during ${context}: ${error.message}\nReports: ${directory}`, {cause: error});
  }
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
