"""Install the release matching the composite action's own manifest."""

import os
from pathlib import Path
from tempfile import mkdtemp

from fetch_release import fetch, manifest_version


def main():
    manifest = Path(__file__).resolve().parents[1] / "moon.mod"
    tag = f"v{manifest_version(manifest.read_text(encoding='utf-8'))}"
    destination = Path(mkdtemp(prefix="pdftextguard-", dir=os.environ["RUNNER_TEMP"])) / "release"
    fetch(tag, destination)
    with Path(os.environ["GITHUB_OUTPUT"]).open("a", encoding="utf-8") as outputs:
        outputs.write(f"bundle={destination / f'PDFTextGuard-{tag}'}\n")


if __name__ == "__main__":
    main()
