from __future__ import annotations
import argparse
import json
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MOD_DIR = ROOT / "mod" / "factorio_autonomous_engineer"


def main() -> None:
    parser = argparse.ArgumentParser(description="Package the Factorio mod directory as a ZIP")
    parser.add_argument("--output", type=Path,
                        default=ROOT / "dist" / "factorio_autonomous_engineer_0.1.0.zip")
    args = parser.parse_args()
    info_path = MOD_DIR / "info.json"
    if not info_path.is_file():
        raise SystemExit(f"Missing mod metadata: {info_path}")
    info = json.loads(info_path.read_text(encoding="utf-8"))
    archive_root = f"{info['name']}_{info['version']}"
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(args.output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(MOD_DIR.rglob("*")):
            if path.is_file():
                archive_name = Path(archive_root) / path.relative_to(MOD_DIR)
                archive.write(path, archive_name.as_posix())
    print(f"Packaged: {args.output}")


if __name__ == "__main__":
    main()
