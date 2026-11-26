"""Build, verify, and package the current version with the pinned release toolchain."""

import argparse
from hashlib import sha256
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
from tempfile import TemporaryDirectory

from package_release import batch_snapshot, check_release_docs


ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / ".work"
VERIFICATION = ROOT / "verification"
MOON_VERSION = "0.1.20261104"
MOONC_VERSION = "v0.10.20+65efd5b93"
BASELINE_TAG = "v0.0.11"
BASELINE_SHA256 = "12befbf8d0e03661d29c542553acbc48c0b1b82fbb8c3b98c4bcfb3b3774fd55"


def run(*command):
    subprocess.run(command, cwd=ROOT, check=True)


def receipt(path):
    return json.loads(path.read_text(encoding="utf-8"))


def write_receipt(path, details):
    path.write_text(json.dumps(details, indent=2) + "\n", encoding="utf-8", newline="\n")


def install_baseline(offline):
    binary = ROOT / "dist" / f"pdftextguard-{BASELINE_TAG}.cjs"
    if not binary.exists():
        if offline:
            raise FileNotFoundError(f"Missing baseline binary {binary.name}; run once without --offline")
        with TemporaryDirectory(dir=WORK, prefix="release-baseline-") as work:
            release = Path(work) / "release"
            run(sys.executable, VERIFICATION / "fetch_release.py", BASELINE_TAG, release)
            shutil.copyfile(release / f"PDFTextGuard-{BASELINE_TAG}" / "dist" / binary.name, binary)
    if sha256(binary.read_bytes()).hexdigest() != BASELINE_SHA256:
        raise ValueError(f"{binary.name} does not match the published baseline")


def verify(moon, offline):
    tools = subprocess.check_output([moon, "version", "--all"], encoding="utf-8")
    if not re.search(rf"^moon {re.escape(MOON_VERSION)}\b", tools, re.M) or not re.search(
        rf"^moonc {re.escape(MOONC_VERSION)}\b", tools, re.M
    ):
        raise ValueError(f"Release requires moon {MOON_VERSION}, moonc {MOONC_VERSION}")
    version = re.search(r'^version = "([^"]+)"$', (ROOT / "moon.mod").read_text(), re.M)[1]
    tag = "v" + version
    check_release_docs(ROOT, version)
    _, batch_hashes = batch_snapshot(ROOT)
    run(sys.executable, ROOT / "scripts" / "package_release_test.py")
    build = ["pwsh", "-NoProfile", "-File", ROOT / "scripts/build.ps1", "-Moon", moon, "-Python", sys.executable, "-Test"]
    if offline:
        build.append("-Offline")
    run(*build)
    run("node", VERIFICATION / "smoke.cjs")
    run("node", VERIFICATION / "quote_demo.cjs")
    run("node", VERIFICATION / "markdown_test.cjs")
    run("node", VERIFICATION / "suite_test.cjs")
    run(sys.executable, VERIFICATION / "page_results_test.py")
    run(sys.executable, VERIFICATION / "install_action_test.py")
    run(sys.executable, VERIFICATION / "verify_reference.py")
    consumer = WORK / "moonbit-source-results.json"
    run(sys.executable, VERIFICATION / "moonbit_consumer_test.py", "--moon", moon, "--output", consumer)

    install_baseline(offline)
    if not (WORK / "benchmark" / "inputs.json").is_file():
        run(sys.executable, VERIFICATION / "benchmark_fixtures.py")
    run("node", VERIFICATION / "benchmark.cjs", BASELINE_TAG, tag)
    benchmark = receipt(WORK / "benchmark" / "comparison.json")
    if benchmark["repetitions"] != 9 or len(benchmark["workloads"]) != 2:
        raise ValueError("Expected two benchmark workloads with nine repetitions")
    for workload in benchmark["workloads"]:
        baseline, candidate = workload["measurements"]
        if candidate["median_ms"] > baseline["median_ms"] * 1.10:
            raise ValueError(f"{workload['name']} exceeded the 10% performance limit")
    write_receipt(VERIFICATION / "benchmark-results.json", benchmark)
    cli = receipt(VERIFICATION / "cli-results.json")
    if batch_snapshot(ROOT)[1] != batch_hashes:
        raise ValueError("Batch and Action files changed during verification; rerun the release checks.")
    acceptance = {
        "toolVersion": version,
        "artifactSha256": cli["artifactSha256"],
        "moonVersion": MOON_VERSION,
        "mooncVersion": MOONC_VERSION,
        "cliChecks": cli["casesPassed"],
        "moonbitTests": "passed",
        "markdownChecks": "passed",
        "pageResultsChecks": "passed",
        "batchChecks": "passed",
        "batchSourceSha256": batch_hashes,
        "checksumRejection": "passed",
        "independentPdfChecks": "passed",
        "moonbitSourceConsumerCases": receipt(consumer),
        "performanceBaseline": BASELINE_TAG,
        "performanceLimitPercent": 10,
    }
    write_receipt(VERIFICATION / "acceptance-results.json", acceptance)
    run(sys.executable, ROOT / "scripts" / "package_release.py")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--moon", type=Path, help="path to the pinned moon executable")
    parser.add_argument("--offline", action="store_true", help="use locally cached archives and baseline only")
    args = parser.parse_args()
    candidate = args.moon or shutil.which("moon") or (
        ROOT.parent / ".moonmmdb-tools/moon-current/bin/moon.exe"
    )
    verify(Path(candidate).resolve(), args.offline)
