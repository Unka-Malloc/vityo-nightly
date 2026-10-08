"""Exercise the editor smoke-test lifecycle with deterministic browser boundaries."""
import pathlib
import subprocess
import unittest


class EditorSelftestLifecycleTest(unittest.TestCase):
    def test_node_lifecycle_cases(self):
        root = pathlib.Path(__file__).resolve().parent
        result = subprocess.run(
            ["node", "--test", "scripts/check-editor-load.test.mjs"],
            cwd=root, capture_output=True, text=True, timeout=30, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
