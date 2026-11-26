"""Check page results with mixed coverage and more findings than the detail limit."""

import json
from pathlib import Path
import subprocess
from tempfile import TemporaryDirectory

from pypdf import PdfReader, PdfWriter

from fetch_release import manifest_version


ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "verification" / "fixtures"
FIXED = "pdfkit-0.18.0-300.pdf"


def write_pages(target, names):
    writer = PdfWriter()
    for name in names:
        if name is None:
            writer.add_blank_page(width=612, height=792)
        else:
            writer.add_page(PdfReader(FIXTURES / name).pages[0])
    writer.write(target)


def check(baseline, candidate, *options):
    version = manifest_version((ROOT / "moon.mod").read_text(encoding="utf-8"))
    cli = ROOT / "dist" / f"pdftextguard-v{version}.cjs"
    result = subprocess.run(
        ["node", cli, "check", baseline, candidate, "--json", *options],
        capture_output=True, encoding="utf-8", timeout=60,
    )
    report = json.loads(result.stdout)
    assert report["exit_code"] == result.returncode and report["schema_version"] == 1
    return report


def main():
    with TemporaryDirectory(prefix="pdftextguard-pages-") as work:
        folder = Path(work)
        baseline = folder / "baseline.pdf"
        candidate = folder / "candidate.pdf"
        markdown = folder / "report.md"
        write_pages(baseline, [FIXED, None, FIXED, FIXED, FIXED])
        write_pages(candidate, [FIXED, None, "missing-tounicode.pdf", "wrong-unicode.pdf", "draws-reordered.pdf"])
        report = check(baseline, candidate, "--markdown-report", markdown)
        pages = report["page_results"]
        assert report["exit_code"] == 2
        assert len(report["diagnostics"]) == 80 and report["diagnostics_omitted"] > 0
        assert [page["page"] for page in pages] == [1, 2, 3, 4, 5]
        assert [page["outcome"] for page in pages] == ["pass", "no_text", "regression", "regression", "inconclusive"]
        assert [page["compared_glyphs"] for page in pages] == [300, 0, 300, 300, 0]
        assert [page["mismatched_occurrences"] for page in pages] == [0, 0, 300, 1, 0]
        assert [page["diagnostic_codes"] for page in pages[2:]] == [
            ["mapping_missing"], ["mapping_changed"], ["unaligned_glyph"],
        ]
        for field in ("aligned_glyphs", "compared_glyphs", "mismatched_occurrences"):
            assert sum(page[field] for page in pages) == report[field]
        text = markdown.read_text(encoding="utf-8")
        assert "| 2 | no_text | 0 | 0 | 0 |" in text and "| 5 | inconclusive |" in text
        write_pages(baseline, [None])
        report = check(baseline, baseline)
        assert report["exit_code"] == 2 and report["page_results"][0]["outcome"] == "no_text"
    baseline = FIXTURES / FIXED
    malformed = FIXTURES / "pdfkit-0.17.2-300.pdf"
    assert check(baseline, malformed)["page_results"][0]["outcome"] == "regression"
    assert check(malformed, baseline)["page_results"][0]["outcome"] == "inconclusive"
    report = check(baseline, FIXTURES / "encrypted.pdf")
    assert report["exit_code"] == 2 and report["page_results"] == []
    print("PASS: mixed page results, empty document, CMap sides, and reasons after the detail limit.", flush=True)


if __name__ == "__main__":
    main()
