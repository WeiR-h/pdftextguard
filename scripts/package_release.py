"""Locally package the verified CLI and a portable demonstration."""
from hashlib import sha256
from datetime import date
import json
from pathlib import Path
import re
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo

ROOT = Path(__file__).resolve().parent.parent


def main():
    version = re.search(r'^version = "([^"]+)"', (ROOT / "moon.mod").read_text(), re.M)[1]
    cli = f"dist/pdftextguard-v{version}.cjs"
    proof = json.loads((ROOT / "verification/cli-results.json").read_text(encoding="utf-8"))
    independent = json.loads((ROOT / "verification/reference-results.json").read_text(encoding="utf-8"))
    digest = sha256((ROOT / cli).read_bytes()).hexdigest()
    if (proof["toolVersion"] != version or proof["artifactSha256"] != digest or
            independent["toolVersion"] != version or independent["artifactSha256"] != digest or
            not independent["all_assertions_passed"]):
        raise ValueError("Build and verify the exact artifact before packaging.")
    benchmark_file = ROOT / "verification" / "benchmark-results.json"
    if benchmark_file.exists():
        benchmark = json.loads(benchmark_file.read_text(encoding="utf-8"))
        for workload in benchmark["workloads"]:
            if not any(m["version"] == f"v{version}" and m["binary_sha256"] == digest
                       for m in workload["measurements"]):
                raise ValueError("Benchmark receipt does not contain the packaged binary.")
    release_date = date.fromisoformat(re.search(
        rf"^## v{re.escape(version)} · (\d{{4}}-\d{{2}}-\d{{2}})$",
        (ROOT / "CHANGELOG.md").read_text(encoding="utf-8"), re.M,
    )[1])
    stamp = (release_date.year, release_date.month, release_date.day, 0, 0, 0)
    prefix = f"PDFTextGuard-v{version}"
    members = {
        "README.md", "CHANGELOG.md", "LICENSE", "LICENSE-APACHE-2.0", "THIRD_PARTY.md",
        "moon.mod", "moon.pkg", "cmd/pdftextguard/moon.pkg", cli, "dist/SHA256SUMS",
        "verification/requirements.txt", "verification/cli-results.json",
        "verification/reference-results.json", "verification/pdfkit/package.json",
        "verification/pdfkit/package-lock.json", "verification/pdfkit/generate.cjs",
        "verification/assets/LiberationSans-Regular.ttf", "verification/assets/LICENSE_LIBERATION",
    }
    for pattern in ("*.mbt", "*.mbti", "cmd/pdftextguard/*.mbt", "cmd/pdftextguard/*.mbti",
                    "scripts/*.py", "scripts/*.ps1",
                    "scripts/mooncakes-lock.json", "verification/*.py", "verification/*.cjs",
                    "verification/fixtures/*.pdf", "verification/fixtures/generator.json",
                    "verification/fixtures/source-300.txt", "verification/history/*.json",
                    "verification/benchmark-results.json", "PERFORMANCE.md",
                    "examples/*.yml", "verification/pdfbox/*.java", "verification/pdfbox/*.py",
                    "verification/pdfbox/*.md", "verification/fixtures/pdfbox.json"):
        members.update(path.relative_to(ROOT).as_posix() for path in ROOT.glob(pattern))
    archive = ROOT / "dist" / (prefix + ".zip")
    with ZipFile(archive, "w", compression=ZIP_DEFLATED, compresslevel=9) as zip_file:
        for name in sorted(members):
            info = ZipInfo(prefix + "/" + name, date_time=stamp)
            info.compress_type = ZIP_DEFLATED
            zip_file.writestr(info, (ROOT / name).read_bytes(), compresslevel=9)
    archive.with_suffix(".zip.sha256").write_text(
        f"{sha256(archive.read_bytes()).hexdigest()}  {archive.name}\n", encoding="ascii",
    )
    print(archive)


if __name__ == "__main__":
    main()
