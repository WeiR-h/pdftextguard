"""Rewrite two known PDFKit inputs with QPDF 12.4.1 and derive xref controls."""

import argparse
from hashlib import sha256
import json
from pathlib import Path
import re
import subprocess
from tempfile import TemporaryDirectory
import zlib


VERSION = "12.4.1"
FLAGS = ["--deterministic-id", "--object-streams=generate"]
FIXTURES = Path(__file__).resolve().parents[1] / "fixtures"
SOURCES = {
    "qpdf-normal.pdf": "pdfkit-0.18.0-300.pdf",
    "qpdf-wrong-unicode.pdf": "wrong-unicode.pdf",
}


def controls(pdf):
    start = int(re.search(rb"startxref\s+(\d+)\s+%%EOF\s*$", pdf)[1])
    head, tail = pdf[start:].split(b"\nstream\n", 1)
    assert b"/Type /XRef" in head and b"/Predictor 12" in head
    declared = re.search(rb"/Length (\d+)", head)
    columns = re.search(rb"/Columns (\d+)", head)
    length = int(declared[1])
    stride = int(columns[1]) + 1
    rows = zlib.decompress(tail[:length])
    assert len(rows) % stride == 0 and all(row == 2 for row in rows[::stride])

    def document(metadata, payload):
        return pdf[:start] + metadata + b"\nstream\n" + payload + tail[length:]

    def repack(rows):
        payload = zlib.compress(rows)
        metadata = head[:declared.start(1)] + str(len(payload)).encode("ascii") + head[declared.end(1):]
        return document(metadata, payload)

    width = str(int(columns[1]) + 1).encode("ascii")
    return {
        "qpdf-xref-columns-control.pdf": document(
            head[:columns.start(1)] + width + head[columns.end(1):], tail[:length],
        ),
        "qpdf-xref-length-control.pdf": repack(rows[:-1]),
        "qpdf-xref-row-control.pdf": repack(b"\x01" + rows[1:]),
    }


def generate(qpdf):
    version = subprocess.check_output([qpdf, "--version"], text=True).splitlines()[0]
    if version != f"qpdf version {VERSION}":
        raise ValueError(f"Expected QPDF {VERSION}, got {version}")
    with TemporaryDirectory(prefix="qpdf-fixtures-") as temporary:
        exports = {}
        for output, source in SOURCES.items():
            target = Path(temporary) / output
            subprocess.run([qpdf, *FLAGS, FIXTURES / source, target], check=True)
            exports[output] = target.read_bytes()
    derived = controls(exports["qpdf-normal.pdf"])
    files = {**exports, **derived}
    metadata = {
        "generator": f"QPDF {VERSION}",
        "options": FLAGS,
        "rewrittenFrom": SOURCES,
        "sourceSha256": {name: sha256((FIXTURES / name).read_bytes()).hexdigest()
                         for name in SOURCES.values()},
        "controlledVariants": list(derived),
        "fixtureSha256": {name: sha256(data).hexdigest() for name, data in files.items()},
    }
    for name, data in files.items():
        (FIXTURES / name).write_bytes(data)
    (FIXTURES / "qpdf.json").write_text(
        json.dumps(metadata, indent=2) + "\n", encoding="utf-8", newline="\n",
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("qpdf", type=Path, help="path to the QPDF 12.4.1 executable")
    generate(parser.parse_args().qpdf.resolve())
