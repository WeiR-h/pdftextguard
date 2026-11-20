"""Prepare checksum-pinned MoonBit dependencies in the local build directory."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from hashlib import sha256
import json
from pathlib import Path, PurePosixPath
import stat
from urllib.request import urlopen
from zipfile import ZipFile

PROJECT = Path(__file__).resolve().parent.parent
WORK = PROJECT / ".work"
LOCK = PROJECT / "scripts" / "mooncakes-lock.json"
MAX_DOWNLOAD = 32 * 1024 * 1024


def install(dependency, offline):
    name = dependency["name"]
    version = dependency["version"]
    package = name.split("/")[1]
    archive = WORK / f"{package}-{version}.zip"
    target = WORK / "vendor" / (name + "-" + version)
    if not archive.exists():
        if offline:
            raise FileNotFoundError(f"offline archive missing: {archive.name}")
        url = f"https://download.mooncakes.io/user/{name}/{version}.zip"
        with urlopen(url, timeout=30) as response:
            data = response.read(MAX_DOWNLOAD + 1)
        if len(data) > MAX_DOWNLOAD:
            raise ValueError(f"Mooncakes archive too large: {name}")
        if sha256(data).hexdigest() != dependency["sha256"]:
            raise ValueError(f"published archive hash differs from lock: {name}")
        archive.write_bytes(data)
    with archive.open("rb") as source:
        if sha256(source.read(MAX_DOWNLOAD + 1)).hexdigest() != dependency["sha256"]:
            raise ValueError(f"cached archive hash differs from lock: {archive.name}")
    with ZipFile(archive) as source:
        entries = source.infolist()
        if sum(entry.file_size for entry in entries) > 128 * 1024 * 1024:
            raise ValueError(f"unpacked archive too large: {name}")
        for entry in entries:
            path = PurePosixPath(entry.filename)
            if (path.is_absolute() or ".." in path.parts or ":" in entry.filename or
                    "\\" in entry.filename or stat.S_ISLNK(entry.external_attr >> 16)):
                raise ValueError(f"unsafe archive member in {archive.name}")
        source.extractall(target)
    return "./" + target.relative_to(WORK).as_posix()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--offline", action="store_true", help="use the local zip cache only")
    opts = parser.parse_args()
    dependencies = json.loads(LOCK.read_text(encoding="utf-8"))
    WORK.mkdir(exist_ok=True)
    with ThreadPoolExecutor(max_workers=4) as pool:
        members = ["..", *pool.map(lambda dep: install(dep, opts.offline), dependencies)]
    workspace = "members = " + json.dumps(members, indent=2) + "\n"
    (WORK / "moon.work").write_text(workspace, encoding="utf-8")
    print("Prepared checksum-pinned Mooncakes sources and .work/moon.work")


if __name__ == "__main__":
    main()
