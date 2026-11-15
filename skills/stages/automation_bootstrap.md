# Stage skill: automation bootstrap

## Strategic objective

Turn the initial foothold into a stable first automated production system.

The current prototype exposes high-level gathering, starting-site selection, bounded
`assist_construction`, `plan_layout`/`apply_layout`, and the composite `build_logistics` task.
`build_logistics` plans a deterministic linear chain, builds real belts, inserters, an ordinary
coal-chest fuel feed and electric poles connected to an existing powered network, then verifies
actual item movement and production. Power generation, autonomous coal mining, underground belts,
splitters, fluids, circuits and arbitrary whole-base generation are not automated. If the result
is `blocked` with `missing_power_source` or `missing_fuel_source`, tell the user which normal
in-game prerequisite is missing; do not ask for coordinates or fabricate infrastructure.
