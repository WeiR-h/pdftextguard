"""Locally package the verified CLI and a portable demonstration."""
from hashlib import sha256
from contextlib import ExitStack
from datetime import date
import json
from pathlib import Path
import re
from uuid import uuid4
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo

ROOT = Path(__file__).resolve().parent.parent
BATCH_FILES = (
    "action.yml",
    "verification/action_gate.cjs",
    "verification/fetch_release.py",
    "verification/gate.cjs",
    "verification/install_action.py",
    "verification/install_action_test.py",
    "verification/suite.cjs",
    "verification/suite_test.cjs",
)
ACTION_EXAMPLES = ("examples/pdf-export-gate.yml", "examples/pdf-export-suite.yml")
CONSUMER_MANIFEST = "examples/moonbit-consumer/moon.mod"
ZIP_REFERENCE = re.compile(
    r"https://github\.com/WeiR-h/pdftextguard/releases/download/"
    r"(v\d+\.\d+\.\d+)/PDFTextGuard-(v\d+\.\d+\.\d+)\.zip\b"
)


def batch_snapshot(root):
    files = {name: (root / name).read_bytes() for name in BATCH_FILES}
    return files, {name: sha256(content).hexdigest() for name, content in files.items()}


def check_release_docs(root, version):
    tag = f"v{version}"
    guides = ("README.md", "REVIEW.md")
    docs = {name: (root / name).read_bytes() for name in (*guides, *ACTION_EXAMPLES, CONSUMER_MANIFEST)}
    for name in guides:
        text = docs[name].decode("utf-8")
        archives = ZIP_REFERENCE.findall(text)
        if (tag, tag) not in archives or any(url_tag != zip_tag for url_tag, zip_tag in archives):
            raise ValueError(f"{name} has an incorrect release ZIP link for {tag}.")
        commands = re.findall(r"pdftextguard-(v\d+\.\d+\.\d+)\.cjs\b", text)
        if (name == "README.md" and not commands) or any(command != tag for command in commands):
            raise ValueError(f"{name} has an incorrect CLI filename for {tag}.")
    for name in ACTION_EXAMPLES:
        references = re.findall(
            r"""(?m)^[ \t]*(?:-[ \t]*)?uses:[ \t]*['"]?WeiR-h/pdftextguard@([^\s#'"]+)""",
            docs[name].decode("utf-8"),
        )
        if not references or any(reference != tag for reference in references):
            raise ValueError(f"{name} must use WeiR-h/pdftextguard@{tag}.")
    dependencies = re.findall(r'"WeiR-h/pdftextguard@([^"]+)"', docs[CONSUMER_MANIFEST].decode("utf-8"))
    if dependencies != [version]:
        raise ValueError(f"{CONSUMER_MANIFEST} must import WeiR-h/pdftextguard@{version}.")
    return docs


def main(root=ROOT):
    version = re.search(r'^version = "([^"]+)"', (root / "moon.mod").read_text(encoding="utf-8"), re.M)[1]
    checked_docs = check_release_docs(root, version)
    batch_files, batch_hashes = batch_snapshot(root)
    cli = f"dist/pdftextguard-v{version}.cjs"
    receipts = {
        f"verification/{name}": (root / "verification" / name).read_bytes()
        for name in ("cli-results.json", "reference-results.json", "acceptance-results.json")
    }
    proof = json.loads(receipts["verification/cli-results.json"])
    independent = json.loads(receipts["verification/reference-results.json"])
    cli_bytes = (root / cli).read_bytes()
    digest = sha256(cli_bytes).hexdigest()
    acceptance = json.loads(receipts["verification/acceptance-results.json"])
    if acceptance.get("batchSourceSha256") != batch_hashes:
        raise ValueError("Batch and Action files differ from the acceptance receipt; run scripts/verify_release.py.")
    if (proof["toolVersion"] != version or proof["artifactSha256"] != digest or
            independent["toolVersion"] != version or independent["artifactSha256"] != digest or
            not independent["all_assertions_passed"] or
            acceptance["toolVersion"] != version or acceptance["artifactSha256"] != digest or
            acceptance["cliChecks"] != proof["casesPassed"] or acceptance["batchChecks"] != "passed"):
        raise ValueError("Build and verify the exact artifact before packaging.")
    for name, expected in independent["quote"]["inputSha256"].items():
        content = (root / name).read_bytes()
        if sha256(content).hexdigest() != expected:
            raise ValueError(f"{name} differs from the independently verified quote inputs.")
        receipts[name] = content
    benchmark_file = root / "verification" / "benchmark-results.json"
    if benchmark_file.exists():
        benchmark_bytes = benchmark_file.read_bytes()
        benchmark = json.loads(benchmark_bytes)
        for workload in benchmark["workloads"]:
            if not any(m["version"] == f"v{version}" and m["binary_sha256"] == digest
                       for m in workload["measurements"]):
                raise ValueError("Benchmark receipt does not contain the packaged binary.")
        receipts["verification/benchmark-results.json"] = benchmark_bytes
    release_date = date.fromisoformat(re.search(
        rf"^## v{re.escape(version)} · (\d{{4}}-\d{{2}}-\d{{2}})$",
        (root / "CHANGELOG.md").read_text(encoding="utf-8"), re.M,
    )[1])
    stamp = (release_date.year, release_date.month, release_date.day, 0, 0, 0)
    prefix = f"PDFTextGuard-v{version}"
    members = {
        "README.md", "CHANGELOG.md", "LICENSE", "LICENSE-APACHE-2.0", "THIRD_PARTY.md",
        "moon.mod", "moon.pkg", "cmd/pdftextguard/moon.pkg", "action.yml", cli, "dist/SHA256SUMS",
        "verification/requirements.txt", "verification/cli-results.json",
        "verification/reference-results.json", "verification/pdfkit/package.json",
        "verification/acceptance-results.json",
        "verification/pdfkit/package-lock.json", "verification/pdfkit/generate.cjs",
        "verification/assets/LiberationSans-Regular.ttf", "verification/assets/LICENSE_LIBERATION",
    }
    for pattern in ("*.mbt", "*.mbti", "cmd/pdftextguard/*.mbt", "cmd/pdftextguard/*.mbti",
                    "scripts/*.py", "scripts/*.ps1",
                    "scripts/mooncakes-lock.json", "verification/*.py", "verification/*.cjs",
                    "verification/fixtures/*.pdf", "verification/fixtures/generator.json",
                    "verification/fixtures/source-300.txt", "verification/history/*.json",
                    "verification/benchmark-results.json", "PERFORMANCE.md",
                    "examples/*.yml", "examples/*.json", "examples/moonbit-consumer/README.md",
                    "examples/moonbit-consumer/moon.mod", "examples/moonbit-consumer/moon.pkg",
                    "examples/moonbit-consumer/main.mbt", "verification/pdfbox/*.java", "verification/pdfbox/*.py",
                    "verification/pdfbox/*.md", "verification/fixtures/pdfbox.json",
                    "verification/qpdf/*.py", "verification/fixtures/qpdf.json",
                    "REVIEW.md", f"dist/PDFTextGuard-v{version}-demo.mp4"):
        members.update(path.relative_to(root).as_posix() for path in root.glob(pattern))
    verified_files = {**checked_docs, **batch_files, **receipts, cli: cli_bytes}
    members.update(verified_files)
    archive = root / "dist" / (prefix + ".zip")
    checksum = archive.with_suffix(".zip.sha256")
    # Stage beside the outputs so they inherit the dist directory's access rules.
    nonce = uuid4().hex
    pending = archive.with_name(f".{archive.name}.{nonce}.tmp")
    pending_checksum = checksum.with_name(f".{checksum.name}.{nonce}.tmp")
    with ExitStack() as cleanup:
        with ZipFile(pending, "x", compression=ZIP_DEFLATED, compresslevel=9) as zip_file:
            cleanup.callback(pending.unlink, missing_ok=True)
            for name in sorted(members):
                info = ZipInfo(prefix + "/" + name, date_time=stamp)
                info.compress_type = ZIP_DEFLATED
                content = verified_files[name] if name in verified_files else (root / name).read_bytes()
                zip_file.writestr(info, content, compresslevel=9)
        with pending_checksum.open("x", encoding="ascii") as output:
            cleanup.callback(pending_checksum.unlink, missing_ok=True)
            output.write(f"{sha256(pending.read_bytes()).hexdigest()}  {archive.name}\n")
        pending.replace(archive)
        pending_checksum.replace(checksum)
    print(archive)


if __name__ == "__main__":
    main()
