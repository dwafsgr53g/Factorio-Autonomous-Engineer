from __future__ import annotations

import argparse
import json
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MOD_DIR = ROOT / "mod" / "factorio_autonomous_engineer"
TEXT_SUFFIXES = {".lua", ".json", ".md", ".txt"}


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
                data = path.read_bytes()
                # Keep the archive byte-identical to canonical Git blobs even when a
                # Windows checkout materialized CRLF endings. Git stores LF for text files.
                if path.suffix.lower() in TEXT_SUFFIXES:
                    data = data.replace(b"\r\n", b"\n")
                # Fixed entry metadata keeps the release archive byte-reproducible.
                info = zipfile.ZipInfo(archive_name.as_posix(),
                                       date_time=(2026, 1, 1, 0, 0, 0))
                info.compress_type = zipfile.ZIP_DEFLATED
                info.external_attr = 0o644 << 16
                archive.writestr(info, data)
    print(f"Packaged: {args.output}")


if __name__ == "__main__":
    main()
