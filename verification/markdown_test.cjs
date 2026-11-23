const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const { createHash } = require('node:crypto');
const { mkdtempSync, readFileSync, rmSync, existsSync } = require('node:fs');
const { tmpdir } = require('node:os');
const { basename, join } = require('node:path');
const { check } = require('./gate.cjs');

const fixtures = join(__dirname, 'fixtures');
const fixed = join(fixtures, 'pdfkit-0.18.0-300.pdf');
const classic = join(fixtures, 'pdfbox-classic.pdf');
const work = mkdtempSync(join(tmpdir(), 'pdftextguard-markdown-'));
const hash = path => createHash('sha256').update(readFileSync(path)).digest('hex');
const version = check(fixed, fixed).tool_version;
const binary = join(__dirname, '../dist', 'pdftextguard-v' + version + '.cjs');

function verifySidecar(baseline, candidate, code, expectedEvidence) {
  const markdown = join(work, '报告 ' + basename(candidate) + '.md');
  const jsonOnly = check(baseline, candidate);
  const report = check(baseline, candidate, markdown);
  assert.deepEqual(report, jsonOnly);
  assert.equal(report.exit_code, code); // gate.cjs also matches it to the process status
  const text = readFileSync(markdown, 'utf8');
  assert.ok(text.includes(`**${report.outcome}** (exit ${code})`));
  assert.ok(text.includes(`| Baseline | ${report.baseline_pages} | \`${hash(baseline)}\` |`));
  const candidateDigest = existsSync(candidate) ? hash(candidate) : 'unavailable';
  assert.ok(text.includes(`| Candidate | ${report.candidate_pages} | \`${candidateDigest}\` |`));
  expectedEvidence(report, text);
  return [markdown, text];
}

function verifySpan(text, cmap, span) {
  assert.ok(text.includes(`ToUnicode \`${cmap.number} ${cmap.generation} R\``));
  assert.ok(text.includes(`${span.operator} bytes [${span.decoded_offset}, ${span.decoded_end})`));
}

try {
  verifySidecar(fixed, join(fixtures, 'subset-reordered.pdf'), 0, (_, text) => {
    assert.ok(!text.includes('## Diagnostics'));
  });
  const oldPdfKit = join(fixtures, 'pdfkit-0.17.2-300.pdf');
  verifySidecar(fixed, oldPdfKit, 1, (report, text) => {
    const { cmap } = report.diagnostics[0];
    verifySpan(text, cmap.cmap_object, cmap.span);
    assert.ok(text.includes('declared 1, observed 2'));
  });
  const wrong = join(fixtures, 'pdfbox-wrong-unicode.pdf');
  const [existing, contents] = verifySidecar(classic, wrong, 1, (report, text) => {
    const issue = report.diagnostics[0];
    for (const side of ['baseline', 'candidate']) {
      const site = issue[side];
      verifySpan(text, site.cmap_object, site.rule);
      assert.ok(text.includes(`font \`${site.font_object.number} ${site.font_object.generation} R\``));
      assert.ok(text.includes(`Unicode \`${JSON.stringify(site.unicode)}\``));
    }
    assert.ok(text.includes('U+0021') && text.includes('U+005A'));
  });
  verifySidecar(fixed, join(fixtures, 'encrypted.pdf'), 2, (_, text) => {
    assert.match(text, /encrypted/i);
  });
  verifySidecar(fixed, join(work, 'missing.pdf'), 2, (_, text) => {
    assert.match(text, /input_error/);
  });
  for (const path of [existing, work, fixed, join(work, 'missing-dir', 'new.md')]) {
    const report = check(classic, wrong, path);
    assert.equal(report.exit_code, 2);
    assert.equal(report.diagnostics[0].side, 'report');
    assert.match(report.diagnostics[0].message, /cannot write Markdown report/);
  }
  assert.equal(readFileSync(existing, 'utf8'), contents);
  const unused = join(work, 'unused.md');
  for (const flags of [[], ['--align-by-position'], [unused, '--markdown-report', unused]]) {
    const result = spawnSync(process.execPath, [binary, 'check', fixed, wrong, '--json',
      '--markdown-report', ...flags], { encoding: 'utf8', timeout: 15_000 });
    assert.equal(result.status, 2);
    assert.equal(JSON.parse(result.stdout).diagnostics[0].side, 'command');
    assert.ok(!existsSync(unused));
  }
  console.log('PASS: Markdown evidence, input hashes, status parity, and exclusive writes.');
} finally {
  rmSync(work, { recursive: true });
}
