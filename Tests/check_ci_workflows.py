"""Protege la activación de CI y que las pruebas financieras sigan conectadas a ella.

Requiere PyYAML. No sustituye al planificador de GitHub ni a ejecutar las suites.
"""
from pathlib import Path
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
VALIDATIONS = (
    "build-ios-simulator.yml",
    "test-backup.yml",
    "test-banking.yml",
    "test-cloud.yml",
    "test-android.yml",
)
CONCURRENCY = "ci-${{ github.workflow }}-${{ github.event_name }}-${{ github.event.pull_request.number || github.ref }}"


def load_workflow(filename):
    return yaml.safe_load((ROOT / ".github/workflows" / filename).read_text(encoding="utf-8"))


def events(workflow):
    # PyYAML usa YAML 1.1: interpreta el nombre de la clave «on» como booleano.
    return workflow.get("on", workflow.get(True, {}))


def selected(config, event, *, branch="main", action=None):
    """Modelo acotado de los eventos que usamos; rechaza selectores desconocidos."""
    configured = events(config)
    if event not in configured:
        return False
    options = configured[event] or {}
    allowed = {"branches", "tags", "types"}
    if set(options) - allowed:
        raise AssertionError(f"Selector sin comprobar: {options}")
    if event == "push" and branch.startswith("refs/tags/"):
        return options.get("tags") == ["**"]
    if "branches" in options and branch not in options["branches"]:
        return False
    if event == "pull_request":
        return action in options.get("types", ["opened", "synchronize", "reopened"])
    if "types" in options:
        return action in options["types"]
    return True


class CIWorkflowCheck(unittest.TestCase):
    def test_trigger_contract(self):
        scenarios = (
            ("push", "main", None, True),  # merge o push directo
            ("push", "codex/cambio", None, False),
            ("push", "feature/cambio", None, False),
            ("push", "v1.0", None, False),
            ("push", "refs/tags/v1.0", None, True),
            ("pull_request", "main", "opened", True),  # también PR en borrador
            ("pull_request", "main", "synchronize", True),
            ("pull_request", "main", "reopened", True),
            ("pull_request", "release", "synchronize", True),
            ("pull_request", "main", "closed", False),
            ("workflow_dispatch", "codex/cambio", None, True),
            ("merge_group", "main", "checks_requested", True),
        )
        for filename in VALIDATIONS:
            config = load_workflow(filename)
            with self.subTest(workflow=filename):
                self.assertEqual(set(events(config)), {"push", "pull_request", "merge_group", "workflow_dispatch"})
                self.assertEqual(events(config)["push"], {"branches": ["main"], "tags": ["**"]})
                self.assertIsNone(events(config)["pull_request"])
                self.assertEqual(config["permissions"], {"contents": "read"})
                self.assertEqual(config["concurrency"], {"group": CONCURRENCY, "cancel-in-progress": True})
            for event, branch, action, expected in scenarios:
                with self.subTest(workflow=filename, event=event, branch=branch, action=action):
                    self.assertEqual(selected(config, event, branch=branch, action=action), expected)

    def test_every_swift_suite_is_executed(self):
        commands = []
        for filename in VALIDATIONS:
            config = load_workflow(filename)
            for job_id, job in config["jobs"].items():
                with self.subTest(workflow=filename, job=job_id):
                    self.assertNotIn("if", job, "No ocultar una suite mediante condiciones")
                    self.assertFalse(job.get("continue-on-error", False))
                    for step in job.get("steps", []):
                        self.assertFalse(step.get("continue-on-error", False))
                        command = step.get("run", "")
                        if "Tests/" in command or "npm test" in command or "flutter test" in command:
                            self.assertNotIn("if", step, "No saltar pasos de pruebas")
                        commands.append(command)
        all_commands = "\n".join(commands)
        for test in sorted((ROOT / "Tests").glob("*Check.swift")):
            with self.subTest(suite=test.name):
                containing = [command for command in commands if f"Tests/{test.name}" in command]
                self.assertTrue(containing, "La suite existe pero no está conectada a CI")
                self.assertTrue(any(command.strip().splitlines()[-1].strip().startswith("build/") for command in containing),
                                "Compilar una suite no basta: debe ejecutarse")
        for command in ("python3 Tests/check_adaptive_layout.py", "python supabase/tests/test_finance.py",
                        "npm test", "npm run test:integration", "npm audit --audit-level=high", "npm run check",
                        "flutter test", "flutter analyze"):
            with self.subTest(command=command):
                self.assertIn(command, all_commands)

    def test_both_native_configurations_remain(self):
        job = load_workflow("build-ios-simulator.yml")["jobs"]["build"]
        self.assertIs(job["strategy"]["fail-fast"], False)
        combinations = {(row["configuration"], row["sdk"]) for row in job["strategy"]["matrix"]["include"]}
        self.assertTrue({("Debug", "iphonesimulator"), ("Release", "iphoneos")} <= combinations)
        self.assertIn("clean build | tee xcodebuild.log", "\n".join(step.get("run", "") for step in job["steps"]))

if __name__ == "__main__":
    unittest.main(verbosity=2)
