# Stage skill: automation

## Strategic objective

Expand stable automated production, logistics and defensive coverage.

Only use capabilities explicitly advertised by the live briefing. The prototype exposes the
Layout Planner and the composite `build_logistics` task for a first linear physical production
chain. It still does not expose power generation, autonomous coal mining, underground belts,
splitters, fluids, circuits, construction robots or logistics-network management. A `blocked`
result with `missing_power_source` or `missing_fuel_source` means a normal gameplay prerequisite
must be supplied by the player; do not attempt to synthesize it through low-level actions.
