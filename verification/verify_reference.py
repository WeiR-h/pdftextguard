"""Verify PDF evidence independently with pypdf and PDFium."""
from hashlib import sha256
from importlib.metadata import version
from contextlib import closing
from collections import Counter
import json
from pathlib import Path
import re

from pypdf import PdfReader
from pypdf.generic import IndirectObject
import pypdfium2 as pdfium
from pypdfium2.version import PDFIUM_INFO

HERE = Path(__file__).resolve().parent
FIXTURES = HERE / "fixtures"


def digest(data):
    return sha256(data).hexdigest()


def object_ref(obj):
    return {"number": obj.idnum, "generation": obj.generation}


def real_export_facts(path):
    page = PdfReader(path, strict=True).pages[0]
    font = page["/Resources"]["/Font"]["/F2"]
    descendant = font["/DescendantFonts"][0].get_object()
    cmap_obj = font.raw_get("/ToUnicode")
    cmap = cmap_obj.get_object().get_data()
    font_program = descendant["/FontDescriptor"]["/FontFile2"].get_data()
    content = page.get_contents().get_data()
    match = re.search(rb"(?m)^(\d+) beginbfrange\r?\n(.*?)endbfrange", cmap, re.S | re.M)
    declared = int(match[1])
    actual = len(re.findall(rb"(?m)^<[\da-fA-F]{4}>\s+<[\da-fA-F]{4}>\s+\[", match[2]))
    entries = len(re.findall(rb"<[\da-fA-F\s]+>", match[2])) - 2 * actual
    # The controlled generator emits only hexadecimal TJ strings. Read the
    # actual drawn codes independently from the decompressed opcode stream.
    strings = re.findall(rb"\[<([0-9a-f]+)> 0\] TJ", content)
    codes = [int(part[i:i+4], 16) for part in strings for i in range(0, len(part), 4)]
    assert codes and all(code > 0 for code in codes)
    assert "/CIDToGIDMap" in descendant and descendant["/CIDToGIDMap"] == "/Identity"
    assert all(isinstance(ref, IndirectObject) for ref in [
        page.raw_get("/Contents"), page["/Resources"]["/Font"].raw_get("/F2"), cmap_obj,
    ])
    return {
        "painted_occurrences": len(codes),
        "distinct_painted_gids": len(set(codes)),
        "first_code": f"{codes[0]:04X}",
        "first_gid": codes[0],
        "first_tj_offset": content.index(b" TJ") + 1,
        "declared_mappings": declared,
        "actual_ranges": actual,
        "cmap_entries": entries,
        "font_program_sha256": digest(font_program),
        "cmap_object": object_ref(cmap_obj),
        "content_object": object_ref(page.raw_get("/Contents")),
        "font_object": object_ref(page["/Resources"]["/Font"].raw_get("/F2")),
    }, cmap


def pdfium_observation(path, preview=None):
    with pdfium.PdfDocument(str(path)) as doc:
        with closing(doc[0]) as page:
            with closing(page.render(scale=1.0)) as bitmap:
                rgb = bitmap.to_pil().convert("RGB")
                pixels = digest(rgb.tobytes())
                if preview:
                    rgb.save(preview)
            with closing(page.get_textpage()) as text_page:
                text = text_page.get_text_range()
    return {"rgb_sha256": pixels, "text_utf8_sha256": digest(text.encode()), "text_prefix": text[:20]}, text


def verify_report_offsets(facts, cmaps):
    report_file = HERE / "cli-results.json"
    cli = json.loads(report_file.read_text(encoding="utf-8"))
    cases = {case["name"]: case for case in cli["cases"]}

    syntax = cases["real PDFKit #1659"]["diagnostic"]
    old = "pdfkit-0.17.2-300.pdf"
    span = syntax["cmap"]["span"]
    assert syntax["cmap"]["cmap_object"] == facts[old]["cmap_object"]
    assert cmaps[old][span["decoded_offset"]:span["decoded_end"]] == b"1 beginbfrange"

    mismatch = cases["cross-subset Unicode change"]["diagnostic"]
    for side, path, target in [
        ("baseline", "pdfkit-0.18.0-300.pdf", b"<0021>"),
        ("candidate", "wrong-unicode.pdf", b"<005a>"),
    ]:
        witness = mismatch[side]
        info = facts[path]
        assert witness["cmap_object"] == info["cmap_object"]
        assert witness["font_object"] == info["font_object"]
        assert witness["content_object"] == info["content_object"]
        assert witness["operator_offset"] == info["first_tj_offset"]
        assert witness["code"] == info["first_code"] and witness["gid"] == info["first_gid"]
        rule = witness["rule"]
        cmap = cmaps[path]
        raw_rule = cmap[rule["decoded_offset"]:rule["decoded_end"]]
        assert raw_rule.startswith(b"<") and raw_rule.endswith(b"]")
        value_start = rule["value_offset"]
        assert cmap[value_start:value_start + len(target)].lower() == target, witness
    verify_form_witnesses(cases["nested form cross-subset drift"]["diagnostic"])
    return {"toolVersion": cli["toolVersion"], "artifactSha256": cli["artifactSha256"]}


def verify_form_witnesses(diagnostic):
    for side, filename, target in [
        ("baseline", "nested-form.pdf", b"<0021>"),
        ("candidate", "nested-form-wrong.pdf", b"<005a>"),
    ]:
        witness = diagnostic[side]
        page = PdfReader(FIXTURES / filename, strict=True).pages[0]
        resources = page["/Resources"]
        caller = page.raw_get("/Contents")
        for call in witness["form_path"]:
            data = caller.get_object().get_data()
            offset = call["operator_offset"]
            assert call["caller_object"] == object_ref(caller)
            assert data[offset:offset + 2] == b"Do"
            assert data[:offset].rstrip().endswith(call["resource"].encode("ascii"))
            caller = resources["/XObject"].raw_get(call["resource"])
            assert call["form_object"] == object_ref(caller)
            resources = caller.get_object()["/Resources"]
        assert witness["content_object"] == object_ref(caller)
        at = witness["operator_offset"]
        assert caller.get_object().get_data()[at:at + 2] == b"TJ"
        font = resources["/Font"][witness["font_resource"]]
        cmap = font.raw_get("/ToUnicode")
        assert witness["cmap_object"] == object_ref(cmap)
        value_at = witness["rule"]["value_offset"]
        assert cmap.get_object().get_data()[value_at:value_at + len(target)].lower() == target


def verify_form_rendering(baseline, baseline_text):
    results = {}
    for file, expected in [
        ("nested-form.pdf", baseline_text),
        ("nested-form-page-resources.pdf", baseline_text),
        ("nested-form-wrong.pdf", "Z" + baseline_text[1:]),
    ]:
        facts, text = pdfium_observation(FIXTURES / file)
        assert facts["rgb_sha256"] == baseline["rgb_sha256"]
        assert text == expected
        results[file] = facts
    return results


def verify_page_rendering(baseline):
    cases = {}
    for angle in [90, 180, 270]:
        old = f"crop-rotate-{angle}.pdf"
        new = f"crop-flatten-{angle}.pdf"
        cases[old], old_text = pdfium_observation(FIXTURES / old)
        cases[new], new_text = pdfium_observation(FIXTURES / new)
        assert cases[old]["rgb_sha256"] == cases[new]["rgb_sha256"]
        assert old_text == new_text
        if angle == 90:
            bad = "crop-flatten-90-wrong.pdf"
            cases[bad], bad_text = pdfium_observation(FIXTURES / bad)
            assert cases[bad]["rgb_sha256"] == cases[old]["rgb_sha256"]
            assert old_text.count("!") == 1 and bad_text == old_text.replace("!", "Z", 1)
    # PDFium does not apply UserUnit to its bitmap size for this fixture.
    # A cross-unit equivalence claim would therefore be reader-dependent.
    cases["unit-scaled.pdf"], _ = pdfium_observation(FIXTURES / "unit-scaled.pdf")
    assert cases["unit-scaled.pdf"]["rgb_sha256"] != baseline["rgb_sha256"]
    return cases


def verify_order_rendering(baseline, baseline_text):
    values = Counter(c for c in baseline_text if not c.isspace())
    wrong = values.copy()
    wrong["!"] -= 1
    wrong["Z"] += 1
    result = {}
    for filename, expected in [("draws-reordered.pdf", values), ("draws-reordered-wrong.pdf", wrong)]:
        facts, text = pdfium_observation(FIXTURES / filename)
        assert facts["rgb_sha256"] == baseline["rgb_sha256"]
        assert Counter(c for c in text if not c.isspace()) == expected
        result[filename] = {**facts, "same_extraction_order_as_baseline": text == baseline_text}
    return result


def verify_pdfbox():
    meta = json.loads((FIXTURES / "pdfbox.json").read_text(encoding="utf-8"))
    for name, expected in meta["fixtureSha256"].items():
        assert digest((FIXTURES / name).read_bytes()) == expected
    expected_text = "! PDFTextGuard compares exported text."
    result = {}
    for mode in ("classic", "compressed", "wrong-unicode"):
        name = f"pdfbox-{mode}.pdf"
        path = FIXTURES / name
        reader = PdfReader(path)
        assert bool(reader.xref_objStm) == (mode != "classic")
        facts, text = pdfium_observation(path)
        expected = expected_text if mode != "wrong-unicode" else "Z" + expected_text[1:]
        assert text.strip() == reader.pages[0].extract_text().strip() == expected
        result[name] = {**facts, "text": expected, "indexed_compressed_objects": len(reader.xref_objStm)}
    assert len({item["rgb_sha256"] for item in result.values()}) == 1
    cases = json.loads((HERE / "cli-results.json").read_text(encoding="utf-8"))["cases"]
    bad = next(item for item in cases if item["name"] == "PDFBox compressed save with controlled wrong mapping")
    witness = bad["diagnostic"]["candidate"]
    page = PdfReader(FIXTURES / "pdfbox-wrong-unicode.pdf").pages[witness["page"] - 1]
    font_ref = page["/Resources"]["/Font"].raw_get(witness["font_resource"])
    cmap_ref = font_ref.get_object().raw_get("/ToUnicode")
    assert (font_ref.idnum, font_ref.generation) == (witness["font_object"]["number"], witness["font_object"]["generation"])
    assert (cmap_ref.idnum, cmap_ref.generation) == (witness["cmap_object"]["number"], witness["cmap_object"]["generation"])
    data = cmap_ref.get_object().get_data()
    rule = witness["rule"]
    assert data[rule["decoded_offset"]:rule["decoded_end"]] == b"<0003> <0004> [<0020> <005A>]"
    assert data[rule["value_offset"]:rule["value_offset"] + 6] == b"<005A>"
    return {"generator": meta["generator"], "cases": result, "verified_changed_rule": rule}


def verify_qpdf(baseline, baseline_text):
    meta = json.loads((FIXTURES / "qpdf.json").read_text(encoding="utf-8"))
    for name, expected in (meta["sourceSha256"] | meta["fixtureSha256"]).items():
        assert digest((FIXTURES / name).read_bytes()) == expected
    cases = json.loads((HERE / "cli-results.json").read_text(encoding="utf-8"))["cases"]
    changed = next(case for case in cases if case["name"] == "QPDF rewrite of controlled wrong mapping")
    result = {}
    for name, source in meta["rewrittenFrom"].items():
        path = FIXTURES / name
        raw = path.read_bytes()
        offset = int(re.search(rb"startxref\s+(\d+)\s+%%EOF\s*$", raw)[1])
        xref_id = re.match(rb"(\d+) (\d+) obj\b", raw[offset:])
        reader = PdfReader(path, strict=True)
        xref = reader.get_object(IndirectObject(int(xref_id[1]), int(xref_id[2]), reader))
        assert xref["/Type"] == "/XRef" and xref["/Filter"] == "/FlateDecode"
        assert "/Prev" not in xref and "/XRefStm" not in xref and reader.xref_objStm
        widths = list(xref["/W"])
        params = xref["/DecodeParms"]
        assert params["/Predictor"] == 12 and params["/Columns"] == sum(widths)
        metrics, text = pdfium_observation(path)
        source_metrics, source_text = pdfium_observation(FIXTURES / source)
        assert metrics == source_metrics and text == source_text
        assert metrics["rgb_sha256"] == baseline["rgb_sha256"]
        expected = ("Z" + baseline_text[1:]) if name == "qpdf-wrong-unicode.pdf" else baseline_text
        assert text == expected
        original = PdfReader(FIXTURES / source, strict=True).pages[0].extract_text()
        assert reader.pages[0].extract_text() == original
        result[name] = {**metrics, "predictor": int(params["/Predictor"]),
                        "xref_field_widths": widths, "indexed_compressed_objects": len(reader.xref_objStm)}

    diagnostic = changed["diagnostic"]
    for side, name, target in [
        ("baseline", "pdfkit-0.18.0-300.pdf", b"<0021>"),
        ("candidate", "qpdf-wrong-unicode.pdf", b"<005a>"),
    ]:
        witness = diagnostic[side]
        facts, cmap = real_export_facts(FIXTURES / name)
        assert witness["page"] == 1 and witness["operator_offset"] == facts["first_tj_offset"]
        for field in ("font_object", "cmap_object", "content_object"):
            assert witness[field] == facts[field]
        rule = witness["rule"]
        start, end, at = rule["decoded_offset"], rule["decoded_end"], rule["value_offset"]
        assert start <= at < at + len(target) <= end
        assert cmap[start:end].startswith(b"<") and cmap[start:end].endswith(b"]")
        assert cmap[at:at + len(target)].lower() == target
    return {"generator": meta["generator"], "cases": result,
            "verified_changed_rule": diagnostic["candidate"]["rule"]}


def main():
    meta = json.loads((FIXTURES / "generator.json").read_text(encoding="utf-8"))
    facts, cmaps, texts = {}, {}, {}
    for case in meta["cases"]:
        name = case["file"]
        path = FIXTURES / name
        assert digest(path.read_bytes()) == case["sha256"]
        expected = case["expectedGlyphs"]
        facts[name], cmaps[name] = real_export_facts(path)
        observed, texts[name] = pdfium_observation(path)
        facts[name].update(observed, input_sha256=case["sha256"])
        assert facts[name]["distinct_painted_gids"] == expected
        assert facts[name]["first_gid"] == case["firstSubsetGid"]
        assert facts[name]["cmap_entries"] == expected + 1 == case["cmapEntries"]

    baseline = "pdfkit-0.18.0-300.pdf"
    old = "pdfkit-0.17.2-300.pdf"
    subset = "subset-reordered.pdf"
    wrong = "wrong-unicode.pdf"
    assert (facts[old]["declared_mappings"], facts[old]["actual_ranges"]) == (1, 2)
    assert (facts[baseline]["declared_mappings"], facts[baseline]["actual_ranges"]) == (2, 2)
    for control in ["pdfkit-0.17.2-200.pdf", "pdfkit-0.18.0-200.pdf", "pdfkit-0.17.2-repeated-a.pdf"]:
        assert (facts[control]["declared_mappings"], facts[control]["actual_ranges"]) == (1, 1)
    assert texts["pdfkit-0.17.2-200.pdf"] == texts["pdfkit-0.18.0-200.pdf"]
    assert texts[old] != texts[baseline]
    assert texts[subset] == texts[baseline]
    assert texts[baseline].startswith("!") and texts[wrong] == "Z" + texts[baseline][1:]
    for file in [old, subset, wrong]:
        assert facts[file]["rgb_sha256"] == facts[baseline]["rgb_sha256"]
    assert facts[subset]["font_program_sha256"] != facts[baseline]["font_program_sha256"]
    assert facts[subset]["first_gid"] == 300 and facts[baseline]["first_gid"] == 1

    checker = verify_report_offsets(facts, cmaps)
    form_results = verify_form_rendering(facts[baseline], texts[baseline])
    page_results = verify_page_rendering(facts[baseline])
    order_results = verify_order_rendering(facts[baseline], texts[baseline])
    result = {
        **checker,
        "all_assertions_passed": True,
        "pypdf": version("pypdf"),
        "pypdfium2": version("pypdfium2"),
        "pdfium": str(PDFIUM_INFO),
        "pillow": version("Pillow"),
        "notes": "Only the original 0.17.2/0.18.0 exports reproduce the upstream release bug. Reordered subsets and the altered Unicode table are controlled PDFKit exports.",
        "cases": facts,
        "form_cases": form_results,
        "page_cases": page_results,
        "order_cases": order_results,
        "pdfbox": verify_pdfbox(),
        "qpdf": verify_qpdf(facts[baseline], texts[baseline]),
    }
    (HERE / "reference-results.json").write_text(
        json.dumps(result, indent=2, ensure_ascii=False) + "\n", encoding="utf-8", newline="\n",
    )
    print("PASS: independent object/span, subset, rendered pixels, and text-extraction checks.")


if __name__ == "__main__":
    main()
