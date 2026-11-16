# Movement Controller

`lib/movement.lua` owns all autonomous locomotion for the agent. It is the only production module
that writes `walking_state`. Tasks submit destination intents and observe status; they do not write
waypoints or walking directions. Every route uses Factorio's pathfinder and ordinary character
walking. Production movement and recovery never teleport the character.

## Intent and callback ownership

Each intent has a new movement ID, owner task ID, generation, original destination, waypoint index,
retry/recovery counters and persistent progress samples. A path request records its engine request
ID, movement ID and generation. A callback is accepted only when all three still match and the
intent is `path_pending`; superseded, duplicate or late callbacks are counted and ignored.

Task completion and cancellation stop ordinary movement and release the primary intent. A new task
therefore receives fresh task and movement identities. Safety creates a separate emergency intent,
interrupts the ordinary intent and retains priority until the emergency is released. Death cancels
both classes of intent.

## Belt rules

Standing on a belt is not itself a recovery condition.

- If the destination is already within arrival tolerance, the intent arrives without stepping off.
- Before a route starts, the controller compares belt direction with the intended route. An aligned
  ride is allowed.
- When a path callback arrives, alignment uses the first waypoint outside normal waypoint arrival
  tolerance—the waypoint the follower would actually command next. This skips a path point that the
  belt has already carried the character past. A final-destination fallback is used when no such
  waypoint remains.
- While following a path, bounded progress samples compare actual displacement with the commanded
  walking direction. Recovery starts when the belt carries the character in a conflicting direction;
  valid progress and ordinary belt crossings are not recovery events.

A belt recovery selects a bounded, collision-free destination that is not on another belt, is outside
construction ghosts and is not occupied by another character. The step-off destination keeps a
1.2-tile belt-free margin, because a path request only has to deliver the character within one tile of
its goal: without that margin the returned path can end on another belt tile and the step-off could
never complete. The original destination, target entity and arrival tolerance are saved. The
controller walks to the step-off destination through a new pathfinder request, verifies the
character's actual position is no longer on a belt, restores the original target and requests a fresh
path. Arrival tolerance alone cannot complete recovery while the character is still on a belt.

Repeated step-offs are bounded by progress, not only by a counter. Each intent compares the remaining
distance at the start of a belt recovery with the previous one; after three recoveries that did not
shorten the route by at least a tile, the controller stops stepping off and follows the ordinary
route across the belt. A larger belt field can then be crossed instead of being re-entered forever.
Retry and replan counts are bounded; recovery never teleports.

## Invalid-position recovery

A belt can carry a character into a position whose collision box clips a belt tile. The engine still
lets the character walk, but the pathfinder refuses to plan from a non-placeable start and returns an
empty path. The controller detects that case through the engine's nearest free character position
(`can_place_entity{name = "character"}` cannot be used: the character's own body occupies its
position). An empty path from such a position starts a bounded `invalid_position` step-out instead of
counting the destination as unreachable; the character walks toward the engine's nearest free
position and then re-requests the original route. This is a normal-walking recovery with the same
bounded attempt count as the other recovery reasons.

## Ghost recovery

Construction ghosts do not collide with the character. The task layer does not repeatedly replace a
path request merely because one overlaps the character. The Movement Controller handles a ghost at
route start or an actual progress stall, and construction can explicitly request a step-out when a
large module footprint must be cleared before revival. Step-outs use normal walking and restore the
original target before routing resumes.

When the executor finds the character inside the target ghost footprint, it must hand the step-out to
the controller (`movement.recover`, then task phase `recovering`) and wait for it. Stopping movement
and re-targeting the same approach point every tick cancels the recovery before it can move, which
was observed as a ghost-recovery/path-request storm that ended only at the task deadline. The
approach ring in `construction.approach_for_entity` starts at `footprint_half_extent + 1.5` (never
below 2.6), so an ordinary arrival cannot leave the character inside the target footprint.

## Save/load and diagnostics

Path engine handles and waypoint arrays are not trusted after load. Pending, following, waiting and
recovering intents return to `idle` for a fresh request. If load occurs during recovery, the saved
original destination and target metadata are restored first; transient step-off fields are cleared.
Task deadlines and persistent counters remain in `storage`.

Internal RCON diagnostics expose bounded counters for requests, completed callbacks, accepted paths,
stale callbacks, retries, recoveries, arrivals and actual sampled distance. They are not MCP tools
and do not expose movement micro-actions to the model. Engine scenarios use transition/periodic
summaries rather than per-tick logging.
