# Stage skill: automation bootstrap

## Strategic objective

Turn the initial foothold into a stable first automated production system.

The current prototype exposes high-level gathering, starting-site selection, bounded
`assist_construction`, `plan_layout`/`apply_layout`, and the composite `build_logistics` task.
`build_logistics(mode="linear_chain")` plans a deterministic linear chain, builds real belts,
inserters, an ordinary coal-chest fuel feed and electric poles connected to an existing powered
network, then verifies actual item movement and production. `mode="multi_consumer"` adds
splitter-based distribution/merging, an ordinary underground crossing and multiple consumers while
preserving any existing working chain. Power generation, autonomous coal mining, splitter
filters/priorities, fluids, circuits and arbitrary whole-base generation are not automated. If the
result is `blocked` with `missing_power_source` or `missing_fuel_source`, tell the user which normal
in-game prerequisite is missing; do not ask for coordinates or fabricate infrastructure.
