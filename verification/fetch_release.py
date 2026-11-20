"""Install a published demonstration ZIP after checking its SHA-256."""

import argparse
import hashlib
from pathlib import Path, PurePosixPath
import re
from urllib.request import urlopen
from zipfile import ZipFile


def fetch(tag, destination):
    if not re.fullmatch(r"v0\.0\.\d+", tag):
        raise ValueError("Expected a v0.0.x release tag")
    prefix = f"PDFTextGuard-{tag}"
    filename = f"{prefix}.zip"
    url = f"https://github.com/WeiR-h/pdftextguard/releases/download/{tag}"
    destination.mkdir(parents=True, exist_ok=False)
    archive = destination / filename
    with urlopen(f"{url}/SHA256SUMS", timeout=30) as response:
        rows = [line.split() for line in response.read(4096).decode("ascii").splitlines()]
    (expected,) = [row[0] for row in rows if len(row) == 2 and row[1] == filename]
    with urlopen(f"{url}/{filename}", timeout=90) as response:
        data = response.read(16 * 1024 * 1024 + 1)
    if len(data) > 16 * 1024 * 1024 or hashlib.sha256(data).hexdigest() != expected:
        raise ValueError("Published ZIP does not match SHA256SUMS")
    archive.write_bytes(data)
    with ZipFile(archive) as package:
        if sum(info.file_size for info in package.infolist()) > 64 * 1024 * 1024:
            raise ValueError("Expanded release ZIP exceeds the size limit")
        members = package.namelist()
        for name in members:
            path = PurePosixPath(name)
            if (not path.parts or path.parts[0] != prefix or ".." in path.parts
                    or "\\" in name or ":" in name):
                raise ValueError("Unexpected ZIP path")
        package.extractall(destination)
    print(expected + "  " + filename)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("tag")
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    fetch(args.tag, args.destination)
