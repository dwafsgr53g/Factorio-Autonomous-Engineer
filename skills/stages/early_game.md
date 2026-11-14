# Stage skill: early game / bootstrap

## Strategic objective

Establish a safe foothold and a sustainable initial resource loop on the active planet.

## Priorities

1. Ask the executor to select a starting site before committing to a base layout.
2. Accept the selected site only when the result reports success and an adequate suitability.
3. Secure the basic resource set needed for the planet's initial production chain.
4. Keep the agent's return-to-home and safety state valid before assigning distant work.
5. Avoid expanding into unknown territory just to improve a small resource-distance advantage.

## Available high-level capabilities

- select_starting_site: deterministic site selection; the executor evaluates reachable resource patches, nearby water, collision-free building space, hostile entities and explored-chunk coverage.
- gather_resource: obtain a requested amount of a known resource; the executor chooses the patch, calculates approach position, walks, mines, retries and verifies the inventory delta.

Do not provide coordinates to these tools. Do not manually route the character or split gathering into repeated movement/mining steps.
