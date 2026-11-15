"""Reference implementation of the Stage-6 physical logistics geometry.

The authoritative implementation runs inside the Factorio mod in
``mod/factorio_autonomous_engineer/lib/logistics.lua``. This module mirrors the
deterministic, bounded parts so the Python unit suite can verify tie-breaking,
turning, obstacle avoidance and the exact inserter gap arithmetic without a game
engine. It never claims engine behaviour: real belts, inserters, power and
production must still be observed in Factorio.
"""
from __future__ import annotations

from collections.abc import Iterable, Mapping
from dataclasses import dataclass
from heapq import heappop, heappush

NORTH, EAST, SOUTH, WEST = 0, 4, 8, 12
NEIGHBOURS = ((0, -1), (1, 0), (0, 1), (-1, 0))
DIRECTIONS = {NORTH: (0, -1), EAST: (1, 0), SOUTH: (0, 1), WEST: (-1, 0)}


@dataclass(frozen=True, order=True)
class Tile:
    x: int
    y: int

    def neighbor(self, direction: int) -> Tile:
        dx, dy = DIRECTIONS[direction]
        return Tile(self.x + dx, self.y + dy)


def tile_of(position_x: float, position_y: float) -> Tile:
    return Tile(int(position_x // 1), int(position_y // 1))


def tile_center(tile: Tile) -> tuple[float, float]:
    return (tile.x + 0.5, tile.y + 0.5)


def direction_between(a: Tile, b: Tile) -> int:
    if b.x > a.x:
        return EAST
    if b.x < a.x:
        return WEST
    if b.y > a.y:
        return SOUTH
    return NORTH


def plan_route(
    blocked: Mapping[Tile, object] | Iterable[Tile],
    start: Tile,
    goal: Tile,
    *,
    max_nodes: int = 4096,
    max_length: int = 128,
    allow: Iterable[Tile] = (),
) -> list[Tile] | None:
    """Deterministic cardinal A*.

    Neighbour order is north, east, south, west. Open-set ordering is
    ``(f, g, x, y)`` so equal-cost alternatives are resolved identically on every
    run. ``blocked`` is read-only; the caller owns the tile grid.
    """
    blocked_set = set(blocked)
    allowed = set(allow)

    def passable(tile: Tile) -> bool:
        return tile in allowed or tile not in blocked_set

    if not passable(start) or not passable(goal):
        return None
    if start == goal:
        return [start]
    queue: list[tuple[int, int, int, int, Tile]] = []
    heappush(queue, (abs(start.x - goal.x) + abs(start.y - goal.y), 0, start.x, start.y, start))
    best = {start: 0}
    parent: dict[Tile, Tile] = {}
    closed: set[Tile] = set()
    visited = 0
    while queue:
        _, cost, _, _, current = heappop(queue)
        if current in closed:
            continue
        if current == goal:
            path = [current]
            while path[-1] in parent:
                path.append(parent[path[-1]])
            path.reverse()
            return path
        closed.add(current)
        visited += 1
        if visited > max_nodes:
            return None
        for dx, dy in NEIGHBOURS:
            nxt = Tile(current.x + dx, current.y + dy)
            if nxt in closed or not passable(nxt):
                continue
            tentative = cost + 1
            if tentative > max_length:
                continue
            if tentative < best.get(nxt, max_length + 1):
                best[nxt] = tentative
                parent[nxt] = current
                heuristic = abs(nxt.x - goal.x) + abs(nxt.y - goal.y)
                heappush(queue, (tentative + heuristic, tentative, nxt.x, nxt.y, nxt))
    return None


def route_directions(path: list[Tile]) -> list[int]:
    directions: list[int] = []
    for index, tile in enumerate(path):
        if index + 1 < len(path):
            directions.append(direction_between(tile, path[index + 1]))
        elif index > 0:
            directions.append(direction_between(path[index - 1], tile))
        else:
            directions.append(EAST)
    return directions


def chain_gap(producer_type: str, consumer_type: str) -> int:
    """Tile gap between module bounds for an eastward physical connection.

    A mining drill drops directly onto a belt. A furnace or assembling machine
    needs an output inserter and/or an input inserter, each occupying one tile.
    Exactly one belt tile sits between the two insertion points.
    """
    output_inserter = producer_type != "mining-drill"
    input_inserter = consumer_type in {"furnace", "assembling-machine"}
    return int(output_inserter) + 1 + int(input_inserter)


def edge_endpoints(
    producer_anchor_x: int,
    producer_width: int,
    consumer_anchor_x: int,
    belt_row: float,
    *,
    direct_output: bool,
    input_inserter: bool,
) -> tuple[Tile, Tile]:
    """Belt source/destination tiles for one eastward item edge."""
    row = int(belt_row // 1)
    source_x = producer_anchor_x + producer_width + (0 if direct_output else 1)
    destination_x = consumer_anchor_x - (2 if input_inserter else 1)
    return Tile(source_x, row), Tile(destination_x, row)
