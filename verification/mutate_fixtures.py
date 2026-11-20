"""Generate additional controls from the fixed PDFKit export."""
from pathlib import Path
import re
import struct

from pypdf import PdfWriter
from pypdf.generic import ArrayObject, DecodedStreamObject, NameObject, NumberObject

FIXTURES = Path(__file__).resolve().parent / "fixtures"
SOURCE = FIXTURES / "pdfkit-0.18.0-300.pdf"


def stream(writer, data):
    item = DecodedStreamObject()
    item.set_data(data)
    return writer._add_object(item)


def variant(name, modify):
    writer = PdfWriter(clone_from=str(SOURCE))
    page = writer.pages[0]
    font = page["/Resources"]["/Font"]["/F2"]
    modify(writer, page, font)
    writer.write(FIXTURES / (name + ".pdf"))


def rewrite_cmap(writer, font, data):
    font[NameObject("/ToUnicode")] = stream(writer, data)


def unused(writer, _, font):
    # Code 0000 is the subset's .notdef entry and is never shown.
    cmap = font["/ToUnicode"].get_data()
    changed = cmap.replace(b"[<0000> ", b"[<005A> ", 1)
    assert changed != cmap
    rewrite_cmap(writer, font, changed)
    for dictionary in [font, font["/DescendantFonts"][0].get_object()]:
        name = str(dictionary["/BaseFont"])
        assert "+" in name
        dictionary[NameObject("/BaseFont")] = NameObject("/ZZZZZZ+" + name.split("+", 1)[1])


def actualtext(writer, page, _):
    data = page.get_contents().get_data()
    wrapped = b"/Span << /ActualText (replacement) >> BDC\n" + data + b"\nEMC\n"
    page[NameObject("/Contents")] = stream(writer, wrapped)


def split_inherited(writer, page, _):
    data = page.get_contents().get_data()
    pivot = data.index(b" Tf\n") + len(b" Tf\n")
    page[NameObject("/Contents")] = ArrayObject([
        stream(writer, data[:pivot]),
        stream(writer, data[pivot:]),
    ])
    page["/Parent"][NameObject("/Resources")] = page.raw_get("/Resources")
    del page[NameObject("/Resources")]


def literal_string(writer, page, _):
    data = page.get_contents().get_data()

    def replacement(m):
        text_bytes = bytes.fromhex(m.group(1).decode("ascii"))
        encoded = "".join(f"\\{byte:03o}" for byte in text_bytes)
        return ("(" + encoded + ") Tj").encode("ascii")

    changed, n = re.subn(rb"\[<([0-9a-f]+)> 0\] TJ", replacement, data, count=1)
    assert n == 1
    page[NameObject("/Contents")] = stream(writer, changed)


def recoded_cids(writer, page, font):
    data = page.get_contents().get_data()

    def swap(m):
        words = [m.group(1)[i:i+4] for i in range(0, len(m.group(1)), 4)]
        swapped = [b"0002" if word == b"0001" else b"0001" if word == b"0002" else word
                   for word in words]
        return b"<" + b"".join(swapped) + b">"

    changed, n = re.subn(rb"<([0-9a-f]{4,})>", swap, data)
    assert n == 10 and changed != data
    page[NameObject("/Contents")] = stream(writer, changed)

    descendant = font["/DescendantFonts"][0].get_object()
    widths = descendant["/W"][1]
    widths[1], widths[2] = widths[2], widths[1]
    gids = list(range(301))
    gids[1], gids[2] = gids[2], gids[1]
    descendant[NameObject("/CIDToGIDMap")] = stream(writer, struct.pack(">301H", *gids))

    cmap = font["/ToUnicode"].get_data()
    match = re.search(rb"\[<0000> (<[a-f0-9]+>) (<[a-f0-9]+>) ", cmap)
    assert match
    changed = cmap[:match.start()] + b"[<0000> " + match[2] + b" " + match[1] + b" " + cmap[match.end():]
    rewrite_cmap(writer, font, changed)


def missing_cmap(_, __, font):
    del font[NameObject("/ToUnicode")]


def inherited_cmap(writer, _, font):
    cmap = font["/ToUnicode"].get_data()
    rewrite_cmap(writer, font, b"/Other-UCS usecmap\n" + cmap)


def encrypted(writer, _, __):
    writer.encrypt("", owner_password="sample-owner-only", algorithm="RC4-128")


def rotated(_, page, __):
    page[NameObject("/Rotate")] = NumberObject(90)


def main():
    for name, mutate in [
        ("unused-and-renamed", unused),
        ("marked-actualtext", actualtext),
        ("split-inherited", split_inherited),
        ("literal-tj", literal_string),
        ("explicit-cid-to-gid", recoded_cids),
        ("missing-tounicode", missing_cmap),
        ("inherited-cmap", inherited_cmap),
        ("encrypted", encrypted),
        ("rotated", rotated),
    ]:
        variant(name, mutate)
    print("Generated 9 structural and coverage controls.")


if __name__ == "__main__":
    main()
