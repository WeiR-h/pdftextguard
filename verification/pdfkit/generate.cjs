// Pinned real PDFKit exports plus controlled variations produced by PDFKit.
const { createHash } = require('node:crypto');
const { readFileSync, writeFileSync, mkdirSync } = require('node:fs');
const { join } = require('node:path');
const oldKit = require('pdfkit-bad');
const fixedKit = require('pdfkit-good');

const fontPath = join(__dirname, '../assets/LiberationSans-Regular.ttf');
const out = join(__dirname, '../fixtures');
const features = { liga: false, clig: false, kern: false };
const digest = bytes => createHash('sha256').update(bytes).digest('hex');
mkdirSync(out, { recursive: true });

function makeDocument(PDFKit) {
  const date = new Date('2026-01-01T00:00:00Z');
  const doc = new PDFKit({compress: true, info: {CreationDate: date, ModDate: date}});
  return doc.font(fontPath).fontSize(10);
}

function sourceCharacters() {
  const face = makeDocument(fixedKit)._font.font;
  const gids = new Set();
  const chars = [];
  for (let cp = 33; cp <= 0x024f && chars.length < 300; cp++) {
    const ch = String.fromCodePoint(cp);
    if (!/[\p{L}\p{N}\p{P}]/u.test(ch)) continue;
    const { id } = face.glyphForCodePoint(cp);
    if (id === 0 || gids.has(id)) continue;
    gids.add(id);
    chars.push(ch);
  }
  if (chars.length !== 300) throw new Error('Expected 300 different nonzero source glyphs');
  return chars;
}

async function exportPdf(PDFKit, name, source, options = {}) {
  const doc = makeDocument(PDFKit);
  const bytes = [];
  const done = new Promise((resolve, reject) => {
    doc.on('data', b => bytes.push(b));
    doc.on('end', () => resolve(Buffer.concat(bytes)));
    doc.on('error', reject);
  });
  const embedded = doc._font;
  if (options.reverseSubset) embedded.encode([...source].reverse().join(''), features);
  const usedGids = new Set();
  for (let i = 0; i < source.length; i += 30) {
    const row = source.slice(i, i + 30).join('');
    for (const g of embedded.font.layout(row, features).glyphs) usedGids.add(g.id);
    doc.text(row, 48 + (options.shift || 0), 48 + (i / 30) * 32, {lineBreak: false, features});
  }
  if (options.overprint) doc.text(source[0], 48, 48, {lineBreak: false, features});
  if (usedGids.has(0) || usedGids.size !== new Set(source).size) {
    throw new Error(`Unexpected shaping for ${name}: ${usedGids.size} distinct glyphs`);
  }
  const initialGid = embedded.font.glyphForCodePoint(source[0].codePointAt(0)).id;
  const subsetGid = embedded.subset.mapping[initialGid];
  if (!Number.isInteger(subsetGid)) throw new Error(`Missing subset mapping for ${name}`);
  if (options.wrongMapping) embedded.unicode[subsetGid] = [0x005a];
  const cmapEntries = embedded.unicode.length;
  if (cmapEntries !== usedGids.size + 1) throw new Error(`Unexpected CMap count for ${name}`);
  doc.end();
  const pdf = await done;
  writeFileSync(join(out, `${name}.pdf`), pdf);
  return {
    file: `${name}.pdf`, sha256: digest(pdf), expectedGlyphs: usedGids.size,
    firstSourceGid: initialGid, firstSubsetGid: subsetGid, cmapEntries,
  };
}

async function main() {
  const chars = sourceCharacters();
  const cases = [
    await exportPdf(oldKit, 'pdfkit-0.17.2-300', chars),
    await exportPdf(fixedKit, 'pdfkit-0.18.0-300', chars),
    await exportPdf(oldKit, 'pdfkit-0.17.2-200', chars.slice(0, 200)),
    await exportPdf(fixedKit, 'pdfkit-0.18.0-200', chars.slice(0, 200)),
    await exportPdf(oldKit, 'pdfkit-0.17.2-repeated-a', Array(300).fill('A')),
    await exportPdf(fixedKit, 'subset-reordered', chars, {reverseSubset: true}),
    await exportPdf(fixedKit, 'wrong-unicode', chars, {reverseSubset: true, wrongMapping: true}),
    await exportPdf(fixedKit, 'shifted', chars, {shift: 12}),
    await exportPdf(fixedKit, 'overprint', chars, {overprint: true}),
  ];
  if (cases[1].firstSubsetGid === cases[5].firstSubsetGid) throw new Error('GID was not renumbered');
  writeFileSync(join(out, 'source-300.txt'), chars.join(''));
  writeFileSync(join(out, 'generator.json'), JSON.stringify({
    pdfkit: [require('pdfkit-bad/package.json').version, require('pdfkit-good/package.json').version],
    node: process.version, fontSha256: digest(readFileSync(fontPath)),
    sourceSha256: digest(chars.join('')), cases,
  }, null, 2) + '\n');
  console.log(`Generated ${cases.length} compressed PDFKit exports.`);
}

main().catch(error => { console.error(error); process.exitCode = 1; });
