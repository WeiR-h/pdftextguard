"""Exercise release guards in a scratch tree before building a candidate."""

from hashlib import sha256
import json
from pathlib import Path
import re
from tempfile import TemporaryDirectory
import unittest

from package_release import ROOT, batch_snapshot, check_release_docs, main


class PackageReleaseTest(unittest.TestCase):
    def setUp(self):
        work = TemporaryDirectory(prefix="pdftextguard-package-check-")
        self.addCleanup(work.cleanup)
        self.repo = Path(work.name)
        manifest = (ROOT / "moon.mod").read_bytes()
        self.version = re.search(rb'^version = "([^"]+)"$', manifest, re.M)[1].decode("ascii")
        self.tag = f"v{self.version}"
        sources, hashes = batch_snapshot(ROOT)
        docs = check_release_docs(ROOT, self.version)
        for name, content in {**docs, **sources, "moon.mod": manifest}.items():
            path = self.repo / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content)
        binary = b"Test data for the release guard."
        dist = self.repo / "dist"
        dist.mkdir()
        (dist / f"pdftextguard-{self.tag}.cjs").write_bytes(binary)
        self.archive = dist / f"PDFTextGuard-{self.tag}.zip"
        self.archive.write_bytes(b"previous verified ZIP")
        identity = {"toolVersion": self.version, "artifactSha256": sha256(binary).hexdigest()}
        for filename, additional in {
            "cli-results.json": {"casesPassed": 53},
            "reference-results.json": {"all_assertions_passed": True},
            "acceptance-results.json": {"cliChecks": 53, "batchChecks": "passed", "batchSourceSha256": hashes},
        }.items():
            (self.repo / "verification" / filename).write_text(json.dumps({**identity, **additional}), encoding="utf-8")

    def change(self, filename, before, after):
        path = self.repo / filename
        content = path.read_text(encoding="utf-8")
        self.assertIn(before, content)
        path.write_text(content.replace(before, after), encoding="utf-8")

    def assert_rejected(self, reason):
        with self.assertRaisesRegex(ValueError, reason):
            main(self.repo)
        self.assertEqual(self.archive.read_bytes(), b"previous verified ZIP")

    def test_zip_filename_must_match_tag_in_readme(self):
        self.change("README.md", f"PDFTextGuard-{self.tag}.zip", "PDFTextGuard-v0.0.0.zip")
        self.assert_rejected(r"README\.md.*incorrect release ZIP")

    def test_cli_filename_must_match_manifest_version(self):
        self.change("README.md", f"pdftextguard-{self.tag}.cjs", "pdftextguard-v0.0.0.cjs")
        self.assert_rejected(r"README\.md.*incorrect CLI filename")

    def test_action_example_must_use_current_tag(self):
        self.change("examples/pdf-export-suite.yml", self.tag, "v0.0.0")
        self.assert_rejected(r"pdf-export-suite\.yml.*must use")

    def test_batch_code_change_invalidates_old_acceptance_even_with_same_cli(self):
        path = self.repo / "verification/suite.cjs"
        path.write_bytes(path.read_bytes() + b"\n// Changed after verification.\n")
        self.assert_rejected(r"Batch and Action files differ from the acceptance receipt")


if __name__ == "__main__":
    unittest.main()
