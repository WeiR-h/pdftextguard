const assert = require('node:assert/strict');
const { join } = require('node:path');
const { check } = require('./gate.cjs');

const fixture = filename => join(__dirname, 'fixtures', filename);
const baseline = fixture('quote-classic.pdf');
for (const [name, filename, expected] of [
  ['正常压缩导出', 'quote-compressed.pdf', 0],
  ['第二页受控错映射', 'quote-wrong-unicode.pdf', 1],
  ['加密对照', 'quote-encrypted.pdf', 2],
]) {
  const report = check(baseline, fixture(filename));
  assert.equal(report.exit_code, expected);
  console.log(`${expected} ${report.outcome} · ${name}`);
  if (expected === 0) console.log(`  两页均通过，已比对 ${report.compared_glyphs} 次字形绘制。`);
  if (expected === 1) {
    const [issue] = report.diagnostics;
    assert.equal(report.mismatched_occurrences, 1);
    assert.equal(issue.page, 2);
    assert.deepEqual(issue.baseline.unicode, ['U+5408']);
    assert.deepEqual(issue.candidate.unicode, ['U+53F0']);
    const { font_object: font, cmap_object: cmap, rule } = issue.candidate;
    console.log(`  “合计”提取成“台计”。第 2 页，字体 ${font.number} ${font.generation} R，ToUnicode ${cmap.number} ${cmap.generation} R。`);
    console.log(`  解压后规则字节 [${rule.decoded_offset}, ${rule.decoded_end})。`);
  }
  if (expected === 2) console.log('  ' + report.diagnostics[0].message);
}
