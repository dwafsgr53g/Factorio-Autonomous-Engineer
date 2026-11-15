# Local verification — 2026-11-15 smoke run

Environment: Factorio 2.1.24 (Steam build), Windows, isolated write-data directory
`<repo>/.runtime/factorio-test` (own `config.ini`, `mods/`, `saves/`, own RCON password).
Mod set: base, elevated-rails, quality, recycler, space-age, planet-express 2.1.12,
factorio_autonomous_engineer 0.1.0. `factorio_llm_use` disabled in this profile, so only one
engineer is spawned.

Save: freshly generated disposable map (`--create .runtime/factorio-test/saves/test-world.zip`).
No existing save of the user's was modified.

## Results (observed, not inferred)

| Check | Result |
| --- | --- |
| Map creation with mod enabled | loads, `control.lua` checksum `3617369306`, no Lua warnings |
| Headless server + RCON on `127.0.0.1:27075` | works |
| MCP server over stdio, `tools/list` | 7 tools as documented |
| `get_briefing` | `planet=nauvis`, `stage=early_game`, skills `core_strategy`, `stage_early_game`, `planet_nauvis`, no coordinates |
| `select_starting_site` | `suitability=excellent`, iron/copper/coal/stone nearby, water distant, no hostiles in exclusion radius, `registered_as_home=true` |
| `execute_task gather_resource iron-ore 20` | `succeeded`, `collected=20`, one terminal tool result, inventory delta matches |
| unavailable resource (`uranium-ore`) | `failed`, reason `no_reachable_deposits`, bounded (0 s) |
| unknown item prototype | rejected with explicit assertion, no infinite loop |
| `task_cancel` mid-task | `status=cancelled`, `walking=false`, `mining=false` |

Not yet exercised: safety pre-emption under attack, death/respawn and inventory recovery,
save/load checkpoint survival, RCON failure modes. Those need a controlled scenario on a
disposable save.

## Defects found and fixed during preparation

1. `lib/strategy.lua:105`, `lib/safety.lua:159`, `lib/safety.lua:232` used
   `agent.prototype.max_health`. `LuaEntityPrototype` has no `max_health` in 2.1.24, so
   `strategy_context` raised `LuaEntityPrototype doesn't contain key max_health` and
   `get_briefing` failed outright. Replaced with `agent.max_health` (live value, 250 for the
   character).
2. `lib/tasks.lua` used a fixed whole-task deadline of `60 * 30` ticks (30 s). A 20-ore
   gathering goal hit `task_deadline_exceeded` after 13 ore. Replaced with
   `TASK_BASE_TICKS (120 s) + amount * TASK_TICKS_PER_UNIT (3 s/unit)`, stored on the task so it
   survives save/load. Failure stays bounded.

## Operational note

The `"rcon"` block in `server-settings.json` is **not** honoured by this build — the server
starts without an RCON listener and logs nothing about it. Enable RCON on the command line
instead:

```
factorio.exe --start-server <save> --server-settings <file> \
  --rcon-bind 127.0.0.1:27075 --rcon-password <password>
```

`--rcon-port` cannot be combined with `--rcon-bind`.
