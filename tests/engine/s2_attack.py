"""Scenario 2: attack during gathering — pre-emption, evacuation, events, resume."""
import asyncio
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "src"))

import harness as h  # noqa: E402


async def scenario() -> int:
    h.load_scenario_save("s2-attack.zip")
    b = h.bridge()
    h.give_kit(b)
    runner = h.TaskRunner(b, poll_interval=1.0)

    print("task start via TaskRunner...")
    execute = asyncio.create_task(runner.execute(
        {"task": "gather_resource", "resource": "iron-ore", "amount": 200}, timeout=600))
    await asyncio.to_thread(h.wait,
                            lambda: h.status(b)["task"].get("phase") in {"mining", "moving"},
                            timeout=90, what="gathering started")
    print("phase before attack:", h.status(b)["task"].get("phase"),
          "| collected:", h.status(b)["task"].get("collected"))

    await asyncio.to_thread(h.lua, "game.speed = 5", b)
    await asyncio.to_thread(
        h.lua,
        "storage.ae_armed_firing_seen = false\n"
        "script.on_event(defines.events.on_tick, function()\n"
        "  local a = remote.call('factorio_autonomous_engineer', 'get_agent')\n"
        "  if a and a.valid and a.shooting_state.state == 1 then\n"
        "    storage.ae_armed_firing_seen = true\n"
        "  end\n"
        "end)", b)
    print("attackers:", await asyncio.to_thread(h.spawn_attackers, 3, 8.0, b))
    result = await asyncio.wait_for(execute, timeout=120)
    print("runner result:", h.pretty(result)[:420])

    safety = h.status(b)["safety"]
    task = h.status(b)["task"]
    print("safety:", h.pretty(safety))
    print("task:", h.pretty(task))
    firing = h.agent_lua("return a.shooting_state.state", b)
    firing_observed = h.lua("rcon.print(tostring(storage.ae_armed_firing_seen == true))", b)
    print("shooting_state (armed):", firing, "| firing observed during attack:", firing_observed)
    events = b.call("agent_events", {"limit": 10, "after_id": 0})["result"]["events"]
    print("events:", h.pretty(events)[:700])

    preempted = (result.get("status") == "interrupted_by_safety"
                 and task.get("status") == "paused"
                 and task.get("reason") in {"safety", "awaiting_llm_resume"})

    print("clearing attackers...")
    await asyncio.to_thread(h.clear_enemies, b)
    await asyncio.to_thread(h.wait, lambda: not h.status(b)["safety"]["active"],
                            timeout=180, what="emergency resolved")
    print("safety after clear:", h.pretty(h.status(b)["safety"]))
    events = b.call("agent_events", {"limit": 20, "after_id": 0})["result"]["events"]
    resolved = [e for e in events if e["type"] == "emergency_resolved"]
    print("emergency_resolved:", h.pretty(resolved)[:300])

    await asyncio.to_thread(h.lua, "game.speed = 60", b)
    print("resume:", h.pretty(b.call("task_resume", {"task_id": task["task_id"]})["result"]))
    final = await asyncio.to_thread(
        h.wait,
        lambda: (lambda s: s if s.get("status") in {"succeeded", "failed", "cancelled"} else None)(
            b.call("task_status", {"task_id": task["task_id"]})["result"]),
        timeout=500, interval=3, what="task completion")
    print("final task:", h.pretty(final))

    # Second attack without ammunition: must not shoot.
    await asyncio.to_thread(h.lua, "game.speed = 5", b)
    h.agent_lua('a.get_inventory(defines.inventory.character_ammo).clear() return ""', b)
    await asyncio.to_thread(h.spawn_attackers, 1, 6.0, b)
    await asyncio.sleep(3)
    unarmed_fire = h.agent_lua("return a.shooting_state.state", b)
    print("shooting_state (no ammo):", unarmed_fire)
    await asyncio.to_thread(h.clear_enemies, b)
    await asyncio.to_thread(h.wait, lambda: not h.status(b)["safety"]["active"],
                            timeout=180, what="second emergency resolved")

    # defines.shooting.shooting_enemies == 1, not_shooting == 0 in Factorio 2.1.
    print("low-health check: health set below 30% -> must not fire")
    h.agent_lua('a.get_inventory(defines.inventory.character_ammo)'
                '.insert{name="firearm-magazine", count=20} a.health = 40 return ""', b)
    await asyncio.to_thread(h.spawn_attackers, 1, 6.0, b)
    await asyncio.sleep(3)
    low_health_fire = h.agent_lua("return a.shooting_state.state", b)
    print("shooting_state (low health):", low_health_fire)
    await asyncio.to_thread(h.clear_enemies, b)
    await asyncio.to_thread(h.wait, lambda: not h.status(b)["safety"]["active"],
                            timeout=180, what="third emergency resolved")

    ok = (preempted and resolved and final.get("status") == "succeeded"
          and firing_observed == "true" and unarmed_fire == "0" and low_health_fire == "0")
    print("RESULT", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(asyncio.run(scenario()))
