# Third-party components

- [pdflite 0.4.2](https://mooncakes.io/docs/moonbitlang/pdflite@0.4.2) supplies PDF object, page, and primitive parsing. Copyright its authors. Apache-2.0.
- [moonbit-community/flate 0.10.0](https://mooncakes.io/docs/moonbit-community/flate@0.10.0) supplies streaming zlib decoding. Copyright its authors. Apache-2.0.
- The compiled JavaScript includes portions of the [MoonBit core library](https://github.com/moonbitlang/core). Copyright International Digital Economy Academy and contributors. Apache-2.0.
- MoonBit dependency resolution also uses the locked [moonbitlang/x](https://github.com/moonbitlang/x) and [moonbitlang/async](https://github.com/moonbitlang/async) modules. Apache-2.0.
- [PDFKit](https://github.com/foliojs/pdfkit) (MIT), pypdf and PDFium are verification tools. They do not run in the shipped checker.
- [Apache PDFBox 3.0.4](https://pdfbox.apache.org/) (Apache-2.0) generates the second export comparison in `verification/pdfbox`. The release includes the generated fixtures and reproduction source.
- The sample PDFs embed [Liberation Sans Regular](https://github.com/liberationfonts/liberation-fonts), distributed under SIL Open Font License 1.1. The font and its license are under verification/assets.

The Apache License 2.0 text is included in LICENSE-APACHE-2.0. The original dependency source archives can be fetched using the coordinates and hashes in scripts/mooncakes-lock.json.
