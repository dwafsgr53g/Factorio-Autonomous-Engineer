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
RCON_PORT = int(os.environ.get("FACTORIO_RCON_PORT", "27075"))
GAME_PORT = int(os.environ.get("FACTORIO_GAME_PORT", "34197"))


def password() -> str:
    """RCON password of the local test server; never stored in the repository."""
    value = os.environ.get("FACTORIO_RCON_PASSWORD")
    if not value:
        raise SystemExit(
            "FACTORIO_RCON_PASSWORD must be set to the RCON password of the test server")
    return value

SAVES = TESTDIR / "saves"

__all__ = ["Bridge", "BridgeError", "TaskRunner", "bridge", "lua", "agent_lua", "lua_json",
           "status", "password", "RCON_PORT", "GAME_PORT",
           "wait", "start_server", "stop_server", "load_scenario_save", "save_as",
           "give_kit", "spawn_attackers", "clear_enemies", "snapshot", "pretty"]


def bridge() -> Bridge:
    return Bridge(password(), "127.0.0.1", RCON_PORT)


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
    # Kill only the server that belongs to this isolated runtime directory. A different
    # Stage-5 acceptance server may legitimately be running from another profile.
    marker = str(TESTDIR).replace("'", "''")
    command = (
        "Get-CimInstance Win32_Process -Filter \"Name='factorio.exe'\" | "
        f"Where-Object {{$_.CommandLine -like '*{marker}*'}} | "
        "ForEach-Object { Stop-Process -Id $_.ProcessId -Force }"
    )
    subprocess.run(["powershell", "-NoProfile", "-Command", command],
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
         "--port", str(GAME_PORT),
         "--rcon-bind", f"127.0.0.1:{RCON_PORT}", "--rcon-password", password()],
        stdout=log, stderr=subprocess.STDOUT, cwd=str(TESTDIR),
    )
    deadline = time.monotonic() + wait_port
    while time.monotonic() < deadline:
        try:
            probe = bridge()
            probe.call("ping")
            speed = os.environ.get("FACTORIO_GAME_SPEED")
            if speed:
                probe.lua(f"game.speed = {speed}")
                probe.lua(f"game.speed = {speed}")
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


def task_cancel(task_id: str, reason: str = "cancelled", b: Bridge | None = None) -> dict:
    return (b or bridge()).call("task_cancel", {
        "task_id": task_id, "reason": reason})["result"]


def task_resume(task_id: str, b: Bridge | None = None) -> dict:
    return (b or bridge()).call("task_resume", {"task_id": task_id})["result"]


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


# ---------------------------------------------------------------------------
# Stage-4 module catalog and instantiation helpers (internal harness surface)
# ---------------------------------------------------------------------------

def module_catalog(b: Bridge | None = None) -> dict:
    return (b or bridge()).call("module_catalog")["result"]


def module_definition(module_id: str, b: Bridge | None = None) -> dict:
    return (b or bridge()).call("module_definition", {"module_id": module_id})["result"]


def module_validate(definition: dict, b: Bridge | None = None) -> dict:
    return (b or bridge()).call(
        "module_validate_definition", {"definition": definition})["result"]


def module_resolve(module_id: str, anchor: dict, *, orientation: int = 0,
                   parameters: dict | None = None, b: Bridge | None = None) -> dict:
    return (b or bridge()).call("module_resolve", {
        "module_id": module_id, "anchor": anchor, "orientation": orientation,
        "parameters": parameters or {},
    })["result"]


def module_instantiate(module_id: str, anchor: dict, *, orientation: int = 0,
                       parameters: dict | None = None, instance_key: str | None = None,
                       b: Bridge | None = None) -> dict:
    params = {"module_id": module_id, "anchor": anchor, "orientation": orientation,
              "parameters": parameters or {}}
    if instance_key is not None:
        params["instance_key"] = instance_key
    return (b or bridge()).call("module_instantiate", params)["result"]


def module_instance_status(instance_key: str, b: Bridge | None = None) -> dict:
    return (b or bridge()).call(
        "module_instance_status", {"instance_key": instance_key})["result"]


def module_instances(b: Bridge | None = None) -> list:
    return (b or bridge()).call("module_instances")["result"]["instances"]


# ---------------------------------------------------------------------------
# Stage-5 Layout Planner helpers (internal RCON surface and public projection)
# ---------------------------------------------------------------------------

def set_home(position: dict, b: Bridge | None = None) -> dict:
    return (b or bridge()).call("set_home", {
        "surface": "nauvis", "position": position})["result"]


def plan_layout(goal_item: str, *, force_new: bool = False,
                orientation_hints: dict | None = None,
                b: Bridge | None = None) -> dict:
    params: dict = {"goal_item": goal_item}
    if force_new:
        params["force_new"] = True
    if orientation_hints:
        params["orientation_hints"] = orientation_hints
    return (b or bridge()).call("layout_plan_create", params)["result"]


def apply_layout(plan_id: str, b: Bridge | None = None) -> dict:
    return (b or bridge()).call("layout_plan_apply", {"plan_id": plan_id})["result"]


def layout_plan_status(plan_id: str, b: Bridge | None = None) -> dict:
    return (b or bridge()).call("layout_plan_status", {"plan_id": plan_id})["result"]


def layout_plans(b: Bridge | None = None) -> list:
    return (b or bridge()).call("layout_plans")["result"]["plans"]


def plan_layout_public(goal_item: str, b: Bridge | None = None) -> dict:
    return (b or bridge()).call("plan_layout", {"goal_item": goal_item})["result"]


def apply_layout_public(plan_id: str, b: Bridge | None = None) -> dict:
    return (b or bridge()).call("apply_layout", {"plan_id": plan_id})["result"]


def ghost_tags(b: Bridge | None = None) -> list:
    code = """
    local out = {}
    for _, g in pairs(game.surfaces.nauvis.find_entities_filtered{type="entity-ghost"}) do
      out[#out+1] = {unit=g.unit_number, name=g.ghost_name, tags=g.tags}
    end
    table.sort(out, function(a,b) return a.unit < b.unit end)
    rcon.print(helpers.table_to_json(out))
    """
    return lua_json(code, b) or []


def real_counts(b: Bridge | None = None) -> dict:
    code = """
    local out = {}
    for _, e in pairs(game.surfaces.nauvis.find_entities_filtered{}) do
      if e.valid and e.type ~= "entity-ghost" and e.type ~= "resource"
         and e.type ~= "character" then
        out[e.name] = (out[e.name] or 0) + 1
      end
    end
    rcon.print(helpers.table_to_json(out))
    """
    return lua_json(code, b) or {}




# ---------------------------------------------------------------------------
# Stage-6 physical logistics helpers
# ---------------------------------------------------------------------------

def layout_chain_plan(goal_item: str = "iron-gear-wheel", *, force_new: bool = True,
                      b: Bridge | None = None) -> dict:
    return (b or bridge()).call("layout_plan_create", {
        "goal_item": goal_item, "logistics_chain": True, "force_new": force_new,
    })["result"]


def layout_multi_consumer_plan(goal_item: str = "iron-gear-wheel", *,
                               force_new: bool = True,
                               b: Bridge | None = None) -> dict:
    return (b or bridge()).call("layout_plan_create", {
        "goal_item": goal_item, "multi_consumer": True, "force_new": force_new,
    })["result"]


def logistics_plan_create(layout_plan_id: str, b: Bridge | None = None) -> dict:
    return (b or bridge()).call(
        "logistics_plan_create", {"layout_plan_id": layout_plan_id})["result"]


def logistics_plan_expansion(layout_plan_id: str, b: Bridge | None = None) -> dict:
    return (b or bridge()).call(
        "logistics_plan_expansion", {"layout_plan_id": layout_plan_id})["result"]


def transport_probe(*, splitter: dict | None = None,
                    underground: dict | None = None,
                    b: Bridge | None = None) -> dict:
    params: dict = {}
    if splitter is not None:
        params["splitter"] = splitter
    if underground is not None:
        params["underground"] = underground
    return (b or bridge()).call("transport_probe", params)["result"]


def logistics_plan_status(logistics_plan_id: str, b: Bridge | None = None) -> dict:
    return (b or bridge()).call(
        "logistics_plan_status", {"logistics_plan_id": logistics_plan_id})["result"]


def logistics_ghosts_place(logistics_plan_id: str, b: Bridge | None = None) -> dict:
    return (b or bridge()).call(
        "logistics_ghosts_place", {"logistics_plan_id": logistics_plan_id})["result"]


def logistics_verify(logistics_plan_id: str, b: Bridge | None = None) -> dict:
    return (b or bridge()).call(
        "logistics_verify", {"logistics_plan_id": logistics_plan_id})["result"]


def logistics_plans(b: Bridge | None = None) -> list:
    return (b or bridge()).call("logistics_plans")["result"]["plans"]


def task_debug(b: Bridge | None = None) -> dict:
    return (b or bridge()).call("task_debug")["result"]


def task_entries(b: Bridge | None = None) -> dict:
    return (b or bridge()).call("task_entries")["result"]


def tile_center(x: int, y: int) -> dict:
    return {"x": x + 0.5, "y": y + 0.5}


def create_solar_fixture(pole_x: float, pole_y: float, b: Bridge | None = None) -> dict:
    """Harness-only fixture: a legitimate powered network from solar panels.

    The scenario records this as pre-existing infrastructure; the agent does not build
    the generator. The physics, pole connection and consumer power are still real.
    """
    code = f"""
    local s = game.surfaces.nauvis
    local result = {{ok = true}}
    local function make(name, x, y)
      local ok, entity = pcall(function()
        return s.create_entity{{name=name, position={{x=x,y=y}},
          force=game.forces.player}}
      end)
      if not ok or not entity or not entity.valid then
        result.ok = false
        result.error = tostring(entity)
        return nil
      end
      return entity
    end
    local pole = make("medium-electric-pole", {pole_x}, {pole_y})
    local panels = 0
    for _, p in ipairs({{{{x={pole_x}-4,y={pole_y}}},{{x={pole_x}+4,y={pole_y}}},
                         {{x={pole_x},y={pole_y}-4}},{{x={pole_x},y={pole_y}+4}}}}) do
      if make("solar-panel", p.x, p.y) then panels = panels + 1 end
    end
    local accumulator = make("accumulator", {pole_x}-4, {pole_y}+4)
    result.pole = pole and pole.unit_number or nil
    result.network = pole and pole.electric_network_id or nil
    result.panels = panels
    result.accumulator = accumulator and accumulator.unit_number or nil
    rcon.print(helpers.table_to_json(result))
    """
    return lua_json(code, b) or {"ok": False, "error": "fixture_lua_failed"}


def electric_network_flow(pole_unit: int, b: Bridge | None = None) -> dict:
    code = f"""
    local out = nil
    for _, e in pairs(game.surfaces.nauvis.find_entities_filtered{{type="electric-pole"}}) do
      if e.unit_number == {pole_unit} then
        local net = e.electric_network
        local parent = net and net.parent_network
        out = {{network_id=e.electric_network_id,
          flow=parent and parent.flow_last_tick or nil,
          connections=e.get_wire_connectors and #e.get_wire_connectors(false) or nil}}
      end
    end
    rcon.print(helpers.table_to_json(out))
    """
    return lua_json(code, b) or {}


def transport_line_contents(x: float, y: float, b: Bridge | None = None) -> dict:
    code = f"""
    local out = nil
    for _, e in pairs(game.surfaces.nauvis.find_entities_filtered{{
        area={{{{x={x}-0.6,y={y}-0.6}},{{x={x}+0.6,y={y}+0.6}}}},
        type="transport-belt"}}) do
      if e.valid then
        local line = e.get_transport_line(1)
        out = line and line.get_contents() or {{}}
      end
    end
    out = out or {{}}
    rcon.print(helpers.table_to_json(out))
    """
    return lua_json(code, b) or {}


def belt_entities(b: Bridge | None = None, radius: int = 64) -> list:
    code = f"""
    local a = remote.call("factorio_autonomous_engineer","get_agent")
    local out = {{}}
    for _, e in pairs(a.surface.find_entities_filtered{{
        area={{{{a.position.x-{radius},a.position.y-{radius}}},
               {{a.position.x+{radius},a.position.y+{radius}}}}},
        type="transport-belt"}}) do
      out[#out+1] = {{unit=e.unit_number, name=e.name,
        position=e.position, direction=e.direction, shape=e.belt_shape,
        neighbours=e.belt_neighbours}}
    end
    table.sort(out, function(a,b) return a.unit < b.unit end)
    rcon.print(helpers.table_to_json(out))
    """
    return lua_json(code, b) or []


def machine_contents(name: str, inventory: str, b: Bridge | None = None) -> dict:
    code = f"""
    local out = {{}}
    for _, e in pairs(game.surfaces.nauvis.find_entities_filtered{{name={json.dumps(name)}}}) do
      local inv = e.get_inventory(defines.inventory[{json.dumps(inventory)}])
      out[e.unit_number] = inv and inv.get_contents() or {{}}
    end
    rcon.print(helpers.table_to_json(out))
    """
    return lua_json(code, b) or {}


def research_all(b: Bridge | None = None) -> None:
    '''Test scaffolding: unlock prototypes on the disposable scenario force.'''
    lua('game.forces.player.research_all_technologies()', b)


def find_resource_anchor(resource: str, width: int = 3, height: int = 3,
                         minimum_amount: int = 9, radius: int = 180,
                         b: Bridge | None = None) -> dict | None:
    """Find a test-controlled resource footprint for a mining module."""
    code = f"""
    local s = game.surfaces.nauvis
    local a = remote.call("factorio_autonomous_engineer","get_agent")
    local resources = s.find_entities_filtered{{
      name = {json.dumps(resource)}, type = "resource",
      area = {{{{a.position.x - {radius}, a.position.y - {radius}}},
                {{a.position.x + {radius}, a.position.y + {radius}}}}}}}
    local best = nil
    for _, r in pairs(resources) do
      local ax = math.floor(r.position.x) - math.floor({width} / 2)
      local ay = math.floor(r.position.y) - math.floor({height} / 2)
      local area = {{{{ax, ay}}, {{ax + {width}, ay + {height}}}}}
      local inside = s.find_entities_filtered{{name = {json.dumps(resource)},
        type = "resource", area = area}}
      local amount = 0
      for _, e in pairs(inside) do amount = amount + e.amount end
      if amount >= {minimum_amount} then
        best = {{x = ax, y = ay, amount = amount, count = #inside}}
        break
      end
    end
    rcon.print(best and helpers.table_to_json(best) or "null")
    """
    value = lua_json(code, b)
    return value or None
