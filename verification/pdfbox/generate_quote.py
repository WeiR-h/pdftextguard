"""Regenerate the shipped quote fixtures with the pinned PDFBox and font inputs."""

import argparse
from hashlib import sha256
import json
import os
from pathlib import Path
import subprocess
from tempfile import TemporaryDirectory


SOURCE = Path(__file__).resolve().with_name("QuoteFixture.java")
FIXTURES = SOURCE.parents[1] / "fixtures"


def require_sha256(path, expected):
    if sha256(path.read_bytes()).hexdigest() != expected:
        raise ValueError(f"Unexpected SHA-256 for {path.name}")


def verify_regeneration(jar_directory, font):
    pdfbox = json.loads((FIXTURES / "pdfbox.json").read_text(encoding="utf-8"))
    quote = json.loads((FIXTURES / "quote.json").read_text(encoding="utf-8"))
    require_sha256(font, quote["font"]["sha256"])
    require_sha256(SOURCE, quote["sourceSha256"])
    jars = [jar_directory / name for name in pdfbox["jarSha256"]]
    for jar in jars:
        require_sha256(jar, pdfbox["jarSha256"][jar.name])
    with TemporaryDirectory(prefix="pdftextguard-quote-") as work:
        subprocess.run(
            ["java", "-Dfile.encoding=UTF-8", "--class-path", os.pathsep.join(map(str, jars)), SOURCE, work, font],
            check=True, timeout=120,
        )
        for name, expected in quote["fixtureSha256"].items():
            require_sha256(Path(work) / name, expected)
            require_sha256(FIXTURES / name, expected)
    print("All four quote PDFs regenerated with identical bytes.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("jar_directory", type=Path)
    parser.add_argument("font", type=Path)
    args = parser.parse_args()
    verify_regeneration(args.jar_directory.resolve(), args.font.resolve())
