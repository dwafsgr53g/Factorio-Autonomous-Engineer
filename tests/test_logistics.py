"""Fast unit tests for the Stage-6 deterministic logistics geometry."""
from __future__ import annotations

from factorio_autonomous_engineer.logistics import (
    EAST,
    NORTH,
    SOUTH,
    WEST,
    Tile,
    chain_gap,
    direction_between,
    edge_endpoints,
    plan_route,
    route_directions,
    tile_center,
    tile_of,
)


def test_tile_conversion_and_centers():
    assert tile_of(21.5, -16.5) == Tile(21, -17)
    assert tile_center(Tile(21, -17)) == (21.5, -16.5)


def test_direction_between_is_cardinal():
    assert direction_between(Tile(0, 0), Tile(1, 0)) == EAST
    assert direction_between(Tile(0, 0), Tile(-1, 0)) == WEST
    assert direction_between(Tile(0, 0), Tile(0, -1)) == NORTH
    assert direction_between(Tile(0, 0), Tile(0, 1)) == SOUTH


def test_straight_route_is_deterministic():
    path = plan_route(set(), Tile(0, 0), Tile(4, 0))
    assert path == [Tile(x, 0) for x in range(5)]
    assert route_directions(path) == [EAST] * 5


def test_turning_route_and_obstacle_avoidance():
    blocked = {Tile(2, 0), Tile(2, 1)}
    path = plan_route(blocked, Tile(0, 0), Tile(4, 0))
    assert path is not None
    assert Tile(2, 0) not in path and Tile(2, 1) not in path
    directions = route_directions(path)
    assert EAST in directions and (NORTH in directions or SOUTH in directions)


def test_route_around_wall_has_expected_length_and_cost():
    wall = {Tile(3, y) for y in range(-1, 2)}
    path = plan_route(wall, Tile(0, 0), Tile(6, 0), max_length=40)
    assert path is not None
    assert len(path) == 11  # two extra steps south and two back north
    assert all(tile not in wall for tile in path)


def test_blocked_start_goal_and_no_path():
    assert plan_route({Tile(0, 0)}, Tile(0, 0), Tile(3, 0)) is None
    assert plan_route({Tile(3, 0)}, Tile(0, 0), Tile(3, 0)) is None
    enclosed = {Tile(1, 0), Tile(-1, 0), Tile(0, 1), Tile(0, -1)}
    assert plan_route(enclosed, Tile(0, 2), Tile(0, 0)) is None


def test_allow_overrides_blocked_endpoints_only():
    blocked = {Tile(0, 0), Tile(2, 0)}
    path = plan_route(blocked, Tile(0, 0), Tile(2, 0),
                      allow={Tile(0, 0), Tile(2, 0)})
    assert path is not None
    assert path[0] == Tile(0, 0) and path[-1] == Tile(2, 0)


def test_route_does_not_mutate_blocked_input():
    blocked = {Tile(1, 0)}
    snapshot = set(blocked)
    plan_route(blocked, Tile(0, 0), Tile(2, 0))
    assert blocked == snapshot


def test_route_budget_is_bounded():
    assert plan_route(set(), Tile(0, 0), Tile(30, 30), max_nodes=8) is None
    assert plan_route(set(), Tile(0, 0), Tile(30, 0), max_length=10) is None


def test_chain_gap_matches_physical_insertion_geometry():
    assert chain_gap("mining-drill", "furnace") == 2
    assert chain_gap("furnace", "assembling-machine") == 3
    assert chain_gap("assembling-machine", "furnace") == 3


def test_edge_endpoints_align_on_the_declared_belt_row():
    source, goal = edge_endpoints(18, 3, 23, -16.5, direct_output=True,
                                  input_inserter=True)
    assert source == Tile(21, -17)
    assert goal == Tile(21, -17)
    source, goal = edge_endpoints(23, 2, 28, -16.5, direct_output=False,
                                  input_inserter=True)
    assert source == Tile(26, -17)
    assert goal == Tile(26, -17)
    source, goal = edge_endpoints(23, 2, 28, -16.5, direct_output=False,
                                  input_inserter=False)
    assert source == Tile(26, -17)
    assert goal == Tile(27, -17)
