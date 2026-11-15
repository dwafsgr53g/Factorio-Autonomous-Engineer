"""Scenario 3b: respawn must wait while home is under threat, then proceed once safe."""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "src"))

import harness as h  # noqa: E402


def main() -> int:
    h.load_scenario_save("s3b-unsafe-home.zip")
    b = h.bridge()
    h.give_kit(b)

    h.lua('local a=game.surfaces["nauvis"].find_entities_filtered{type="character"}[1]; a.die()', b)
    h.wait(lambda: h.status(b)["lifecycle"]["status"] != "alive", timeout=20, what="death")

    # Hostiles inside the home danger radius must hold the respawn back.
    guards = h.lua(
        'local out={} '
        'for i=1,4 do '
        '  local ang=i*math.pi/2 '
        '  local e=game.surfaces["nauvis"].create_entity{name="small-biter", '
        '    position={x=math.cos(ang)*20,y=math.sin(ang)*20}, force=game.forces.enemy} '
        '  out[#out+1]=e.unit_number '
        'end '
        'rcon.print(table.concat(out,","))', b)
    print("spawn guards:", guards)

    h.wait(lambda: h.status(b)["lifecycle"]["status"] in {"waiting_for_safe_spawn", "dead"},
           timeout=30, what="respawn window")
    time.sleep(6)
    life = h.status(b)["lifecycle"]
    chars = h.lua('rcon.print(#game.surfaces["nauvis"]'
                  '.find_entities_filtered{type="character"})', b)
    print("lifecycle while home unsafe:", h.pretty(life))
    print("characters alive:", chars)
    blocked_ok = life["status"] in {"waiting_for_safe_spawn", "dead"} and chars == "0"

    h.wait(lambda: h.status(b)["lifecycle"]["status"] == "waiting_for_safe_spawn", timeout=30,
           what="explicit blocked status")
    blocked_reason = h.status(b)["lifecycle"].get("spawn_block_reason")
    print("spawn_block_reason:", blocked_reason)

    h.clear_enemies(b)
    h.wait(lambda: h.status(b)["lifecycle"]["status"] == "alive", timeout=120,
           what="respawn after clearing")
    life_after = h.status(b)["lifecycle"]
    print("after clearing:", h.pretty(life_after))
    events = b.call("agent_events", {"limit": 10, "after_id": 0})["result"]["events"]
    print("events:", h.pretty(events)[:600])
    ok = blocked_ok and blocked_reason == "home_under_threat" and life_after["status"] == "alive"
    print("RESULT", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
