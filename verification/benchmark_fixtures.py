"""Make a repeatable workload from the checked-in PDFKit exports."""
from hashlib import sha256
import json
from pathlib import Path

from pypdf import PdfReader, PdfWriter
from pypdf.generic import DecodedStreamObject, NameObject

HERE = Path(__file__).resolve().parent
FIXTURES = HERE / "fixtures"
DEST = HERE.parent / ".work" / "benchmark"
PAGES = 48


def multipage(source, output):
    reader = PdfReader(FIXTURES / source)
    page = reader.pages[0]
    content = page.get_contents().get_data()
    writer = PdfWriter()
    for i in range(PAGES):
        copy = writer.add_page(page)
        stream = DecodedStreamObject()
        stream.set_data(f"% page {i + 1}\n".encode("ascii") + content)
        copy[NameObject("/Contents")] = writer._add_object(stream.flate_encode())
    writer.write(DEST / output)
    verified = PdfReader(DEST / output, strict=True)
    content_refs = {p.raw_get("/Contents").idnum for p in verified.pages}
    font_refs = {p["/Resources"]["/Font"].raw_get("/F2").idnum for p in verified.pages}
    assert len(verified.pages) == len(content_refs) == PAGES and len(font_refs) == 1


def main():
    DEST.mkdir(parents=True, exist_ok=True)
    multipage("pdfkit-0.18.0-300.pdf", "48-baseline.pdf")
    multipage("subset-reordered.pdf", "48-candidate.pdf")
    records = []
    cases = [
        ("one-page", 1, FIXTURES / "pdfkit-0.18.0-300.pdf", FIXTURES / "subset-reordered.pdf"),
        ("48-pages-shared-font", PAGES, DEST / "48-baseline.pdf", DEST / "48-candidate.pdf"),
    ]
    for label, pages, baseline, candidate in cases:
        records.append({
            "name": label,
            "pages": pages,
            "glyph_occurrences": pages * 300,
            "baseline": baseline.relative_to(HERE.parent).as_posix(),
            "candidate": candidate.relative_to(HERE.parent).as_posix(),
            "input_sha256": [sha256(path.read_bytes()).hexdigest() for path in [baseline, candidate]],
        })
    (DEST / "inputs.json").write_text(json.dumps(records, indent=2) + "\n", encoding="utf-8")
    print(f"Prepared {len(records)} workloads. The {PAGES}-page pair has distinct content streams and one shared font per PDF.")


if __name__ == "__main__":
    main()
