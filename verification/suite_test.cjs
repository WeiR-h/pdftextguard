const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync,
  rmSync, writeFileSync } = require('node:fs');
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
    RUNNER_TEMP: work, GITHUB_OUTPUT: outputs, ...inputs,
  });
}

function readOutputs(file) {
  return Object.fromEntries(readFileSync(file, 'utf8').trimEnd().split('\n').map(line => {
    const index = line.indexOf('=');
    return [line.slice(0, index), line.slice(index + 1)];
  }));
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
  console.log(`PASS (${process.platform}): batch 0/1/2, every report, Unicode paths, validation and Action outputs.`);
} finally {
  rmSync(work, {recursive: true, force: true});
}
