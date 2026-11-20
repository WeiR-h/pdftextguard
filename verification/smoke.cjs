const assert = require('node:assert/strict');
const { createHash } = require('node:crypto');
const { readFileSync, writeFileSync } = require('node:fs');
const { join, resolve } = require('node:path');
const { spawnSync } = require('node:child_process');

const version = readFileSync(join(__dirname, '../moon.mod'), 'utf8')
  .match(/^version = "([^"]+)"/m)[1];
const binary = process.argv[2]
  ? resolve(process.argv[2])
  : join(__dirname, '../dist', 'pdftextguard-v' + version + '.cjs');
const input = name => join(__dirname, 'fixtures', name + '.pdf');
const fixed = input('pdfkit-0.18.0-300');

function run(...args) {
  const p = spawnSync(process.execPath, [binary, ...args], {
    encoding: 'utf8', timeout: 15_000, maxBuffer: 2 * 1024 * 1024,
  });
  if (p.error) throw p.error;
  assert.equal(p.signal, null, p.stderr);
  assert.equal(p.stderr, '');
  return p;
}

const versionResult = run('--version');
assert.equal(versionResult.status, 0);
assert.equal(versionResult.stdout.trim(), 'PDFTextGuard v' + version);

const cases = [];
function check(name, baseline, candidate, exit, extra = () => {}) {
  const stdout = run('check', baseline, candidate, '--json');
  const report = JSON.parse(stdout.stdout);
  assert.equal(stdout.status, exit, name + ': ' + stdout.stdout);
  assert.equal(report.exit_code, exit, name);
  assert.equal(report.outcome, ['pass', 'regression', 'inconclusive'][exit], name);
  assert.equal(report.coverage, exit === 2 ? 'incomplete' : 'complete', name);
  assert.equal(report.schema_version, 1);
  assert.equal(report.tool_version, version);
  extra(report);
  cases.push({name, exit, report});
}

function clean(n) {
  return report => {
    assert.equal(report.aligned_glyphs, n);
    assert.equal(report.compared_glyphs, n);
    assert.equal(report.mismatched_occurrences, 0);
    assert.equal(report.diagnostics.length, 0);
  };
}

function reason(code, message) {
  return report => {
    const issue = report.diagnostics.find(d => d.code === code);
    assert.ok(issue, JSON.stringify(report.diagnostics));
    if (message) assert.match(issue.message, message);
  };
}

check('same ready export', fixed, fixed, 0, clean(300));
check('real PDFKit #1659', fixed, input('pdfkit-0.17.2-300'), 1, report => {
  assert.equal(report.aligned_glyphs, 300);
  assert.equal(report.compared_glyphs, 0);
  assert.equal(report.mismatched_occurrences, 0);
  const [issue] = report.diagnostics;
  assert.equal(issue.code, 'cmap_syntax');
  assert.equal(issue.cmap.span.operator, 'beginbfrange');
  assert.equal(issue.cmap.declared, 1);
  assert.equal(issue.cmap.observed, 2);
  assert.equal(issue.candidate.page, 1);
  assert.equal(issue.candidate.operator, 'TJ');
  assert.ok(issue.cmap.cmap_object.number > 0);
});
check('malformed baseline is inconclusive', input('pdfkit-0.17.2-300'), fixed, 2, reason('cmap_syntax'));
check('200 independent glyphs stay below the bug threshold',
  input('pdfkit-0.18.0-200'), input('pdfkit-0.17.2-200'), 0, clean(200));
check('300 copies of A are one glyph',
  input('pdfkit-0.17.2-repeated-a'), input('pdfkit-0.17.2-repeated-a'), 0, clean(300));
check('different embedded subset and renumbered glyphs', fixed, input('subset-reordered'), 0, clean(300));
check('cross-subset Unicode change', fixed, input('wrong-unicode'), 1, report => {
  assert.equal(report.mismatched_occurrences, 1);
  assert.equal(report.compared_glyphs, 300);
  assert.equal(report.diagnostics.length, 1);
  const [issue] = report.diagnostics;
  assert.equal(issue.code, 'mapping_changed');
  assert.deepEqual(issue.baseline.unicode, ['U+0021']);
  assert.deepEqual(issue.candidate.unicode, ['U+005A']);
  assert.notEqual(issue.baseline.gid, issue.candidate.gid);
  assert.notEqual(issue.baseline.code, issue.candidate.code);
  for (const witness of [issue.baseline, issue.candidate]) {
    assert.equal(witness.page, 1);
    assert.equal(witness.operator, 'TJ');
    assert.equal(witness.rule.operator, 'bfrange');
    assert.ok(witness.rule.decoded_offset <= witness.rule.value_offset);
    assert.ok(witness.rule.value_offset < witness.rule.decoded_end);
  }
});
check('position differs', fixed, input('shifted'), 2, reason('unaligned_glyph'));
check('ambiguous overprint', input('overprint'), input('overprint'), 2, reason('ambiguous_alignment'));
check('unused code, CMap object and subset name change', fixed, input('unused-and-renamed'), 0, clean(300));
check('multiple streams and inherited page resources', fixed, input('split-inherited'), 0, clean(300));
check('PDF literal string and equivalent Tj', fixed, input('literal-tj'), 0, clean(300));
check('real CIDToGIDMap stream preserves glyph identity', fixed, input('explicit-cid-to-gid'), 0, clean(300));
check('ActualText shadows font mapping', fixed, input('marked-actualtext'), 2, reason('unsupported', /ActualText/));
check('encrypted input', fixed, input('encrypted'), 2, reason('unsupported', /encrypted/));
check('changed display rotation is inconclusive', fixed, input('rotated'), 2, reason('unaligned_page'));
check('CMap inheritance does not masquerade as regression', fixed, input('inherited-cmap'), 2, reason('cmap_unsupported'));
check('ToUnicode loss is visible for used characters', fixed, input('missing-tounicode'), 1, report => {
  assert.equal(report.mismatched_occurrences, 300);
  assert.equal(report.diagnostics[0].code, 'mapping_missing');
  assert.equal(report.diagnostics.length + report.diagnostics_omitted, 300);
});
check('baseline has no reliable mapping', input('missing-tounicode'), fixed, 2, reason('baseline_unmapped'));
check('missing input', fixed, input('does-not-exist'), 2, reason('input_error'));
check('invalid container', fixed, join(__dirname, 'fixtures/source-300.txt'), 2, reason('invalid_input'));
check('page to nested forms preserves text scope and transform', fixed, input('nested-form'), 0, clean(300));
check('legacy form inherits page resources', fixed, input('nested-form-page-resources'), 0, clean(300));
check('explicit form scope cannot fall through', fixed, input('nested-form-missing-resource'), 2, reason('invalid_input', /Font/));
check('recursive forms are inconclusive', fixed, input('recursive-form'), 2, report => {
  reason('unsupported', /recursive Form/)(report);
  assert.equal(report.diagnostics[0].stream.form_path[0].resource, '/Loop');
});
check('nested form cross-subset drift', input('nested-form'), input('nested-form-wrong'), 1, report => {
  assert.equal(report.mismatched_occurrences, 1);
  const [issue] = report.diagnostics;
  assert.equal(issue.code, 'mapping_changed');
  assert.deepEqual(issue.baseline.form_path.map(x => x.resource), ['/Outer', '/Leaf']);
  assert.deepEqual(issue.candidate.form_path.map(x => x.resource), ['/Outer', '/ChangedLeaf']);
  assert.equal(issue.candidate.content_object.number, issue.candidate.form_path[1].form_object.number);
  assert.deepEqual(issue.candidate.unicode, ['U+005A']);
});
for (const angle of [90, 180, 270]) {
  check('rotate ' + angle + ' and cropped page normalized', input('crop-rotate-' + angle),
    input('crop-flatten-' + angle), 0, clean(300));
}
check('rotation normalized Unicode regression', input('crop-rotate-90'), input('crop-flatten-90-wrong'), 1, report => {
  assert.equal(report.mismatched_occurrences, 1);
  const [issue] = report.diagnostics;
  assert.equal(issue.code, 'mapping_changed');
  assert.deepEqual(issue.candidate.unicode, ['U+005A']);
  assert.ok(Math.abs(issue.baseline.origin_x - issue.candidate.origin_x) > 100);
  assert.ok(Math.abs(issue.baseline.display_origin_x - issue.candidate.display_origin_x) < 0.01);
  assert.ok(Math.abs(issue.baseline.display_origin_y - issue.candidate.display_origin_y) < 0.01);
});
check('invalid rotation is rejected', fixed, input('invalid-rotate'), 2, reason('invalid_input', /multiple of 90/));
check('equal non-default UserUnit is supported', input('unit-scaled'), input('unit-scaled'), 0, clean(300));
check('changed UserUnit remains inconclusive across readers', fixed, input('unit-scaled'), 2, reason('unaligned_page', /UserUnit/));
check('zero UserUnit is rejected', fixed, input('invalid-unit'), 2, reason('invalid_input', /positive/));

const human = run('check', fixed, input('wrong-unicode'));
assert.equal(human.status, 1);
assert.match(human.stdout, /REGRESSION/);
assert.match(human.stdout, /U\+0021/);
assert.match(human.stdout, /U\+005A/);
const malformedCommand = run('check', '--json');
assert.equal(malformedCommand.status, 2);
assert.equal(JSON.parse(malformedCommand.stdout).diagnostics[0].side, 'command');

const result = {
  toolVersion: version,
  node: process.version,
  artifactSha256: createHash('sha256').update(readFileSync(binary)).digest('hex'),
  casesPassed: cases.length + 3,
  cases: cases.map(({name, exit, report}) => ({
    name, exit, aligned: report.aligned_glyphs, compared: report.compared_glyphs,
    mismatches: report.mismatched_occurrences, diagnostic: report.diagnostics[0] || null,
  })),
};
writeFileSync(join(__dirname, 'cli-results.json'), JSON.stringify(result, null, 2) + '\n');
console.log('PASS: ' + result.casesPassed + ' command-line checks.');
