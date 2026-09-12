"""Host-side tests; no real sysfs access or root privileges required."""
import importlib.util
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

import power_mode as pm

PIPE_TRANSPORT = os.environ.get("A14_TEST_PIPE_TRANSPORT") == "1"
if PIPE_TRANSPORT:
    from test_pipe_transport import PipeSocket
    socket.socket = PipeSocket


class FakeHardware:
    def __init__(self):
        self.performance = None
        self.fail_performance = False
        self.calls = []

    def apply(self, performance):
        self.calls.append(performance)
        self.performance = performance
        if performance and self.fail_performance:
            raise RuntimeError('simulated EC failure')

    def snapshot(self):
        return {'test_performance': self.performance}


class CoordinatorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = self.temp.name + '/control.sock'
        self.hardware = FakeHardware()
        self.server = pm.Coordinator(self.hardware, self.path)
        self.thread = threading.Thread(target=self.server.serve)
        self.thread.start()
        self.wait_for(lambda: Path(self.path).exists() and bool(self.server.selector.get_map()))
        self.sockets = []

    def tearDown(self):
        for conn in self.sockets:
            conn.close()
        self.server.running = False
        self.thread.join(3)
        self.assertFalse(self.thread.is_alive())
        self.temp.cleanup()

    def wait_for(self, condition, seconds=3):
        end = time.monotonic() + seconds
        while not condition():
            if time.monotonic() >= end:
                self.fail('Timed out')
            time.sleep(.01)

    def acquire(self):
        conn, result = pm.connect_request('acquire', self.path)
        self.sockets.append(conn)
        self.assertTrue(result['ok'])
        return conn

    def test_defaults_and_overlapping_requests(self):
        self.assertFalse(self.hardware.performance)
        first, second = self.acquire(), self.acquire()
        self.assertEqual(self.server.active(), 2)
        first.close()
        self.wait_for(lambda: self.server.active() == 1)
        self.assertTrue(self.hardware.performance)
        second.close()
        self.wait_for(lambda: self.server.active() == 0)
        self.assertFalse(self.hardware.performance)

    def test_failed_transition_rolls_back_and_rejects_command(self):
        self.hardware.fail_performance = True
        with self.assertRaisesRegex(RuntimeError, 'simulated EC failure'):
            pm.connect_request('acquire', self.path)
        self.wait_for(lambda: not self.hardware.performance)
        self.assertEqual(self.server.active(), 0)
        self.hardware.fail_performance = False
        self.acquire()
        self.assertTrue(self.hardware.performance)

    def test_status_does_not_request_performance(self):
        conn, state = pm.connect_request('status', self.path)
        conn.close()
        self.assertEqual(state['mode'], 'quiet')
        self.assertEqual(state['active'], 0)
        self.assertFalse(self.hardware.performance)

    def test_malformed_request_does_not_change_mode(self):
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.connect(self.path)
        conn.sendall(b'{invalid json}\n')
        conn.settimeout(2)
        self.assertEqual(conn.recv(1), b'')
        conn.close()
        self.assertFalse(self.hardware.performance)

    def test_command_exit_status_and_missing_command_cleanup(self):
        with patch.object(pm.os, 'geteuid', return_value=1000):
            self.assertEqual(pm.run_client([sys.executable, '-c', 'raise SystemExit(7)'],
                                           path=self.path), 7)
            self.wait_for(lambda: not self.hardware.performance)
            with self.assertRaises(FileNotFoundError):
                pm.run_client(['/no-such-a14-test-command'], path=self.path)
        self.wait_for(lambda: not self.hardware.performance)

    def spawn_hold(self):
        code = ('import sys; sys.path.insert(0, sys.argv[1]); import power_mode as p; '
                'p.os.geteuid=lambda: 1000; '
                'sys.exit(p.run_client([], hold=True, path=sys.argv[2]))')
        child = subprocess.Popen([sys.executable, '-c', code,
                                  str(Path(pm.__file__).parent), self.path],
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.wait_for(lambda: self.hardware.performance)
        return child

    @unittest.skipIf(PIPE_TRANSPORT, "Real process/socket death needs UNIX sockets")
    def test_sigterm_and_sigkill_release_request(self):
        for sig in (signal.SIGTERM, signal.SIGKILL):
            child = self.spawn_hold()
            try:
                child.send_signal(sig)
                child.communicate(timeout=3)
                self.wait_for(lambda: not self.hardware.performance)
            finally:
                if child.poll() is None:
                    child.kill()
                    child.communicate()

    def test_hold_sigterm_releases_request(self):
        def stop_when_active():
            self.wait_for(lambda: self.hardware.performance)
            time.sleep(.1)
            os.kill(os.getpid(), signal.SIGTERM)
        killer = threading.Thread(target=stop_when_active)
        killer.start()
        with patch.object(pm.os, 'geteuid', return_value=1000):
            self.assertEqual(pm.run_client([], hold=True, path=self.path), 143)
        killer.join(3)
        self.wait_for(lambda: not self.hardware.performance)

    def test_service_shutdown_restores_quiet(self):
        conn = self.acquire()
        self.server.running = False
        self.thread.join(3)
        self.assertFalse(self.hardware.performance)
        conn.settimeout(2)
        self.assertEqual(conn.recv(1), b'')


class FakeSysfsTests(unittest.TestCase):
    def test_governor_support_and_transition_order(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            for i in (0, 6, 12):
                p = root / f'devices/system/cpu/cpufreq/policy{i}'
                p.mkdir(parents=True)
                (p / 'scaling_governor').write_text('schedutil\n')
                (p / 'scaling_available_governors').write_text('schedutil performance\n')
            fan = root / 'bus/i2c/drivers/asus-glymur-ec/20-0076/fan_profile'
            fan.parent.mkdir(parents=True)
            fan.write_text('desired=1 last_requested=1 last_error=0 suspended=0\n')
            hardware = pm.Hardware(root)
            writes = []
            original = Path.write_text

            def write(path, text, *args, **kwargs):
                writes.append((path.name, text.strip()))
                if path == fan:
                    text = f'desired={text.strip()} last_requested={text.strip()} last_error=0 suspended=0\n'
                return original(path, text, *args, **kwargs)

            with patch.object(Path, 'write_text', write):
                hardware.apply(True)
                self.assertEqual(writes[0], ('fan_profile', '0'))
                self.assertEqual([v for k, v in writes if k == 'scaling_governor'],
                                 ['performance'] * 3)
                writes.clear()
                hardware.apply(False)
                self.assertEqual(writes[-1], ('fan_profile', '1'))
                self.assertEqual([v for k, v in writes if k == 'scaling_governor'],
                                 ['schedutil'] * 3)
                writes.clear()
                hardware.apply(False)
                self.assertEqual(writes, [])
            (root / 'devices/system/cpu/cpufreq/policy6/scaling_available_governors').write_text('schedutil\n')
            with self.assertRaisesRegex(RuntimeError, 'does not support performance'):
                hardware.apply(True)


if __name__ == '__main__':
    unittest.main(verbosity=2)
