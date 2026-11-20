"""Copy the real exports and derive explicitly labelled structure controls."""

import hashlib
import json
from pathlib import Path
import re
import sys


def install(source):
    fixtures = Path(__file__).resolve().parents[1] / "fixtures"
    inputs = {
        name: (source / name).read_bytes()
        for name in ("pdfbox-classic.pdf", "pdfbox-compressed.pdf", "pdfbox-wrong-unicode.pdf")
    }
    compressed = inputs["pdfbox-compressed.pdf"]
    start = int(re.search(rb"startxref\s+(\d+)\s+%%EOF\s*$", compressed)[1])
    prefix, rest = compressed[:start], compressed[start:]
    head, tail = rest.split(b"stream", 1)
    if b"/Type /XRef" not in head:
        raise ValueError("Compressed fixture must end with an xref stream")
    for kind, entry in (("incremental", b"/Prev 1"), ("hybrid", b"/XRefStm 1")):
        controls = head.replace(b"/Type /XRef", b"/Type /XRef\n" + entry, 1)
        inputs[f"pdfbox-{kind}-control.pdf"] = prefix + controls + b"stream" + tail
    limited = re.sub(rb"/Size \d+", b"/Size 50001", head, count=1)
    inputs["pdfbox-size-control.pdf"] = prefix + limited + b"stream" + tail
    for name, data in inputs.items():
        (fixtures / name).write_bytes(data)
    record = {
        "generator": "Apache PDFBox 3.0.4",
        "jarSha256": {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(source.glob("*.jar"))},
        "realExports": ["pdfbox-classic.pdf", "pdfbox-compressed.pdf"],
        "controlledVariants": [name for name in inputs if name not in ("pdfbox-classic.pdf", "pdfbox-compressed.pdf")],
        "fixtureSha256": {name: hashlib.sha256(data).hexdigest() for name, data in inputs.items()},
    }
    (fixtures / "pdfbox.json").write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8", newline="\n")


if __name__ == "__main__":
    install(Path(sys.argv[1]))
