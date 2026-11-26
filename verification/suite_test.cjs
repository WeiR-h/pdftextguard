const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync,
  rmSync, statSync, writeFileSync } = require('node:fs');
const { tmpdir } = require('node:os');
const { dirname, join, resolve } = require('node:path');

const repo = resolve(__dirname, '..');
const temp = realpathSync(tmpdir());
const work = mkdtempSync(join(temp, 'pdftextguard-suite-'));
assert.equal(dirname(work), temp);
const input = join(work, '导出 对照');
mkdirSync(input);
const fixtures = {
  '基准 export.pdf': 'pdfkit-0.18.0-300.pdf',
  '正常 export.pdf': 'subset-reordered.pdf',
  '错误 export.pdf': 'qpdf-wrong-unicode.pdf',
  '加密 export.pdf': 'encrypted.pdf',
  '报价 基准.pdf': 'quote-classic.pdf',
  '报价 压缩.pdf': 'quote-compressed.pdf',
  '报价 回归.pdf': 'quote-wrong-unicode.pdf',
  '报价 加密.pdf': 'quote-encrypted.pdf',
};
const good = {id: '正常', baseline: '基准 export.pdf', candidate: '正常 export.pdf'};
const regression = {...good, id: '回归 | <case>', candidate: '错误 export.pdf'};
const encrypted = {...good, id: '加密', candidate: '加密 export.pdf'};
const missing = {...good, id: '缺失', candidate: '找不到 export.pdf'};

const json = path => JSON.parse(readFileSync(path, 'utf8'));
function manifest(name, pairs) {
  const file = join(input, name + '.json');
  writeFileSync(file, JSON.stringify({schema_version: 1, pairs}), 'utf8');
  return file;
}

function invoke(script, args, env) {
  const result = spawnSync(process.execPath, [join(__dirname, script), ...args], {
    cwd: work, env: {...process.env, ...env}, encoding: 'utf8', timeout: 60_000,
  });
  if (result.error) throw result.error;
  assert.equal(result.signal, null);
  return result;
}

function compare(name, pairs, code, markdown) {
  const directory = join(work, name);
  const file = manifest(name, pairs);
  const args = [file, directory, ...(markdown ? ['--markdown'] : [])];
  const result = invoke('suite.cjs', args);
  assert.equal(result.status, code, result.stderr);
  assert.equal(result.stderr, '');
  const summary = json(join(directory, 'summary.json'));
  assert.equal(summary.schema_version, 1);
  assert.equal(summary.kind, 'suite');
  assert.equal(summary.exit_code, code);
  assert.equal(summary.outcome, ['pass', 'regression', 'inconclusive'][code]);
  assert.deepEqual(summary.pairs.map(row => row.id), pairs.map(pair => pair.id));
  const reports = summary.pairs.map(row => {
    const report = json(join(directory, row.report_path));
    assert.equal(report.schema_version, 1);
    assert.equal(report.tool_version, summary.tool_version);
    assert.equal(report.exit_code, row.exit_code);
    assert.equal(report.outcome, row.outcome);
    assert.equal(Boolean(row.markdown_path), markdown);
    if (markdown) {
      assert.match(readFileSync(join(directory, row.markdown_path), 'utf8'), /SHA-256/);
    }
    return report;
  });
  assert.equal(existsSync(join(directory, 'summary.md')), markdown);
  return {file, directory, summary, reports};
}

function action(outputs, inputs) {
  return invoke('action_gate.cjs', [], {
    PDFTEXTGUARD_BUNDLE: repo, PDFTEXTGUARD_MARKDOWN: 'true',
    PDFTEXTGUARD_PAIRS: '', PDFTEXTGUARD_BASELINE: '', PDFTEXTGUARD_CANDIDATE: '',
    RUNNER_TEMP: work, GITHUB_OUTPUT: outputs, GITHUB_STEP_SUMMARY: '', ...inputs,
  });
}

function readOutputs(file) {
  return Object.fromEntries(readFileSync(file, 'utf8').trimEnd().split('\n').map(line => {
    const index = line.indexOf('=');
    return [line.slice(0, index), line.slice(index + 1)];
  }));
}

function faultBundle(failOn) {
  const directory = join(work, 'fault-bundle');
  const verification = join(directory, 'verification');
  const dist = join(directory, 'dist');
  mkdirSync(verification, {recursive: true});
  mkdirSync(dist);
  copyFileSync(join(repo, 'moon.mod'), join(directory, 'moon.mod'));
  for (const name of ['suite.cjs', 'gate.cjs']) copyFileSync(join(__dirname, name), join(verification, name));
  const version = readFileSync(join(directory, 'moon.mod'), 'utf8').match(/^version = "([\d.]+)"$/m)[1];
  const binary = 'pdftextguard-v' + version + '.cjs';
  const real = JSON.stringify(join(repo, 'dist', binary));
  // Two deterministic failures in a scratch bundle. All other calls use the real checker.
  const wrapper = [
    "const { appendFileSync, mkdirSync } = require('node:fs');",
    "const { spawnSync } = require('node:child_process');",
    "const { basename, join } = require('node:path');",
    "const args = process.argv.slice(2);",
    "const candidate = basename(args[2]);",
    "appendFileSync(join(__dirname, 'checks.log'), candidate + '\\n', 'utf8');",
    `if (candidate === ${JSON.stringify(failOn)}) {`,
    "  if (process.env.PDFTEXTGUARD_TEST_FAILURE === 'write_report') {",
    "    const sidecar = args[args.indexOf('--markdown-report') + 1];",
    "    mkdirSync(sidecar.slice(0, -3) + '.json');",
    "  } else {",
    "    console.error('Simulated unexpected checker exit.');",
    "    process.exit(70);",
    "  }",
    "}",
    `const child = spawnSync(process.execPath, [${real}, ...args], {stdio: 'inherit'});`,
    "if (child.error) throw child.error;",
    "process.exitCode = child.status ?? 70;",
  ].join('\n');
  writeFileSync(join(dist, binary), wrapper, 'utf8');
  return {directory, log: join(dist, 'checks.log')};
}

try {
  for (const [name, fixture] of Object.entries(fixtures)) {
    copyFileSync(join(__dirname, 'fixtures', fixture), join(input, name));
  }

  const pass = compare('全部通过', [good, {...good, id: '绝对路径', candidate: join(input, good.candidate)}], 0, false);
  assert.deepEqual(pass.summary.counts, {pass: 2, regression: 0, inconclusive: 0});
  assert.ok(pass.reports.every(report => report.compared_glyphs === 300));

  const bad = compare('回归阻断', [regression], 1, false);
  assert.equal(bad.reports[0].mismatched_occurrences, 1);
  assert.deepEqual(bad.reports[0].diagnostics[0].candidate.unicode, ['U+005A']);

  const mixed = compare('混合 报告', [regression, encrypted, good], 2, true);
  assert.deepEqual(mixed.summary.counts, {pass: 1, regression: 1, inconclusive: 1});
  assert.deepEqual(mixed.reports.map(report => report.exit_code), [1, 2, 0]);
  const markdown = readFileSync(join(mixed.directory, 'summary.md'), 'utf8');
  assert.match(markdown, /回归 &#124; &#60;case&#62;/);
  assert.match(markdown, /\(pair-003\.md\)/);

  const absent = compare('缺少输入', [missing, good], 2, false);
  assert.equal(absent.reports[0].diagnostics[0].side, 'candidate');
  assert.equal(absent.reports[1].exit_code, 0);

  for (const [name, pairs, message] of [
    ['空清单', [], /nonempty pairs/],
    ['重复 ID', [good, good], /duplicate id/],
    ['无效路径', [{...good, candidate: 3}], /nonempty id, baseline and candidate/],
  ]) {
    const output = join(work, name);
    const result = invoke('suite.cjs', [manifest(name, pairs), output]);
    assert.equal(result.status, 2);
    assert.match(result.stderr, message);
    assert.ok(!existsSync(output));
  }
  const occupied = join(work, '已经存在的报告');
  mkdirSync(occupied);
  const keep = join(occupied, 'untouched.txt');
  writeFileSync(keep, 'do not overwrite');
  const conflict = invoke('suite.cjs', [mixed.file, occupied]);
  assert.equal(conflict.status, 2);
  assert.match(conflict.stderr, /EEXIST/);
  assert.equal(readFileSync(keep, 'utf8'), 'do not overwrite');
  assert.ok(!existsSync(join(occupied, 'summary.json')));

  const outputs = join(work, 'batch-output');
  const actionResult = action(outputs, {PDFTEXTGUARD_PAIRS: mixed.file});
  assert.equal(actionResult.status, 0, actionResult.stderr);
  const batch = readOutputs(outputs);
  assert.equal(batch['exit-code'], '2'); // the final composite step enforces this
  assert.equal(batch.outcome, 'inconclusive');
  assert.equal(dirname(batch['report-path']), batch['report-dir']);
  assert.deepEqual(json(batch['report-path']), mixed.summary);
  assert.equal(readFileSync(batch['markdown-path'], 'utf8'), markdown);

  const quotePass = {id: '中文报价正常', baseline: '报价 基准.pdf', candidate: '报价 压缩.pdf'};
  const quoteChange = {...quotePass, id: '中文报价回归 | <case>', candidate: '报价 回归.pdf'};
  const quoteEncrypted = {...quotePass, id: '中文报价加密', candidate: '报价 加密.pdf'};
  const quoteSuite = manifest('中文报价批量', [quotePass, quoteChange, quoteEncrypted]);
  const quoteOutputs = join(work, 'quote-outputs');
  const jobSummary = join(work, 'quote-job-summary.md');
  const quoteRun = action(quoteOutputs, {PDFTEXTGUARD_PAIRS: quoteSuite, GITHUB_STEP_SUMMARY: jobSummary});
  assert.equal(quoteRun.status, 0, quoteRun.stderr);
  const quoteFields = readOutputs(quoteOutputs);
  assert.equal(quoteFields['exit-code'], '2');
  const quoteReport = json(quoteFields['report-path']);
  assert.deepEqual(quoteReport.pairs.map(pair => pair.exit_code), [0, 1, 2]);
  const [affected] = quoteReport.pairs[1].affected_pages;
  assert.equal(affected.page, 2);
  assert.deepEqual(affected.diagnostic_codes, ['mapping_changed']);
  assert.ok(quoteReport.pairs[2].document_codes.includes('unsupported'));
  const job = readFileSync(jobSummary, 'utf8');
  assert.match(job, /中文报价回归 &#124; &#60;case&#62; \| regression \| Page 2 · mapping_changed/);
  assert.match(job, /中文报价加密 \| inconclusive \| Document · unsupported/);
  assert.doesNotMatch(job, /\(pair-\d+/);

  const singleOutputs = join(work, 'single-output');
  const single = action(singleOutputs, {PDFTEXTGUARD_BASELINE: join(input, good.baseline),
    PDFTEXTGUARD_CANDIDATE: join(input, good.candidate)});
  assert.equal(single.status, 0, single.stderr);
  const legacy = readOutputs(singleOutputs);
  assert.equal(legacy['exit-code'], '0');
  assert.equal(legacy.outcome, 'pass');
  assert.equal(json(legacy['report-path']).compared_glyphs, 300);
  assert.ok(existsSync(legacy['markdown-path']));
  assert.ok(!Object.hasOwn(legacy, 'report-dir'));

  const invalidOutputs = join(work, 'invalid-output');
  const invalid = action(invalidOutputs, {PDFTEXTGUARD_PAIRS: mixed.file,
    PDFTEXTGUARD_BASELINE: join(input, good.baseline)});
  assert.notEqual(invalid.status, 0);
  assert.match(invalid.stderr, /either baseline and candidate together or pairs-file/);
  assert.ok(!existsSync(invalidOutputs));

  const emptyOutputs = join(work, 'empty-action-output');
  const empty = action(emptyOutputs, {PDFTEXTGUARD_PAIRS: manifest('无效 Action 清单', [])});
  assert.notEqual(empty.status, 0);
  assert.match(empty.stderr, /nonempty pairs/);
  assert.ok(!existsSync(emptyOutputs));

  const faults = faultBundle(quoteChange.candidate);
  for (const stage of ['check', 'write_report']) {
    writeFileSync(faults.log, '', 'utf8');
    const output = join(work, 'partial-' + stage);
    const partialJob = join(work, `partial-${stage}.md`);
    const interrupted = action(output, {
      PDFTEXTGUARD_PAIRS: quoteSuite, PDFTEXTGUARD_BUNDLE: faults.directory,
      PDFTEXTGUARD_TEST_FAILURE: stage, GITHUB_STEP_SUMMARY: partialJob,
    });
    assert.notEqual(interrupted.status, 0);
    assert.ok(interrupted.stderr.includes(`during ${stage} for pair 2`), interrupted.stderr);
    const fields = readOutputs(output);
    assert.deepEqual(Object.keys(fields), ['report-dir']);
    const directory = fields['report-dir'];
    assert.deepEqual(json(join(directory, 'execution-error.json')), {
      schema_version: 1, kind: 'suite_execution_error', stage, completed_pairs: 1,
      pair: {index: 2, id: quoteChange.id},
    });
    assert.equal(json(join(directory, 'pair-001.json')).compared_glyphs, 224);
    assert.match(readFileSync(join(directory, 'pair-001.md'), 'utf8'), /SHA-256/);
    const partialText = readFileSync(partialJob, 'utf8');
    assert.ok(partialText.includes(`Completed pairs · 1. Failed at ${stage} for pair 2.`));
    assert.doesNotMatch(partialText, /\bResult\b/);
    for (const file of ['summary.json', 'summary.md', 'pair-002.json.tmp', 'pair-003.json', 'pair-003.md']) {
      assert.ok(!existsSync(join(directory, file)), file);
    }
    if (stage === 'write_report') {
      assert.ok(statSync(join(directory, 'pair-002.json')).isDirectory()); // the intentional collision
    } else {
      assert.ok(!existsSync(join(directory, 'pair-002.json')));
    }
    assert.deepEqual(readFileSync(faults.log, 'utf8').trimEnd().split('\n'),
      [quotePass.candidate, quoteChange.candidate]);
  }
  console.log(`PASS (${process.platform}): batch 0/1/2, Action summaries, and quote evidence after both interruptions.`);
} finally {
  rmSync(work, {recursive: true, force: true});
}
