# Stage skill: automation

## Strategic objective

Expand stable automated production, logistics and defensive coverage.

Only use capabilities explicitly advertised by the live briefing. The prototype exposes the
Layout Planner and the composite `build_logistics` task. Use `mode="linear_chain"` for a first
single chain and `mode="multi_consumer"` when multiple consumers/producers, splitters or an
underground crossing are wanted. The task builds real splitters, one-to-two branches, two-to-one
merges and an ordinary underground pair as part of the expansion. It still does not expose power
generation, autonomous coal mining, splitter filters/priorities, fluids, circuits, construction
robots or logistics-network management. A `blocked` result with `missing_power_source` or
`missing_fuel_source` means a normal gameplay prerequisite must be supplied by the player; do not
attempt to synthesize it through low-level actions. Do not claim balanced throughput: a splitter
shares whatever physical flow the connected consumers and back-pressure allow.
