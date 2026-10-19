"""Run with python3 tests/vime_dependencies.py; no downloads or sudo."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


SETUP = Path(__file__).resolve().parents[1] / "nvima/setup-dependencies.sh"
LAUNCHER = SETUP.with_name("launcher.sh")
COMMANDS = "rg git bash ctags node typescript-language-server tsserver go gopls clangd".split()


def executable(path, body):
    path.write_text("#!/bin/sh\n" + body)
    path.chmod(0o755)


class DependencySetup(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="vime dependencies ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.tools = self.root / "system tools"
        self.tools.mkdir()
        (self.tools / "mkdir").symlink_to(shutil.which("mkdir"))
        (self.tools / "dirname").symlink_to(shutil.which("dirname"))
        (self.tools / "sh").symlink_to("/bin/sh")
        self.prefix = self.root / "private tools"
        self.calls = self.root / "calls.json"
        self.manager = self.root / "package manager"
        self.manager.write_text(
            f"#!{sys.executable}\n"
            "import json, pathlib, sys\n"
            f"pathlib.Path({str(self.calls)!r}).write_text(json.dumps(sys.argv[1:]))\n"
            "sys.exit(0)\n"
        )
        self.manager.chmod(0o755)

    def supply(self, directory, commands=COMMANDS):
        directory.mkdir(parents=True, exist_ok=True)
        for command in commands:
            executable(directory / command, "printf 'json enabled\\n'\n" if command == "ctags" else "exit 0\n")

    def run_setup(self):
        return subprocess.run(
            ["/bin/sh", str(SETUP), str(self.prefix), str(self.manager)],
            env={**os.environ, "PATH": str(self.tools)},
            text=True, capture_output=True, check=False,
        )

    def test_fresh_install_covers_editor_tools_and_runtimes(self):
        result = self.run_setup()
        self.assertEqual(result.returncode, 0, result.stderr)
        args = json.loads(self.calls.read_text())
        self.assertIn("create", args)
        self.assertEqual(args[args.index("--prefix") + 1], str(self.prefix))
        for package in ("ripgrep", "git", "bash", "universal-ctags", "nodejs>=24,<27",
                        "typescript-language-server>=6,<7", "typescript>=6,<7", "go", "gopls", "clang-tools"):
            self.assertIn(package, args)
        self.assertIn("--no-rc", args)
        self.assertIn("--override-channels", args)

    def test_existing_tools_need_no_network_or_manager(self):
        self.supply(self.tools)
        self.manager.unlink()
        result = self.run_setup()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.calls.exists())

    def test_installed_private_tools_are_reused(self):
        self.supply(self.prefix / "bin")
        self.manager.unlink()
        self.assertEqual(self.run_setup().returncode, 0)
        self.assertFalse(self.calls.exists())

    def test_partial_install_is_repaired(self):
        self.supply(self.tools, [key for key in COMMANDS if key != "gopls"])
        (self.prefix / "conda-meta").mkdir(parents=True)
        (self.prefix / "conda-meta/history").touch()
        self.assertEqual(self.run_setup().returncode, 0)
        args = json.loads(self.calls.read_text())
        self.assertIn("install", args)
        self.assertEqual(args[-1], "gopls")
        self.assertNotIn("clang-tools", args)

    def test_old_node_and_non_json_ctags_are_replaced(self):
        self.supply(self.tools)
        executable(self.tools / "node", "exit 1\n")
        executable(self.tools / "ctags", "exit 1\n")
        self.assertEqual(self.run_setup().returncode, 0)
        args = json.loads(self.calls.read_text())
        self.assertIn("nodejs>=24,<27", args)
        self.assertIn("universal-ctags", args)

    def test_failed_install_can_retry(self):
        executable(self.manager, "exit 1\n")
        self.assertNotEqual(self.run_setup().returncode, 0)
        self.supply(self.tools)
        self.assertEqual(self.run_setup().returncode, 0)

    def launch(self, args, **options):
        payload = self.root / "cache/nvima-portable/test"
        (payload / "nvim/bin").mkdir(parents=True, exist_ok=True)
        (payload / "config").mkdir(exist_ok=True)
        editor = payload / "nvim/bin/nvim"
        editor.write_text(
            f"#!{sys.executable}\nimport json, os, sys\n"
            'if "--require-activation" in sys.argv:\n'
            '    assert os.environ.get("CONDA_PREFIX", "").endswith("vime/dependencies")\n'
            "print(json.dumps(sys.argv[1:]))\n"
        )
        editor.chmod(0o755)
        executable(payload / "config/setup-dependencies.sh", 'printf called >"$1.called"\nexit 1\n')
        manager = payload / "config/micromamba"
        manager.write_text(
            f"#!{sys.executable}\nimport os, sys\n"
            'args = sys.argv[1:]\nassert "run" in args\n'
            'assert args[args.index("--attach") + 1] == ""\n'
            'index = args.index("--prefix")\n'
            'os.environ["CONDA_PREFIX"] = args[index + 1]\n'
            'os.execv(args[index + 2], args[index + 2:])\n'
        )
        manager.chmod(0o755)
        launcher = self.root / "vime-launcher"
        launcher.write_text(LAUNCHER.read_text().replace("@PAYLOAD_ID@", "test"))
        return subprocess.run(
            ["/bin/sh", str(launcher), *args],
            env={**os.environ, "PATH": str(self.tools),
                 "XDG_CACHE_HOME": str(self.root / "cache"),
                 "XDG_DATA_HOME": str(self.root), **options},
            capture_output=True, text=True, check=False,
        )

    def test_launcher_opens_editor_after_setup_failure_and_keeps_arguments(self):
        # mkdir in the fixture setup script normally creates this directory.
        (self.root / "vime").mkdir()
        result = self.launch(["--headless", "a file.ts", "+qa!"])
        self.assertEqual(result.returncode, 0, result.stderr)
        args = json.loads(result.stdout)
        self.assertEqual(args[-3:], ["--headless", "a file.ts", "+qa!"])
        self.assertIn("retry next launch", result.stderr)
        self.assertTrue((self.root / "vime/dependencies.called").exists())

    def test_launcher_help_and_version_do_not_install(self):
        for arg in ("--help", "--version"):
            result = self.launch([arg])
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stderr, "")
        self.assertFalse((self.root / "vime/dependencies.called").exists())

    def test_launcher_install_opt_out(self):
        result = self.launch(["test.ts"], VIME_INSTALL_DEPS="0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        self.assertFalse((self.root / "vime/dependencies.called").exists())

    def test_launcher_activates_private_environment_for_package_wrappers(self):
        metadata = self.root / "vime/dependencies/conda-meta"
        metadata.mkdir(parents=True)
        (metadata / "history").touch()
        result = self.launch(["--require-activation"], VIME_INSTALL_DEPS="0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--require-activation", json.loads(result.stdout))


if __name__ == "__main__":
    unittest.main()
