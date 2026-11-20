const assert = require('node:assert/strict');
const { join } = require('node:path');
const { check } = require('./gate.cjs');

const fixture = name => join(__dirname, 'fixtures', name + '.pdf');
const baseline = fixture('pdfkit-0.18.0-300');
const cases = [
  ['Normal font subset change', 'subset-reordered', 0],
  ['PDFKit #1659', 'pdfkit-0.17.2-300', 1],
  ['Encrypted input', 'encrypted', 2],
];
for (const [label, file, expected] of cases) {
  const report = check(baseline, fixture(file));
  assert.equal(report.exit_code, expected);
  console.log(label + ' → ' + report.exit_code + ' ' + report.outcome);
  if (expected === 0) assert.equal(report.compared_glyphs, 300);
  if (expected === 1) {
    const issue = report.diagnostics.find(item => item.code === 'cmap_syntax');
    assert.equal(issue.candidate.page, 1);
    assert.equal(issue.cmap.span.operator, 'beginbfrange');
    const { cmap_object: object, span, declared, observed } = issue.cmap;
    assert.deepEqual([declared, observed], [1, 2]);
    console.log('  Page 1, ToUnicode ' + object.number + ' ' + object.generation +
      ' R, ' + span.operator + ' bytes ' + span.decoded_offset + '–' + span.decoded_end +
      ', declared ' + declared + ', observed ' + observed);
  }
  if (expected === 2) console.log('  ' + report.diagnostics[0].message);
}
