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


AGENT = ('local a = game.surfaces["nauvis"].find_entities_filtered{type="character"}[1] ')


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
    local a = game.surfaces["nauvis"].find_entities_filtered{type="character"}[1]
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
    local a = game.surfaces["nauvis"].find_entities_filtered{{type="character"}}[1]
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
    local a = game.surfaces["nauvis"].find_entities_filtered{type="character"}[1]
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
