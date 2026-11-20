"""Create supported and deliberately inconclusive page-geometry controls."""
import argparse
from pathlib import Path

from pypdf import PdfWriter
from pypdf.generic import (
    ArrayObject, DecodedStreamObject, DictionaryObject, NameObject, NumberObject,
)

FIXTURES = Path(__file__).resolve().parent / "fixtures"
FIXED = "pdfkit-0.18.0-300.pdf"


def name(value):
    return NameObject("/" + value)


def array(values):
    return ArrayObject([NumberObject(v) for v in values])


def dictionary(**items):
    return DictionaryObject({name(key): value for key, value in items.items()})


def stream(writer, content):
    obj = DecodedStreamObject()
    obj.set_data(content)
    return writer._add_object(obj)


def variant(source, output, transform):
    writer = PdfWriter(clone_from=str(FIXTURES / source))
    transform(writer, writer.pages[0])
    writer.write(FIXTURES / (output + ".pdf"))


def form(writer, content, resources=None, matrix=None):
    ref = stream(writer, content)
    obj = ref.get_object()
    obj.update(dictionary(Type=name("XObject"), Subtype=name("Form"),
                          FormType=NumberObject(1), BBox=array([0, 0, 612, 792])))
    if resources is not None:
        obj[name("Resources")] = resources
    if matrix is not None:
        obj[name("Matrix")] = array(matrix)
    return ref


def nest(writer, page, *, stem="Leaf", resources="explicit"):
    original = page.raw_get("/Resources")
    content = page.get_contents().get_data()
    form_resources = (original if resources == "explicit" else
                      DictionaryObject() if resources == "empty" else None)
    inner = form(writer, content, form_resources)
    inner_call = f"/{stem} Do\n".encode("ascii")
    outer = form(writer, inner_call, dictionary(XObject=dictionary(**{stem: inner})),
                 matrix=[1, 0, 0, 1, -8, -12])
    page_resources = dictionary(XObject=dictionary(Outer=outer))
    if resources != "explicit":
        page_resources[name("Font")] = original.get_object().raw_get("/Font")
    page[name("Resources")] = page_resources
    page[name("Contents")] = stream(writer, b"q 1 0 0 1 8 12 cm /Outer Do Q\n")


def recursing_form(writer, page):
    loop = form(writer, b"/Loop Do\n")
    loop.get_object()[name("Resources")] = dictionary(XObject=dictionary(Loop=loop))
    page[name("Resources")] = dictionary(XObject=dictionary(Loop=loop))
    page[name("Contents")] = stream(writer, b"/Loop Do\n")


def forms():
    variant(FIXED, "nested-form", nest)
    variant("wrong-unicode.pdf", "nested-form-wrong",
            lambda w, p: nest(w, p, stem="ChangedLeaf"))
    variant(FIXED, "nested-form-page-resources",
            lambda w, p: nest(w, p, resources="page"))
    variant(FIXED, "nested-form-missing-resource",
            lambda w, p: nest(w, p, resources="empty"))
    variant(FIXED, "recursive-form", recursing_form)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("stage", nargs="?", choices=["forms", "all"], default="all")
    args = parser.parse_args()
    if args.stage in ("forms", "all"):
        forms()
    print(f"Generated geometry fixtures ({args.stage}).")


if __name__ == "__main__":
    main()
