# Third-party components

- [pdflite 0.4.2](https://mooncakes.io/docs/moonbitlang/pdflite@0.4.2) supplies PDF object, page, and primitive parsing. Copyright its authors. Apache-2.0.
- [moonbit-community/flate 0.10.0](https://mooncakes.io/docs/moonbit-community/flate@0.10.0) supplies streaming zlib decoding. Copyright its authors. Apache-2.0.
- The compiled JavaScript includes portions of the [MoonBit core library](https://github.com/moonbitlang/core). Copyright International Digital Economy Academy and contributors. Apache-2.0.
- MoonBit dependency resolution also uses the locked [moonbitlang/x](https://github.com/moonbitlang/x) and [moonbitlang/async](https://github.com/moonbitlang/async) modules. Apache-2.0.
- [PDFKit 0.17.2 and 0.18.0](verification/fixtures/generator.json) (MIT) generate the original export fixtures. [pypdf 6.21.4](https://github.com/py-pdf/pypdf/blob/6.21.4/LICENSE) (BSD-3-Clause), [pypdfium2 5.13.0](https://pypi.org/project/pypdfium2/5.13.0/) and [Pillow 13.0.0](https://pypi.org/project/pillow/13.0.0/) (MIT-CMU) are independent verification tools installed from `verification/requirements.txt`. The pypdfium2 wheel carries the corresponding PDFium and third-party notices.
- [Apache PDFBox 3.0.4](https://pdfbox.apache.org/) (Apache-2.0) generates the second export comparison in `verification/pdfbox`. The release includes the generated fixtures and reproduction source.
- [QPDF 12.4.1](https://github.com/qpdf/qpdf/tree/v12.4.1) ([Apache-2.0 license](https://github.com/qpdf/qpdf/blob/v12.4.1/LICENSE.txt)) generates the compressed cross-reference fixtures. The release includes the [sample provenance and hashes](verification/fixtures/qpdf.json) and the regeneration script. QPDF is used when regenerating those samples.
- The sample PDFs embed [Liberation Sans Regular](https://github.com/liberationfonts/liberation-fonts), distributed under SIL Open Font License 1.1. The font and its license are under verification/assets.
- The synthetic quote PDFs embed a subset of [LXGW WenKai Regular 1.510](https://github.com/lxgw/LxgwWenKai/releases/tag/v1.510). The [SIL OFL 1.1 license](verification/assets/OFL-LXGW-WenKai.txt) and [provenance](verification/fixtures/quote.json) accompany the PDFs.

The Apache License 2.0 text is included in LICENSE-APACHE-2.0. The original dependency source archives can be fetched using the coordinates and hashes in scripts/mooncakes-lock.json.
