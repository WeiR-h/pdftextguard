"""Compile the standalone example and compare real PDF reports through the library."""

import argparse
from hashlib import sha256
import json
import os
from pathlib import Path
import shutil
import subprocess
from tempfile import TemporaryDirectory
import tomllib
from zipfile import ZipFile

from fetch_release import manifest_version


ROOT = Path(__file__).resolve().parents[1]
EXAMPLE = ROOT / "examples" / "moonbit-consumer"
FIXTURES = ROOT / "verification" / "fixtures"
ORIGINAL = "pdfkit-0.18.0-300.pdf"
QUOTE = "quote-classic.pdf"
CASES = (
    (ORIGINAL, "subset-reordered.pdf", 0, "pass"),
    (ORIGINAL, "pdfkit-0.17.2-300.pdf", 1, "regression"),
    (ORIGINAL, "qpdf-wrong-unicode.pdf", 1, "regression"),
    (ORIGINAL, "encrypted.pdf", 2, "inconclusive"),
    (QUOTE, "quote-compressed.pdf", 0, "pass"),
    (QUOTE, "quote-wrong-unicode.pdf", 1, "regression"),
    (QUOTE, "quote-encrypted.pdf", 2, "inconclusive"),
)


def build_example(moon, work, consumer, registry, installed=None):
    tool_home = moon.parent.parent
    env = dict(os.environ, MOON_HOME=str(tool_home))
    target = work / "build"
    command = [moon, "build", "--target", "js", "--release", "--target-dir", target]
    if registry:
        env.pop("MOON_WORK", None)
        env["MOON_HOME"] = str(work / "registry-home")
        env["MOON_REGISTRY_API"] = "1"
        shutil.copytree(tool_home / "lib", work / "registry-home" / "lib")
    else:
        pinned = ROOT / ".work" / "moon.work"
        members = tomllib.loads(pinned.read_text(encoding="utf-8"))["members"]
        paths = [(pinned.parent / path).resolve() for path in members]
        if installed is not None:
            paths = [installed if path == ROOT else path for path in paths]
            assert ROOT not in paths and installed in paths
        workspace = work / "moon.work"
        workspace.write_text(
            "members = " + json.dumps([path.as_posix() for path in [*paths, consumer]]) + "\n",
            encoding="utf-8",
        )
        env["MOON_WORK"] = str(workspace)
        command.append("--frozen")
    subprocess.run([*command, "."], cwd=consumer, env=env, check=True)
    # A registry build puts the executable at a different level than a workspace build.
    artifacts = list((target / "js/release/build").rglob("pdftextguard-consumer.js"))
    if len(artifacts) != 1:
        raise ValueError(f"Expected one MoonBit consumer executable, found {len(artifacts)}")
    return artifacts[0]


def run_report(command, expected_code):
    result = subprocess.run(command, capture_output=True, encoding="utf-8", timeout=60)
    if result.returncode != expected_code:
        raise ValueError(f"Expected exit {expected_code}, got {result.returncode}: {result.stderr}")
    return json.loads(result.stdout)


def verify(moon, registry, package=None):
    version = manifest_version((ROOT / "moon.mod").read_text(encoding="utf-8"))
    cli = ROOT / "dist" / f"pdftextguard-v{version}.cjs"
    work_root = ROOT / ".work"
    work_root.mkdir(exist_ok=True)
    cases = []
    with TemporaryDirectory(dir=work_root, prefix="moonbit-consumer-") as directory:
        work = Path(directory)
        consumer = work / "export check 工程"
        consumer.mkdir()
        for name in ("moon.mod", "moon.pkg", "main.mbt"):
            shutil.copyfile(EXAMPLE / name, consumer / name)
        installed = None
        if package is not None:
            installed = work / "packaged-module"
            with ZipFile(package) as archive:
                bundled = archive.read("moon.mod").decode("utf-8")
                if manifest_version(bundled) != version or 'name = "WeiR-h/pdftextguard"' not in bundled.splitlines():
                    raise ValueError("Expected the matching PDFTextGuard module archive")
                archive.extractall(installed)
        example = build_example(moon, work, consumer, registry, installed)
        for baseline, name, code, outcome in CASES:
            paths = [FIXTURES / baseline, FIXTURES / name]
            report = run_report(["node", example, *paths], code)
            assert (report["tool_version"], report["exit_code"], report["outcome"]) == (version, code, outcome)
            assert report == run_report(["node", cli, "check", *paths, "--json"], code), name
            cases.append({"baseline": baseline, "candidate": name, "exit_code": code, "outcome": outcome})
            print(f"MoonBit library {name}: {code} {outcome}", flush=True)
    return cases


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--moon", required=True, type=Path, help="exact path to the installed moon executable")
    source = parser.add_mutually_exclusive_group()
    source.add_argument("--registry", action="store_true", help="resolve from Mooncakes in a fresh registry home")
    source.add_argument("--package", type=Path, help="consume a local ZIP produced by moon package")
    parser.add_argument("--output", type=Path, help="write the library check results to this file")
    options = parser.parse_args()
    result = verify(options.moon.resolve(), options.registry, options.package)
    if options.package:
        result = {"package": options.package.name, "sha256": sha256(options.package.read_bytes()).hexdigest(),
                  "cases": result}
    if options.output:
        options.output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8", newline="\n")
