"""Load stage and planet guidance as plain text; never execute skill content."""
from __future__ import annotations

from pathlib import Path
from typing import Any


def _skill_roots() -> tuple[Path, Path]:
    package_root = Path(__file__).resolve().parent / "skills"
    repository_root = Path(__file__).resolve().parents[2] / "skills"
    return package_root, repository_root


def _read_skill(relative_path: str) -> str | None:
    for root in _skill_roots():
        try:
            return (root / relative_path).read_text(encoding="utf-8")
        except FileNotFoundError:
            continue
    return None


def load_skill_pack(profile: dict[str, Any]) -> list[dict[str, str]]:
    """Resolve code-generated planet/stage profile into plain Markdown prompt files."""
    stage = str((profile.get("stage") or {}).get("id") or "")
    planet = str((profile.get("planet") or {}).get("name") or "")
    candidates = [
        ("core_strategy", "core_strategy.md"),
        (f"stage_{stage}", f"stages/{stage}.md"),
        (f"planet_{planet}", f"planets/planet_{planet}.md"),
    ]
    result = []
    for skill_id, relative_path in candidates:
        content = _read_skill(relative_path)
        if content:
            result.append({"id": skill_id, "content": content.strip()})
    if not result:
        result.append({
            "id": "core_strategy",
            "content": ("Use only capabilities returned by get_briefing. "
                        "Plan goals, not game micro-actions."),
        })
    return result
