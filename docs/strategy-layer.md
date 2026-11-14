# Strategic layer and skill activation

## Intended operating model

The LLM is a planner. It decides which milestone to pursue and which high-level task should happen next. It must not calculate coordinates, routes, reach, inventory slots, mining loops, crafting queues, entity placement geometry or defensive movement.

The runtime owns those mechanics. It returns compact outcomes that let the planner choose the next objective without seeing raw implementation details or the server's Lua/Python source.

## Session bootstrap

1. get_briefing asks the Factorio mod for a deterministic world profile.
2. The profile identifies the active domain (planet, surface or space platform), planet name, progression stage, base maturity, agent lifecycle and currently supported capabilities.
3. Python loads matching plain-Markdown skill files: core strategy, stage guidance and a planet-specific modifier.
4. The MCP response contains the strategic profile and loaded skill text. It does not contain raw coordinates, entity handles, path nodes, inventory indexes, or Lua source.
5. The planner chooses one goal from the returned capability list.

Call get_briefing again after a milestone changes research progression, the active planet/domain changes, or the agent is respawned into a materially different situation.

## Stage detection

Stage detection is code-owned and evidence-based. The first rules use researched technologies and space-platform presence:

- early_game: automation not researched.
- automation_bootstrap: automation researched, no logistic science yet.
- automation: logistic science researched.
- oil_processing: oil processing or chemical science researched.
- advanced_industry: production or utility science researched.
- space_age: space science/promethium science or at least one owned platform exists.

The classifier exposes evidence flags so a planner can see why a stage was selected. Rules will evolve with Space Age and supported mods; unrecognized progression must fail closed rather than unlock a guessed toolset.

## Capability gating

The profile advertises only capabilities actually implemented and valid for the active domain. The Factorio mod independently validates every mutating request. The list returned to the LLM is not merely descriptive documentation.

Currently implemented high-level goals:

- select_starting_site on Nauvis during bootstrap. The model supplies no coordinates.
- gather_resource on a planet surface. The model supplies a resource and requested amount only.

The site selector works only with generated chunks around the starting area. It finds candidate centers with a furnace-sized free footprint, evaluates iron/copper/coal/stone proximity, water access, known hostile units/spawners/turrets and generated-chunk coverage, then registers the best candidate as the agent's home. It does not claim unexplored territory is enemy-free. The selector is Nauvis-only; other planets require their own site-scoring strategy and skill rules.

## Skill files

Skill files are plain Markdown loaded by Python as prompt material. They are not scripts and are never evaluated. A missing planet modifier is simply omitted; the core strategy and stage skill remain active. The live capability list always wins over aspirational skill text.

## Model-visible boundary

The MCP interface intentionally excludes raw RCON, arbitrary Lua execution, low-level movement, mining-state, item-transfer and inventory-index operations. Internal polling and game-action sequences happen behind one high-level task call. Status and event responses are compact and omit world coordinates.
