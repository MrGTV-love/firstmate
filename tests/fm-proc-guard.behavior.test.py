#!/usr/bin/env python3
import ctypes
import importlib.util
import io
import json
import os
from pathlib import Path
import resource
import sys
import tempfile
import unittest
from contextlib import ExitStack, contextmanager
from types import SimpleNamespace
from unittest.mock import patch


ENGINE = Path(__file__).resolve().parents[1] / "bin" / "fm-proc-guard.py"
spec = importlib.util.spec_from_file_location("fm_proc_guard", ENGINE)
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


class Output(io.StringIO):
    def reconfigure(self, **kwargs):
        pass


def invoke(source, *args):
    out = Output()
    with patch.object(guard, "open_source", return_value=source), \
            patch.object(sys, "argv", [str(ENGINE), *args]), \
            patch.object(sys, "stdout", out):
        guard.main()
    return out.getvalue()


class Clock:
    def __init__(self):
        self.now = 0.0

    def monotonic(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds


class Source:
    name = "controlled"
    uid = 1234

    def __init__(self, counts):
        self.counts = iter(counts)
        self.last = 0

    def limit(self):
        return 100, "controlled per-user limit"

    def count(self):
        self.last = next(self.counts, self.last)
        if isinstance(self.last, Exception):
            raise self.last
        return self.last

    def pids(self):
        return [11, 12, 13]

    def info(self, pid):
        if pid not in self.pids():
            return None
        return guard.Proc(pid, pid - 1 if pid > 11 else 0, "bash", "R", 100 + pid, 1)

    def identifier(self, pid):
        return guard.process_identifier(
            b"/bin/bash", [b"bash", b"/private/path/nest.sh", b"--user", b"alice:secret"])


@contextmanager
def proc_fixture():
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        target = os.getuid() + 1000
        rows = [(101, target, 0, 4), (102, target + 1, target, 7)]
        for pid, real, effective, threads in rows:
            directory = root / str(pid)
            directory.mkdir()
            (directory / "status").write_text(
                "Name:\tbash\nUid:\t%d\t%d\t%d\t%d\n" %
                (real, effective, effective, effective))
            fields = ["0"] * 20
            fields[0], fields[1], fields[17], fields[19] = "R", "0", str(threads), "100"
            (directory / "stat").write_text("%d (bash) %s\n" % (pid, " ".join(fields)))
            (directory / "cmdline").write_bytes(
                b"bash\0/private/alice:secret/nest.sh\0--user\0alice:secret\0")
            (directory / "exe").symlink_to("/bin/bash")
        for pid, status in [(103, "Uid:\tbroken\n"), (104, "Uid:\n"), (105, "Name:\tgone\n")]:
            directory = root / str(pid)
            directory.mkdir()
            (directory / "status").write_text(status)
        (root / "106").mkdir()
        (root / "stat").write_text("btime 1000\n")
        (root / "sys" / "kernel").mkdir(parents=True)
        (root / "sys" / "kernel" / "threads-max").write_text("99999\n")
        real_open, real_scandir, real_readlink = open, os.scandir, os.readlink
        opened = []

        def mapped(path):
            text = os.fspath(path)
            return root / text[len("/proc/"):] if text.startswith("/proc/") else path

        def fixture_open(path, *args, **kwargs):
            opened.append(os.fspath(path))
            return real_open(mapped(path), *args, **kwargs)

        with ExitStack() as stack:
            stack.enter_context(patch("builtins.open", side_effect=fixture_open))
            stack.enter_context(patch.object(guard.os, "scandir", side_effect=lambda path: real_scandir(
                root if os.fspath(path) == "/proc" else path)))
            stack.enter_context(patch.object(guard.os, "readlink", side_effect=lambda path: real_readlink(mapped(path))))
            source = guard.Linux()
            source.uid = target
            yield source, root, opened


class GuardBehavior(unittest.TestCase):
    def test_real_uid_selection_reaches_count_check_and_census(self):
        with proc_fixture() as (source, root, _), \
                patch.object(guard.resource, "getrlimit", return_value=(100, 100)):
            self.assertNotEqual((root / "101").stat().st_uid, source.uid)
            self.assertEqual(source.pids(), [101])
            self.assertEqual(source.count(), 4)
            report = json.loads(invoke(source, "check", "--json"))
            self.assertEqual((report["count"], report["status"]), (4, "OK"))
            census_path = invoke(source, "census", "--state-dir", str(root / "state")).strip()
            census = json.loads(Path(census_path).read_text())
            self.assertEqual(census["user_process_count"], 4)
            self.assertEqual(census["census_processes"], 1)
            self.assertEqual([entry["pid"] for entry in census["newest"]], [101])
            source.uid = os.getuid()
            self.assertEqual(source.pids(), [])
            self.assertEqual(source.count(), 0)

    def test_unlimited_is_unknown_without_reading_system_limit(self):
        with proc_fixture() as (source, root, opened), \
                patch.object(guard.resource, "getrlimit", return_value=(resource.RLIM_INFINITY, resource.RLIM_INFINITY)):
            report = json.loads(invoke(source, "check", "--json", "--check"))
            self.assertEqual(report["status"], "UNKNOWN")
            self.assertIsNone(report["limit"])
            self.assertIn("unlimited", report["reason"])
            self.assertEqual(report["count"], 4)
            state = root / "watch"
            result = invoke(source, "watch", "--state-dir", str(state))
            self.assertIn("status: error\n", result)
            self.assertIn("unlimited", result)
            self.assertFalse(state.exists())
            census_path = invoke(source, "census", "--state-dir", str(root / "census")).strip()
            census = json.loads(Path(census_path).read_text())
            for field in ("limit", "threshold", "percent_of_limit"):
                self.assertIsNone(census[field])
            self.assertEqual(census["user_process_count"], 4)
            self.assertNotIn("/proc/sys/kernel/threads-max", opened)
            report = json.loads(invoke(source, "check", "--json", "--limit", "5"))
            self.assertEqual((report["limit_source"], report["status"]), ("--limit", "WARNING"))
            self.assertEqual(report["percent_of_limit"], 80.0)
            census_path = invoke(source, "census", "--limit", "5", "--state-dir", str(root / "override")).strip()
            census = json.loads(Path(census_path).read_text())
            self.assertEqual((census["limit"], census["threshold"]), (5, 3.0))
            clock = Clock()
            with patch.object(guard.time, "monotonic", clock.monotonic), \
                    patch.object(guard.time, "sleep", clock.sleep):
                result = invoke(source, "watch", "--limit", "5", "--state-dir", str(state), "--hold", "1")
            self.assertIn("status: pileup\n", result)
            self.assertTrue((state / "proc-guard.episode").is_file())

    def test_linux_census_retains_identifiers_not_arguments(self):
        with proc_fixture() as (source, root, _):
            census_path = invoke(source, "census", "--limit", "100", "--state-dir", str(root / "state")).strip()
            persisted = Path(census_path).read_text()
            self.assertNotIn("alice:secret", persisted)
            self.assertNotIn("--user", persisted)
            census = json.loads(persisted)
            self.assertEqual(census["schema"], 2)
            self.assert_identifiers(census)

    def test_linux_reader_excludes_inline_code_modules_and_credentials(self):
        cases = [
            ("/bin/bash", [b"bash", b"-c", b"echo alice:secret"]),
            ("/usr/bin/python3", [b"python", b"-m", b"alice:secret"]),
            ("/usr/bin/curl", [b"curl", b"--user", b"alice:secret"]),
        ]
        with proc_fixture() as (source, root, _):
            for executable, argv in cases:
                with self.subTest(executable=executable):
                    (root / "101" / "exe").unlink()
                    (root / "101" / "exe").symlink_to(executable)
                    (root / "101" / "cmdline").write_bytes(b"\0".join(argv) + b"\0")
                    path = invoke(source, "census", "--limit", "100", "--state-dir", str(root / "state")).strip()
                    persisted = Path(path).read_text()
                    self.assertNotIn("alice:secret", persisted)
                    self.assertNotIn("--user", persisted)
                    self.assert_identifiers(json.loads(persisted), Path(executable).name, "")

    def test_darwin_census_retains_identifiers_not_arguments(self):
        source = guard.Darwin.__new__(guard.Darwin)
        source.uid = 1234
        source.args_buffer = ctypes.create_string_buffer(512)
        processes = Source([3])
        source.pids, source.info = processes.pids, processes.info
        raw = b""
        cases = [
            (b"/bin/bash", [b"bash", b"/private/alice:secret/nest.sh", b"--user", b"alice:secret"], "nest.sh"),
            (b"/bin/bash", [b"bash", b"-c", b"echo alice:secret"], ""),
            (b"/usr/bin/python3", [b"python", b"-m", b"alice:secret"], ""),
            (b"/usr/bin/curl", [b"curl", b"--user", b"alice:secret"], ""),
        ]

        def sysctl(mib, count, buffer, size, new, new_size):
            buffer.raw = raw.ljust(ctypes.sizeof(buffer), b"\0")
            size._obj.value = len(raw)
            return 0

        source.libc = SimpleNamespace(sysctl=sysctl)
        for executable, argv, script in cases:
            with self.subTest(executable=executable, argv=argv):
                raw = len(argv).to_bytes(4, sys.byteorder) + executable + b"\0\0" + b"\0".join(argv) + b"\0"
                census = guard.build_census(source, 3, 100, "controlled", 60, {"reason": "requested"})
                with tempfile.TemporaryDirectory() as state:
                    persisted = Path(guard.write_census(state, census)).read_text()
                self.assertNotIn("alice:secret", persisted)
                self.assertNotIn("--user", persisted)
                self.assert_identifiers(json.loads(persisted), os.fsdecode(os.path.basename(executable)), script)

    def assert_identifiers(self, census, executable="bash", script="nest.sh"):
        entries = list(census["oldest"]) + list(census["newest"])
        for chain in census["deepest_chains"]:
            entries.append(chain["leaf"])
            entries.extend(chain["run_samples"])
        self.assertTrue(entries)
        for entry in entries:
            self.assertNotIn("argv", entry)
            self.assertEqual(entry["executable"], executable)
            self.assertEqual(entry["script"], script)

    def test_inline_code_and_non_interpreter_arguments_are_not_scripts(self):
        for executable, argv in [
                (b"/bin/bash", [b"bash", b"-c", b"echo alice:secret"]),
                (b"/usr/bin/python3.12", [b"python", b"-c", b"alice:secret"]),
                (b"/usr/bin/python3.12", [b"python", b"-m", b"alice:secret"]),
                (b"/usr/bin/curl", [b"curl", b"--user", b"alice:secret"]),
                (b"/usr/bin/curl", [b"curl", b"https://alice:secret@example.com"]),
                (b"", [b"alice:secret"])]:
            with self.subTest(executable=executable, argv=argv):
                identifier = guard.process_identifier(executable, argv)
                self.assertEqual(identifier["script"], "")
                self.assertNotIn("alice:secret", json.dumps(identifier))
        identifier = guard.process_identifier(b"/usr/bin/python3.12", [b"python", b"/private/nest.py", b"alice:secret"])
        self.assertEqual(identifier, {"executable": "python3.12", "script": "nest.py"})

    def test_check_boundary_and_census_threshold_are_fixed(self):
        for count, expected in [(60, "OK"), (61, "WARNING"), (90, "WARNING"), (91, "CRITICAL")]:
            with self.subTest(count=count):
                report = json.loads(invoke(Source([count]), "check", "--json"))
                self.assertEqual(report["status"], expected)
        with tempfile.TemporaryDirectory() as state:
            path = invoke(Source([60]), "census", "--state-dir", state).strip()
            census = json.loads(Path(path).read_text())
            self.assertEqual(census["threshold"], 60.0)

    def watch(self, state, counts, episode=None, duration=10):
        clock = Clock()
        args = ["watch", "--state-dir", str(state), "--hold", "1", "--interval", "1", "--duration", str(duration)]
        if episode is not None:
            args += ["--episode-file", str(episode)]
        with patch.object(guard.time, "monotonic", clock.monotonic), \
                patch.object(guard.time, "sleep", clock.sleep):
            return invoke(Source(counts), *args)

    def test_watch_warning_boundary_and_hold_reset(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            result = self.watch(root / "equal", [60], duration=4)
            self.assertIn("status: idle\n", result)
            self.assertFalse((root / "equal").exists())
            result = self.watch(root / "above", [61, 61, 61])
            self.assertIn("status: pileup\n", result)
            self.assertIn("threshold: 60\n", result)
            result = self.watch(root / "dip", [61, 60, 61, 61, 61])
            self.assertIn("status: pileup\n", result)
            self.assertIn("sampler_samples: 5\n", result)

    def test_watch_clear_boundary_and_hold_reset(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            episode = root / "shared.episode"
            episode.write_text('{"opened": 1}')
            result = self.watch(root / "high", [51], episode, duration=4)
            self.assertIn("armed: no\n", result)
            self.assertTrue(episode.exists())
            result = self.watch(root / "dip", [50, 51, 50], episode, duration=4)
            self.assertIn("armed: no\n", result)
            self.assertTrue(episode.exists())
            result = self.watch(root / "equal", [50], episode, duration=4)
            self.assertIn("armed: yes\n", result)
            self.assertFalse(episode.exists())
            self.assertFalse((root / "equal").exists())

    def test_unreadable_sample_breaks_high_hold(self):
        with tempfile.TemporaryDirectory() as state:
            result = self.watch(state, [61, guard.ReadError("unreadable"), 61, 61, 61])
            self.assertIn("status: pileup\n", result)
            self.assertIn("sampler_samples: 4\n", result)

    def test_unreadable_sample_breaks_quiet_hold(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            episode = root / "shared.episode"
            episode.write_text('{"opened": 1}')
            result = self.watch(root / "state", [50, OSError("unreadable"), 50, 50], episode, duration=4)
            self.assertIn("status: idle\n", result)
            self.assertIn("armed: no\n", result)
            self.assertTrue(episode.exists())
            result = self.watch(root / "state", [50], episode, duration=4)
            self.assertIn("armed: yes\n", result)
            self.assertFalse(episode.exists())

    def test_census_retention_keeps_the_newest_twenty(self):
        with tempfile.TemporaryDirectory() as temporary:
            state = Path(temporary)
            for index in range(22):
                census = {"epoch": index}
                path = Path(guard.write_census(state, census))
                os.utime(path, (index, index))
            retained = [json.loads(path.read_text())["epoch"] for path in state.glob("proc-census.*.json")]
            self.assertEqual(sorted(retained), list(range(2, 22)))

    def test_episode_override_is_shared_across_census_directories(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            episode = root / "claims" / "uid" / "proc-guard.episode"
            first, second = root / "home-a", root / "home-b"
            result = self.watch(first, [61], episode)
            self.assertIn("status: pileup\n", result)
            self.assertTrue(episode.is_file())
            self.assertFalse((first / "proc-guard.episode").exists())
            record = json.loads(episode.read_text())
            self.assertEqual(Path(record["census"]).parent, first)
            result = self.watch(second, [61], episode, duration=4)
            self.assertIn("status: idle\n", result)
            self.assertIn("armed: no\n", result)
            self.assertFalse(second.exists())
            result = self.watch(second, [50, 50, 50, 61, 61, 61], episode)
            self.assertIn("status: pileup\n", result)
            self.assertTrue(episode.is_file())
            self.assertEqual(len(list(first.glob("proc-census.*.json"))), 1)
            self.assertEqual(len(list(second.glob("proc-census.*.json"))), 1)
            self.assertFalse((second / "proc-guard.episode").exists())

    def test_failed_census_still_opens_shared_episode(self):
        for failure in ("build", "save"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                episode = root / "claim" / "proc-guard.episode"
                method = "build_census" if failure == "build" else "write_census"
                with patch.object(guard, method, side_effect=OSError("census unavailable")):
                    result = self.watch(root / "first", [61], episode)
                self.assertIn("status: pileup\n", result)
                self.assertIn("census_error: OSError: census unavailable\n", result)
                self.assertNotIn("\ncensus: ", result)
                self.assertTrue(episode.exists())
                record = json.loads(episode.read_text())
                self.assertEqual(record["count"], 61)
                self.assertIsNone(record["census"])
                result = self.watch(root / "second", [61], episode, duration=4)
                self.assertIn("status: idle\n", result)
                self.assertIn("armed: no\n", result)
                self.assertFalse((root / "second").exists())



if __name__ == "__main__":
    unittest.main()
