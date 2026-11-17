"""Source-level contract tests for the Stage-7.1 Movement Controller.

These tests cannot prove in-game behaviour (``tests/engine/`` does that with a real
Factorio server). They pin the architectural invariants that a refactor could break
silently: the single ``walking_state`` writer, the absence of teleportation, the
generation-checked path callback, bounded recovery, the instruction that a task must
delegate an inside-ghost step-out to the controller instead of cancelling it, and the
unchanged construction/logistics deadlines.
"""
from __future__ import annotations

import re
from pathlib import Path

MOD_ROOT = Path(__file__).resolve().parents[1] / "mod" / "factorio_autonomous_engineer"
LIB = MOD_ROOT / "lib"

MOVEMENT = (LIB / "movement.lua").read_text(encoding="utf-8")
TASKS = (LIB / "tasks.lua").read_text(encoding="utf-8")
SCHEDULER = (LIB / "work_scheduler.lua").read_text(encoding="utf-8")
CONSTRUCTION = (LIB / "construction.lua").read_text(encoding="utf-8")
SAFETY = (LIB / "safety.lua").read_text(encoding="utf-8")
CONTROL = (MOD_ROOT / "control.lua").read_text(encoding="utf-8")


def lua_sources() -> dict[str, str]:
    return {
        path.relative_to(MOD_ROOT).as_posix(): path.read_text(encoding="utf-8")
        for path in sorted(MOD_ROOT.rglob("*.lua"))
    }


def block_after(text: str, marker: str, *, span: int = 900) -> str:
    index = text.index(marker)
    return text[index:index + span]


def test_only_movement_module_writes_walking_state():
    writers = sorted(
        name for name, source in lua_sources().items()
        if re.search(r"\.walking_state\s*=", source)
    )
    assert writers == ["lib/movement.lua"]


def code_without_comments(source: str) -> str:
    """Drop Lua line comments so documentation prose cannot satisfy a code check."""
    return "\n".join(line.split("--", 1)[0] for line in source.splitlines())


def test_production_movement_never_teleports():
    # Counter names such as step_out_teleports and prose comments mention the word;
    # only an actual engine call would move the character.
    call = re.compile(r"\.teleport\s*\(")
    offenders = {
        name: len(call.findall(code_without_comments(source)))
        for name, source in lua_sources().items()
        if call.search(code_without_comments(source))
    }
    assert offenders == {}


def test_path_callback_is_generation_checked():
    callback = block_after(MOVEMENT, "function M.path_finished", span=700)
    assert "event.id ~= request.id" in callback
    assert "intent.generation ~= request.generation" in callback
    assert 'intent.state ~= "path_pending"' in callback
    assert "stale_path_callbacks" in callback


def test_path_requests_are_single_flight_and_retries_bounded():
    request = block_after(MOVEMENT, "local function request_path", span=900)
    assert "if movement.path_request then return false end" in request
    assert "TRY_AGAIN_LIMIT" in MOVEMENT
    assert "NO_PATH_RETRY_LIMIT" in MOVEMENT
    assert "PATH_TIMEOUT_TICKS" in MOVEMENT
    # try_again_later must not be honoured without a bound.
    assert "intent.try_again_count > TRY_AGAIN_LIMIT" in MOVEMENT


def test_recovery_attempts_are_bounded_and_reported():
    assert "local RECOVERY_LIMIT = 6" in MOVEMENT
    assert "intent.recovery_count > RECOVERY_LIMIT" in MOVEMENT
    for reason in ('"belt_displacement"', '"ghost_obstruction"', '"invalid_position"',
                   '"recovery_complete"'):
        assert reason in MOVEMENT


def test_belt_step_off_is_stand_only():
    # Travel crosses belts; stand intents recover only when they must remain at a
    # belt-covered or belt-adjacent destination.
    assert "belt_aligned" not in MOVEMENT
    assert "belt_recovery_useful" not in MOVEMENT
    assert "stand = spec.stand == true" in MOVEMENT
    resolve = block_after(MOVEMENT, "local function resolve_arrival", span=800)
    assert "intent.stand and not intent.recovery" in resolve
    assert "BELT_EXIT_CLEARANCE" in resolve
    assert 'enter_recovery(movement, intent, agent, "belt")' in resolve
    assert "return false" in resolve
    callers = MOVEMENT.count("if resolve_arrival(movement, intent, agent) == false then")
    assert callers == 4
    assert "find_safe_recovery_positions" in MOVEMENT
    assert "BELT_EXIT_SEARCH_RADIUS = 32" in MOVEMENT
    assert "BELT_EXIT_CLEARANCE = 1.25" in MOVEMENT
    assert "BELT_EXIT_CANDIDATE_CLEARANCE" in MOVEMENT
    assert "WAYPOINT_TOLERANCE + BELT_EXIT_PATH_RADIUS" in MOVEMENT
    assert "step_out_use_path = true" in MOVEMENT
    assert "request_next_belt_exit_path" in MOVEMENT
    assert '"belt_exit_unreachable"' in MOVEMENT
    candidates = block_after(MOVEMENT, "local function find_safe_recovery_positions", span=2600)
    assert "return result" in candidates
    assert "or position_copy(start)" not in candidates
    stuck = block_after(MOVEMENT, "local function check_stuck", span=1000)
    assert 'enter_recovery(movement, intent, agent, "belt")' not in stuck
    assert "DIRECTION_VECTORS" not in MOVEMENT
    assert "BELT_STEP_OFF_GRACE_TICKS" not in MOVEMENT
    assert "belt_step_off_until" not in MOVEMENT
    callback = block_after(MOVEMENT, "function M.path_finished", span=3000)
    assert "belt_exit_no_path" in callback
    assert "belt_exit_stale_paths" in callback
    idle = block_after(MOVEMENT, 'if intent.state == "idle" then', span=700)
    assert 'enter_recovery(movement, intent, agent, "belt")' not in idle
    assert 'stand = options.stand == true' in TASKS
    assert 'stand = kind ~= "travel"' in TASKS
    assert "stand = false" in TASKS


def test_belt_exit_uses_engine_pathfinder_and_keeps_a_stable_candidate():
    recovery = block_after(MOVEMENT, "local function enter_recovery", span=2800)
    assert "find_safe_recovery_positions" in recovery
    assert "return request_next_belt_exit_path" in recovery
    request = block_after(MOVEMENT, "local function request_next_belt_exit_path", span=1700)
    assert "request_path(movement, intent, agent)" in request
    assert "intent.destination = position_copy(candidate)" in request
    assert "step_out_use_path = true" in request
    assert "local BELT_EXIT_STALE_START_DISTANCE = 1.0" in MOVEMENT
    assert "belt_exit_stale_start" in MOVEMENT
    assert "belt_exit_candidate_reached" in MOVEMENT
    assert "belt_exit_no_progress" in MOVEMENT
    progress = block_after(MOVEMENT, "local function check_belt_exit_progress", span=1300)
    assert "STUCK_WINDOW_TICKS" in progress
    assert "belt_exit_progress_distance" in progress
    assert "stop_walking(agent, movement)" in progress
    callback = block_after(MOVEMENT, "function M.path_finished", span=900)
    assert "finish_recovery(movement, intent, mover)" in callback
    assert "BELT_EXIT_CLEARANCE" in callback
    follow = block_after(MOVEMENT, "local function follow", span=2200)
    assert "belt_exit_candidate_reached" in follow
    finish = block_after(MOVEMENT, "local function finish_recovery", span=1200)
    assert '"belt_target_redirected"' in finish
    assert "resume_original" in finish



def test_invalid_character_position_is_recovered_before_pathing():
    # The pathfinder refuses to plan from a position the engine reports as
    # non-placeable (a belt can carry the character into such a spot), so the
    # controller must step out instead of treating the target as unreachable.
    assert "local function character_position_is_free(agent)" in MOVEMENT
    assert 'not character_position_is_free(mover)' in MOVEMENT
    assert 'enter_recovery(movement, intent, mover, "position")' in MOVEMENT
    # The recovery window uses one free-position probe per tick.
    assert "if kind == \"belt\" then" in MOVEMENT
    assert "on = not character_position_is_free(agent)" in MOVEMENT


def test_task_delegates_inside_ghost_step_out_to_movement():
    marker = "if position_inside_box(agent.position, ghost.bounding_box) then"
    start = TASKS.index(marker)
    stop = TASKS.index("local ok, reason, entity, proxy = construction.build", start)
    head = TASKS[start:stop]
    assert head, "the inside-ghost branch must precede the paid build call"
    assert 'movement.recover(s, task.id, "ghost")' in head
    assert 'task.phase, task.phase_started_tick = "recovering"' in head
    # Falling back to a cancelled intent is only allowed after a bounded number of
    # failed hand-offs; stopping first would make the recovery impossible.
    recover_index = head.index("movement.recover")
    stop_index = head.find("stop_character")
    assert recover_index < stop_index
    assert "step_out_attempts" in head[recover_index:stop_index]
    assert '"movement_recovery_failed"' in head


def test_work_scheduler_never_moves_the_character():
    code = code_without_comments(SCHEDULER)
    assert not re.search(r"walking_state\s*=", code)
    assert ".request_path" not in code
    assert 'require("lib.movement")' in SCHEDULER


def test_safety_preempts_ordinary_movement_through_the_controller():
    assert "movement.interrupt_primary(s, " in SAFETY
    assert "movement.emergency(s, {" in SAFETY
    assert not re.search(r"walking_state\s*=", code_without_comments(SAFETY))


def test_single_path_callback_consumer():
    assert "movement.path_finished(s, event)" in CONTROL
    callbacks = CONTROL.count("on_script_path_request_finished")
    assert callbacks == 1


def test_construction_deadlines_are_not_inflated():
    assert "local CONSTRUCTION_BASE_TICKS = 60 * 60 * 5" in TASKS
    assert "local CONSTRUCTION_TICKS_PER_GHOST = 60 * 30" in TASKS
    assert "local LOGISTICS_DEADLINE_TICKS = 60 * 60 * 30" in TASKS
    # 18000 + 4 * 1800 = 25200 construction ticks; 108000 logistics ticks.
    assert "CONSTRUCTION_BASE_TICKS + 4 * CONSTRUCTION_TICKS_PER_GHOST" in TASKS
    assert "task.deadline_ticks = LOGISTICS_DEADLINE_TICKS" in TASKS


def test_approach_point_is_outside_the_target_footprint():
    approach = block_after(CONSTRUCTION, "function M.approach_for_entity", span=1400)
    assert "local inside = candidate.x > box.left_top.x - 0.25" in approach
    assert "if not inside and surface.can_place_entity{" in approach
