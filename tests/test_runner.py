import asyncio
import unittest

from factorio_autonomous_engineer.runner import TaskRunner


class FakeBridge:
    def __init__(self, statuses):
        self.statuses = iter(statuses)
        self.calls = []

    def call(self, operation, params=None):
        self.calls.append((operation, params))
        if operation == "task_start":
            return {"ok": True, "result": {"task_id": "task-1"}}
        if operation == "task_status":
            return {"ok": True, "result": next(self.statuses)}
        if operation == "task_cancel":
            return {"ok": True, "result": {"status": "cancelled"}}
        raise AssertionError(operation)


class RunnerTests(unittest.IsolatedAsyncioTestCase):
    async def test_internal_polling_returns_one_terminal_result(self):
        bridge = FakeBridge([
            {"status": "moving", "progress": 0.1},
            {"status": "mining", "progress": 0.5},
            {"status": "succeeded", "success": True, "collected": 100},
        ])
        runner = TaskRunner(bridge, poll_interval=0.1, sleep=lambda _: asyncio.sleep(0))
        result = await runner.execute(
            {"task": "gather_resource", "resource": "iron-ore", "amount": 100})
        self.assertEqual(result["status"], "succeeded")
        self.assertEqual(result["collected"], 100)
        self.assertEqual([c[0] for c in bridge.calls],
                         ["task_start", "task_status", "task_status", "task_status"])

    async def test_emergency_is_returned_without_waiting_for_normal_completion(self):
        bridge = FakeBridge([{"status": "paused",
                              "emergency": {"active": True, "reason": "under_attack"}}])
        runner = TaskRunner(bridge, sleep=lambda _: asyncio.sleep(0))
        result = await runner.execute({"task": "gather_resource"})
        self.assertEqual(result["status"], "interrupted_by_safety")
        self.assertTrue(result["emergency"]["active"])

    async def test_death_is_distinguished_from_nonfatal_emergency(self):
        bridge = FakeBridge([{"status": "paused", "reason": "death",
                              "emergency": {"active": False, "status": "safe"}}])
        runner = TaskRunner(bridge, sleep=lambda _: asyncio.sleep(0))
        result = await runner.execute({"task": "gather_resource"})
        self.assertEqual(result["status"], "interrupted_by_death")

    async def test_terminal_failure_is_forwarded_as_one_result(self):
        bridge = FakeBridge([{"status": "failed", "success": False, "reason": "no_deposits"}])
        runner = TaskRunner(bridge, sleep=lambda _: asyncio.sleep(0))
        result = await runner.execute({"task": "gather_resource"})
        self.assertEqual(result["status"], "failed")
        self.assertEqual(result["reason"], "no_deposits")


class RunnerTerminalStatusTests(unittest.IsolatedAsyncioTestCase):
    async def test_partial_construction_is_terminal(self):
        bridge = FakeBridge([{"status": "partial", "success": False,
                              "built_by_agent": 1, "remaining": 1,
                              "reason": "missing_materials"}])
        runner = TaskRunner(bridge, sleep=lambda _: asyncio.sleep(0))
        result = await runner.execute({"task": "assist_construction"})
        self.assertEqual(result["status"], "partial")
        self.assertEqual(result["remaining"], 1)

    async def test_missing_materials_is_terminal(self):
        bridge = FakeBridge([{"status": "missing_materials", "success": False,
                              "missing_materials": {"stone-furnace": 1}}])
        runner = TaskRunner(bridge, sleep=lambda _: asyncio.sleep(0))
        result = await runner.execute({"task": "assist_construction"})
        self.assertEqual(result["status"], "missing_materials")
        self.assertEqual(result["missing_materials"], {"stone-furnace": 1})

    async def test_blocked_construction_is_terminal(self):
        bridge = FakeBridge([{"status": "blocked", "success": False,
                              "reason": "inventory_full"}])
        runner = TaskRunner(bridge, sleep=lambda _: asyncio.sleep(0))
        result = await runner.execute({"task": "assist_construction"})
        self.assertEqual(result["status"], "blocked")
        self.assertEqual(result["reason"], "inventory_full")


class RunnerConstructionTests(unittest.TestCase):
    def test_runner_can_be_constructed_without_running_event_loop(self):
        runner = TaskRunner(FakeBridge([]))
        self.assertGreater(runner._clock(), 0)


if __name__ == "__main__":
    unittest.main()
