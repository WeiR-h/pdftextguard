"""Verify that the installer accepts matching release versions and refuses invalid bundles."""

from hashlib import sha256
from io import BytesIO
import os
from pathlib import Path
import re
from tempfile import TemporaryDirectory
from unittest import TestCase, main
from unittest.mock import patch
from zipfile import ZipFile

import install_action
from fetch_release import fetch


class InstallActionTest(TestCase):
    def install_version(self, expected, packaged):
        with TemporaryDirectory() as work:
            home = Path(work)
            (home / "verification").mkdir()
            (home / "moon.mod").write_text(f'version = "{expected}"\n', encoding="utf-8")
            prefix = f"PDFTextGuard-v{expected}"
            archive = BytesIO()
            with ZipFile(archive, "w") as bundle:
                bundle.writestr(f'{prefix}/moon.mod', f'version = "{packaged}"\n')
            checksum = f"{sha256(archive.getvalue()).hexdigest()}  {prefix}.zip\n".encode("ascii")
            archive.seek(0)
            outputs = home / "outputs"
            outputs.touch()
            with patch.dict(os.environ, RUNNER_TEMP=work, GITHUB_OUTPUT=str(outputs)), patch.object(
                install_action, "__file__", str(home / "verification/install_action.py")
            ), patch("fetch_release.urlopen", side_effect=[BytesIO(checksum), archive]) as request:
                if packaged != expected:
                    with self.assertRaisesRegex(ValueError, "version does not match"):
                        install_action.main()
                    self.assertEqual(outputs.read_bytes(), b"")
                    self.assertEqual(list(home.rglob("release/*/moon.mod")), [])
                    return
                install_action.main()
                self.assertTrue(request.call_args_list[1].args[0].endswith(f"/v{expected}/{prefix}.zip"))
                installed = Path(outputs.read_text(encoding="utf-8").strip().removeprefix("bundle="))
                self.assertEqual(installed.name, prefix)
                self.assertEqual((installed / "moon.mod").read_text(), f'version = "{expected}"\n')

    def test_installs_pinned_patch_and_minor_versions(self):
        for version in ("0.0.13", "0.1.0"):
            with self.subTest(version=version):
                self.install_version(version, version)

    def test_manifest_version_must_match_archive_tag(self):
        self.install_version("0.1.0", "0.0.13")

    def test_invalid_tag_is_rejected_before_fetch(self):
        with patch("fetch_release.urlopen") as request:
            for tag in ("main", "v0.1", "v0.01.0", "v0.1.0-rc.1"):
                with self.subTest(tag=tag), self.assertRaisesRegex(ValueError, "stable"):
                    fetch(tag, None)
            request.assert_not_called()

    def test_checksum_failure_has_no_bundle_output(self):
        manifest = (Path(__file__).resolve().parents[1] / "moon.mod").read_text()
        version = re.search(r'^version = "([^"]+)"$', manifest, re.M)[1]
        checksum = f"{'0' * 64}  PDFTextGuard-v{version}.zip\n".encode("ascii")
        with TemporaryDirectory() as work:
            outputs = Path(work) / "outputs"
            outputs.touch()
            with patch.dict(os.environ, RUNNER_TEMP=work, GITHUB_OUTPUT=str(outputs)):
                with patch("fetch_release.urlopen", side_effect=[BytesIO(checksum), BytesIO(b"bad")]):
                    with self.assertRaisesRegex(ValueError, "does not match SHA256SUMS"):
                        install_action.main()
            self.assertEqual(outputs.read_bytes(), b"")
            self.assertEqual(list(Path(work).rglob("*.zip")), [])


if __name__ == "__main__":
    main()
