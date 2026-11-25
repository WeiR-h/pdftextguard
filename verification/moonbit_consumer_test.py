"""Compile the standalone example and compare real PDF reports through the library."""

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
from tempfile import TemporaryDirectory
import tomllib


ROOT = Path(__file__).resolve().parents[1]
EXAMPLE = ROOT / "examples" / "moonbit-consumer"
FIXTURES = ROOT / "verification" / "fixtures"
CASES = {
    "subset-reordered.pdf": (0, "pass"),
    "pdfkit-0.17.2-300.pdf": (1, "regression"),
    "qpdf-wrong-unicode.pdf": (1, "regression"),
    "encrypted.pdf": (2, "inconclusive"),
}


def build_example(moon, work, consumer, registry):
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
        paths = [(pinned.parent / path).resolve().as_posix() for path in members]
        workspace = work / "moon.work"
        workspace.write_text(
            "members = " + json.dumps([*paths, consumer.as_posix()]) + "\n",
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


def verify(moon, registry):
    version = re.search(r'^version = "([^"]+)"$', (ROOT / "moon.mod").read_text(), re.M)[1]
    baseline = FIXTURES / "pdfkit-0.18.0-300.pdf"
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
        example = build_example(moon, work, consumer, registry)
        for name, (code, outcome) in CASES.items():
            paths = [baseline, FIXTURES / name]
            report = run_report(["node", example, *paths], code)
            assert (report["tool_version"], report["exit_code"], report["outcome"]) == (version, code, outcome)
            assert report == run_report(["node", cli, "check", *paths, "--json"], code), name
            cases.append({"candidate": name, "exit_code": code, "outcome": outcome})
            print(f"MoonBit library {name}: {code} {outcome}", flush=True)
    return cases


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--moon", required=True, type=Path, help="exact path to the installed moon executable")
    parser.add_argument("--registry", action="store_true", help="resolve from Mooncakes in a fresh registry home")
    parser.add_argument("--output", type=Path, help="write the library check results to this file")
    options = parser.parse_args()
    cases = verify(options.moon.resolve(), options.registry)
    if options.output:
        options.output.write_text(json.dumps(cases, indent=2) + "\n", encoding="utf-8", newline="\n")
