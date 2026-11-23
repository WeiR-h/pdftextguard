"""Check that a bad release checksum cannot produce an installed action bundle."""

from io import BytesIO
import os
from pathlib import Path
import re
from tempfile import TemporaryDirectory
from unittest import TestCase, main
from unittest.mock import patch

import install_action


class InstallActionTest(TestCase):
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
