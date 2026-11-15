"""Shared helpers for the engine reliability scenarios (save/load, safety, death, RCON faults).

These scenarios drive a real Factorio 2.1 headless server through the mod's RCON bridge. They are
not part of the unit suite: run them against a disposable save in an isolated write-data directory
(see tests/engine/README.md)."""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "src"))

from factorio_autonomous_engineer.bridge import Bridge, BridgeError  # noqa: E402
from factorio_autonomous_engineer.runner import TaskRunner  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
TESTDIR = Path(os.environ.get("FACTORIO_TEST_DIR", ROOT / ".runtime" / "factorio-test"))
FACTORIO = Path(os.environ.get(
    "FACTORIO_BIN",
    r"C:\Program Files (x86)\Steam\steamapps\common\Factorio\bin\x64\factorio.exe"))
def password() -> str:
    """RCON password of the local test server; never stored in the repository."""
    value = os.environ.get("FACTORIO_RCON_PASSWORD")
    if not value:
        raise SystemExit(
            "FACTORIO_RCON_PASSWORD must be set to the RCON password of the test server")
    return value

SAVES = TESTDIR / "saves"

__all__ = ["Bridge", "BridgeError", "TaskRunner", "bridge", "lua", "agent_lua", "lua_json",
           "status", "password",
           "wait", "start_server", "stop_server", "load_scenario_save", "save_as",
           "give_kit", "spawn_attackers", "clear_enemies", "snapshot", "pretty"]


def bridge() -> Bridge:
    return Bridge(password(), "127.0.0.1", 27075)


def lua(code: str, b: Bridge | None = None) -> str:
    return (b or bridge()).lua(code).strip()


AGENT = 'local a = remote.call("factorio_autonomous_engineer","get_agent") '


def agent_lua(body: str, b: Bridge | None = None) -> str:
    """Run `body` with `a` bound to the agent entity and print the returned value."""
    code = AGENT + "rcon.print(tostring((function() " + body + " end)()))"
    return lua(code, b)


def lua_json(code: str, b: Bridge | None = None):
    out = lua(code, b)
    return json.loads(out) if out else None


def status(b: Bridge | None = None) -> dict:
    return (b or bridge()).call("agent_status")["result"]


def pretty(value) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True)


def wait(predicate, *, timeout: float = 120, interval: float = 0.5, what: str = "condition"):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        last = predicate()
        if last:
            return last
        time.sleep(interval)
    raise TimeoutError(f"timed out waiting for {what}; last={last!r}")


def stop_server() -> None:
    subprocess.run(["powershell", "-NoProfile", "-Command",
                    "Get-Process factorio -ErrorAction SilentlyContinue | Stop-Process -Force"],
                   capture_output=True, check=False)
    time.sleep(2)


def start_server(save: str, *, wait_port: float = 60) -> None:
    stop_server()
    log = open(TESTDIR / "server-last.out", "w", encoding="utf-8")  # noqa: SIM115 - kept open
    subprocess.Popen(
        [str(FACTORIO), "--config", str(TESTDIR / "config" / "config.ini"),
         "--mod-directory", str(TESTDIR / "mods"),
         "--start-server", str(SAVES / save),
         "--server-settings", str(TESTDIR / "config" / "server-settings.json"),
         "--rcon-bind", "127.0.0.1:27075", "--rcon-password", password()],
        stdout=log, stderr=subprocess.STDOUT, cwd=str(TESTDIR),
    )
    deadline = time.monotonic() + wait_port
    while time.monotonic() < deadline:
        try:
            bridge().call("ping")
            return
        except (OSError, BridgeError):
            time.sleep(1)
    raise TimeoutError("RCON did not come up")


def load_scenario_save(name: str, baseline: str = "baseline.zip") -> None:
    shutil.copyfile(SAVES / baseline, SAVES / name)
    start_server(name)


def save_as(name: str, b: Bridge | None = None) -> str:
    """Save through the Lua console. The first console command in a session only prints the
    "will disable achievements" warning, so issue it twice."""
    lua(f'game.server_save("{name}")', b)
    return lua(f'game.server_save("{name}")', b)

def give_kit(b: Bridge | None = None) -> dict:
    """Iron plates, a gun with ammunition, armor and grid equipment on the agent."""
    code = """
    local a = remote.call("factorio_autonomous_engineer","get_agent")
    local main = a.get_main_inventory()
    main.insert{name="iron-plate", count=50}
    main.insert{name="copper-plate", count=25}
    local guns = a.get_inventory(defines.inventory.character_guns)
    guns.insert{name="submachine-gun", count=1}
    local ammo = a.get_inventory(defines.inventory.character_ammo)
    ammo.insert{name="firearm-magazine", count=100}
    local armor = a.get_inventory(defines.inventory.character_armor)
    armor.insert{name="modular-armor", count=1}
    local stack = armor[1]
    local ok, err = pcall(function()
      stack.grid.put{name="battery-equipment", quality="normal"}
      stack.grid.put{name="solar-panel-equipment", quality="normal"}
    end)
    local grid = stack.grid and stack.grid.get_contents() or nil
    rcon.print(helpers.table_to_json{ok=ok, err=tostring(err), grid=grid})
    """
    return lua_json(code, b)


def spawn_attackers(count: int = 3, distance: float = 8.0, b: Bridge | None = None) -> list:
    code = f"""
    local a = remote.call("factorio_autonomous_engineer","get_agent")
    local created = {{}}
    for i = 1, {count} do
      local angle = (i - 1) * 2 * math.pi / {count}
      local p = {{
        x = a.position.x + math.cos(angle) * {distance},
        y = a.position.y + math.sin(angle) * {distance},
      }}
      local unit = a.surface.create_entity{{
        name="small-biter", position=p, force=game.forces.enemy}}
      unit.commandable.set_command{{
        type=defines.command.attack, target=a,
        distraction=defines.distraction.by_damage}}
      created[#created+1] = unit.unit_number
    end
    rcon.print(helpers.table_to_json(created))
    """
    return lua_json(code, b) or []


def clear_enemies(b: Bridge | None = None) -> int:
    code = """
    local n = 0
    for _, e in pairs(game.surfaces["nauvis"].find_entities_filtered{force="enemy"}) do
      if e.valid then e.destroy() n = n + 1 end
    end
    rcon.print(n)
    """
    return int(lua(code, b) or 0)


def snapshot(b: Bridge | None = None) -> dict:
    """Exact per-item counts in every character inventory plus the armor grid."""
    code = """
    local a = remote.call("factorio_autonomous_engineer","get_agent")
    local function contents(inv)
      local t = {}
      if not inv then return t end
      for i = 1, #inv do
        local s = inv[i]
        if s.valid_for_read then t[s.name] = (t[s.name] or 0) + s.count end
      end
      return t
    end
    local armor = a.get_inventory(defines.inventory.character_armor)
    local equipment = {}
    for i = 1, #armor do
      local s = armor[i]
      if s.valid_for_read and s.grid then
        for _, eq in pairs(s.grid.get_contents()) do
          equipment[eq.name] = (equipment[eq.name] or 0) + 1
        end
      end
    end
    rcon.print(helpers.table_to_json{
      unit = a.unit_number, health = a.health,
      main = contents(a.get_main_inventory()),
      guns = contents(a.get_inventory(defines.inventory.character_guns)),
      ammo = contents(a.get_inventory(defines.inventory.character_ammo)),
      armor = contents(armor), equipment = equipment,
    })
    """
    return lua_json(code, b)


def recovery_contents(b: Bridge | None = None) -> dict:
    code = """
    local s = storage.autonomous_engineer
    local out = {}
    for _, key in pairs({"main", "guns", "ammo", "armor"}) do
      local bag = s.recovery and s.recovery[key]
      local t = {}
      if bag and bag.valid then
        for i = 1, #bag do
          local st = bag[i]
          if st.valid_for_read then t[st.name] = (t[st.name] or 0) + st.count end
        end
      end
      out[key] = t
    end
    rcon.print(helpers.table_to_json(out))
    """
    return lua_json(code, b)


# ---------------------------------------------------------------------------
# Construction scenario helpers
# ---------------------------------------------------------------------------

def place_plan(name: str = "test_basic", b: Bridge | None = None) -> dict:
    """Invoke the executor-owned named plan placement; no coordinates are supplied."""
    return (b or bridge()).call("construction_plan_place", {"plan": name})["result"]


def task_start(spec: dict, b: Bridge | None = None) -> dict:
    return (b or bridge()).call("task_start", spec)["result"]


def task_status(task_id: str, b: Bridge | None = None) -> dict:
    return (b or bridge()).call("task_status", {"task_id": task_id})["result"]


TERMINAL = {"succeeded", "failed", "cancelled", "partial", "missing_materials", "blocked"}


def wait_task(task_id: str, b: Bridge | None = None, *, timeout: float = 300) -> dict:
    return wait(lambda: (lambda s: s if s.get("status") in TERMINAL else None)(
        task_status(task_id, b)), timeout=timeout, interval=1.0, what=f"task {task_id}")


def ghosts(b: Bridge | None = None, *, radius: int = 64) -> list:
    code = f"""
    local a = remote.call("factorio_autonomous_engineer","get_agent")
    local out = {{}}
    for _, g in pairs(a.surface.find_entities_filtered{{
        area = {{{{a.position.x - {radius}, a.position.y - {radius}}},
                  {{a.position.x + {radius}, a.position.y + {radius}}}}},
        type = "entity-ghost"}}) do
      out[#out+1] = {{unit = g.unit_number, name = g.ghost_name,
        position = g.position, direction = g.direction, bbox = g.bounding_box}}
    end
    table.sort(out, function(a, b) return a.unit < b.unit end)
    rcon.print(helpers.table_to_json(out))
    """
    return lua_json(code, b) or []


def create_ghost(name: str, x: float, y: float, *, direction: int = 0,
                  quality: str = "normal", b: Bridge | None = None) -> dict:
    code = f"""
    local g = game.surfaces["nauvis"].create_entity{{name="entity-ghost",
      inner_name={json.dumps(name)}, position={{x={x},y={y}}},
      direction={direction}, force=game.forces.player, quality={json.dumps(quality)}}}
    rcon.print(helpers.table_to_json({{unit=g and g.unit_number, name=g and g.ghost_name,
      position=g and g.position}}))
    """
    return lua_json(code, b) or {}


def cancel_ghost(unit: int, b: Bridge | None = None) -> bool:
    code = f"""
    local g = game.surfaces["nauvis"].find_entities_filtered{{type="entity-ghost"}}
    for _, e in pairs(g) do
      if e.unit_number == {unit} then e.destroy() rcon.print(true) return end
    end
    rcon.print(false)
    """
    return lua(code, b).strip() == "true"


def build_ghost_as_player(unit: int, b: Bridge | None = None) -> dict:
    """Test scaffolding: simulate a player completing a ghost directly.

    The harness, unlike the mod, may call revive without payment; this is only setup.
    """
    code = f"""
    local g = game.surfaces["nauvis"].find_entities_filtered{{type="entity-ghost"}}
    for _, e in pairs(g) do
      if e.unit_number == {unit} then
        local _, entity = e.revive()
        rcon.print(helpers.table_to_json({{name=entity and entity.name,
          unit=entity and entity.unit_number, position=entity and entity.position}}))
        return
      end
    end
    rcon.print("null")
    """
    out = lua(code, b).strip()
    return json.loads(out) if out and out != "null" else {}


def create_chest(x: float, y: float, items: dict | None = None,
                 b: Bridge | None = None) -> dict:
    inserts = []
    for name, count in (items or {}).items():
        inserts.append(f'chest.get_inventory(defines.inventory.chest).insert'
                       f'{{name={json.dumps(name)},count={count},quality="normal"}}')
    code = f"""
    local chest = game.surfaces["nauvis"].create_entity{{name="wooden-chest",
      position={{x={x},y={y}}}, force=game.forces.player}}
    {' '.join(inserts)}
    rcon.print(helpers.table_to_json({{unit=chest.unit_number, position=chest.position,
      contents=chest.get_inventory(defines.inventory.chest).get_contents()}}))
    """
    return lua_json(code, b) or {}


def chest_contents(unit: int, b: Bridge | None = None) -> dict:
    code = f"""
    local out = {{}}
    for _, e in pairs(game.surfaces["nauvis"].find_entities_filtered{{type={{"container",
        "logistic-container"}}}}) do
      if e.unit_number == {unit} then
        local inv = e.get_inventory(defines.inventory.chest)
        rcon.print(helpers.table_to_json(inv and inv.get_contents() or {{}}))
        return
      end
    end
    rcon.print("null")
    """
    out = lua(code, b).strip()
    return json.loads(out) if out and out != "null" else {}


def create_natural(name: str, x: float, y: float, b: Bridge | None = None) -> dict:
    code = f"""
    local e = game.surfaces["nauvis"].create_entity{{name={json.dumps(name)},
      position={{x={x},y={y}}}, force="neutral"}}
    rcon.print(helpers.table_to_json({{name=e and e.name, type=e and e.type,
      unit=e and e.unit_number, position=e and e.position}}))
    """
    return lua_json(code, b) or {}


def create_real_entity(name: str, x: float, y: float, *, direction: int = 0,
                       b: Bridge | None = None) -> dict:
    code = f"""
    local e = game.surfaces["nauvis"].create_entity{{name={json.dumps(name)},
      position={{x={x},y={y}}}, direction={direction}, force=game.forces.player}}
    rcon.print(helpers.table_to_json({{name=e and e.name, type=e and e.type,
      unit=e and e.unit_number, position=e and e.position}}))
    """
    return lua_json(code, b) or {}


def create_player_character(x: float, y: float, b: Bridge | None = None) -> dict:
    return create_real_entity("character", x, y, b=b)


def remove_entity(unit: int, b: Bridge | None = None) -> bool:
    code = f"""
    local n = 0
    for _, e in pairs(game.surfaces["nauvis"].find_entities_filtered{{}}) do
      if e.unit_number == {unit} then e.destroy() n = n + 1 end
    end
    rcon.print(n)
    """
    return int(lua(code, b) or 0) > 0


def _lua_list(values: list[str]) -> str:
    return "{" + ",".join(json.dumps(value) for value in values) + "}"


def entities_named(names: list[str], b: Bridge | None = None) -> list:
    code = f"""
    local out = {{}}
    for _, e in pairs(game.surfaces["nauvis"].find_entities_filtered{{
        name={_lua_list(names)}}}) do
      out[#out+1] = {{name=e.name, type=e.type, unit=e.unit_number, position=e.position}}
    end
    table.sort(out, function(a,b) return a.unit < b.unit end)
    rcon.print(helpers.table_to_json(out))
    """
    return lua_json(code, b) or []


def entity_at(name: str, x: float, y: float, radius: float = 2.0,
              b: Bridge | None = None) -> dict | None:
    code = f"""
    local out = nil
    for _, e in pairs(game.surfaces["nauvis"].find_entities_filtered{{
        name={json.dumps(name)}, area={{{{{x-radius},{y-radius}}},{{{x+radius},{y+radius}}}}}}}) do
      if e.valid then out = {{name=e.name, type=e.type, unit=e.unit_number,
        position=e.position}} break end
    end
    rcon.print(out and helpers.table_to_json(out) or "null")
    """
    return lua_json(code, b)


def give_items(items: dict, b: Bridge | None = None) -> dict:
    inserts = []
    for name, count in items.items():
        inserts.append(f'main.insert{{name={json.dumps(name)},count={count},quality="normal"}}')
    code = f"""
    local a = remote.call("factorio_autonomous_engineer","get_agent")
    local main = a.get_main_inventory()
    {' '.join(inserts)}
    rcon.print(helpers.table_to_json(main.get_contents()))
    """
    return lua_json(code, b) or {}


def clear_main_inventory(b: Bridge | None = None) -> None:
    agent_lua("a.get_main_inventory().clear() return ''", b)


def fill_main_inventory(item: str = "iron-plate", b: Bridge | None = None) -> dict:
    code = f"""
    local a = remote.call("factorio_autonomous_engineer","get_agent")
    local main = a.get_main_inventory()
    main.clear()
    main.insert{{name={json.dumps(item)}, count=100000, quality="normal"}}
    rcon.print(helpers.table_to_json({{count=main.get_item_count(), full=main.is_full()}}))
    """
    return lua_json(code, b) or {}


def clear_test_area(x1: float, y1: float, x2: float, y2: float,
                    b: Bridge | None = None, *, keep_resources: bool = True) -> int:
    keep = 'e.type ~= "resource"' if keep_resources else 'true'
    code = f"""
    local n = 0
    for _, e in pairs(game.surfaces["nauvis"].find_entities_filtered{{
        area={{{{{x1},{y1}}},{{{x2},{y2}}}}}}}) do
      if e.valid and e.type ~= "character" and ({keep}) then e.destroy() n = n + 1 end
    end
    rcon.print(n)
    """
    return int(lua(code, b) or 0)


def remove_chest_items(unit: int, name: str, count: int,
                       b: Bridge | None = None) -> int:
    code = f"""
    for _, e in pairs(game.surfaces["nauvis"].find_entities_filtered{{type={{"container",
        "logistic-container"}}}}) do
      if e.unit_number == {unit} then
        local inv = e.get_inventory(defines.inventory.chest)
        rcon.print(inv and inv.remove{{name={json.dumps(name)}, count={count},
          quality="normal"}} or 0)
        return
      end
    end
    rcon.print(0)
    """
    return int(lua(code, b) or 0)
