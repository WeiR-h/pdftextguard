"""Install the release matching the composite action's own manifest."""

import os
from pathlib import Path
import re
from tempfile import mkdtemp

from fetch_release import fetch


def main():
    manifest = Path(__file__).resolve().parents[1] / "moon.mod"
    version = re.search(r'^version = "(0\.0\.\d+)"$', manifest.read_text(encoding="utf-8"), re.M)
    if version is None:
        raise ValueError("Composite action requires a v0.0.x module version")
    tag = f"v{version[1]}"
    destination = Path(mkdtemp(prefix="pdftextguard-", dir=os.environ["RUNNER_TEMP"])) / "release"
    fetch(tag, destination)
    with Path(os.environ["GITHUB_OUTPUT"]).open("a", encoding="utf-8") as outputs:
        outputs.write(f"bundle={destination / f'PDFTextGuard-{tag}'}\n")


if __name__ == "__main__":
    main()
