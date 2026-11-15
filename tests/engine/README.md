# Engine reliability scenarios

Python unit tests cannot prove Lua/gameplay behaviour. These scenarios drive a **real Factorio 2.1
headless server** through the mod's RCON bridge and assert on observable state only (MCP tool
results, `agent_status`, event queue, character inventories).

They are deliberately outside `tests/` discovery: `python -m unittest discover -s tests` must stay
fast and engine-free.

## Prerequisites

1. Factorio 2.1 with `bin/x64/factorio.exe` (`FACTORIO_BIN` overrides the default Steam path).
2. An **isolated write-data directory** — never the player's real one:

   ```
   <repo>/.runtime/factorio-test/
     config/config.ini          # read-data -> install, write-data -> this directory
     config/server-settings.json
     mods/                      # packaged mod + mod-list.json (+ optional ae_probe diagnostics)
     saves/baseline.zip         # disposable map, created with the test mod set
   ```

   `FACTORIO_TEST_DIR` overrides the location, `FACTORIO_RCON_PASSWORD` the RCON password
   (default `aetest-7f3c9-local`).

3. RCON must be enabled **on the command line**. A `"rcon"` block in `server-settings.json` is
   ignored by 2.1.24 and the server then starts without a listener:

   ```
   factorio.exe --config <dir>/config/config.ini --mod-directory <dir>/mods \
     --start-server <dir>/saves/<save>.zip --server-settings <dir>/config/server-settings.json \
     --rcon-bind 127.0.0.1:27075 --rcon-password <password>
   ```

   `--rcon-port` cannot be combined with `--rcon-bind`.

`harness.py` starts and stops the server, creates scenario copies of `baseline.zip`, and provides
inventory/equipment snapshots plus biter attack helpers. Every scenario copies the baseline, so
scenarios never inherit each other's state.

## Scenarios

| Script | Asserts |
| --- | --- |
| `s1_save_load.py` | hard kill + reload while mining: task id/phase/collected survive, task finishes with the exact requested amount, no double counting |
| `s2_attack.py` | biter attack during gathering: task paused by safety, `interrupted_by_safety` returned to the caller, evacuation to a safe destination, `agent_under_attack` / `emergency_resolved` events, explicit resume completes the task, firing only with gun+ammo and health above 30 % |
| `s3_death.py` | death recovery: main/guns/ammo/armor and armor-grid equipment restored exactly once, new unit number, task paused with reason `death`, resume gathers the remaining amount |
| `s3b_unsafe_home.py` | respawn holds at `waiting_for_safe_spawn` / `home_under_threat` while hostiles sit in the home radius, then completes once the area is clear |
| `s4_rcon.py` | replay of the same `request_id` returns the cached response instead of a second task (deduplication is request-id scoped, not a general exactly-once guarantee), cache survives save/load, connection loss raises a bounded error carrying the request id, reconnect works, wrong password and missing server report clearly |
| `s4b_mcp_restart.py` | SIGKILL of the MCP client mid-task: the task keeps its id, a fresh MCP process reports it, and the remaining amount completes exactly |

Run one at a time (they share port 27075):

```
uv run python tests/engine/s3_death.py
```

Each script prints its evidence and exits non-zero on failure.

## Optional diagnostics mod

`.runtime/factorio-test/mods/ae_probe/` is a read-only probe that records what the engine exposes
during a character death (`script-output/ae_probe.log`). It is only useful when debugging recovery
changes and is not required for the scenarios.
