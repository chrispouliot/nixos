"""Tests use anonymous pipes and ordinary child processes, never real fan control."""
import importlib.util
import os
from pathlib import Path
import signal
import sys
import tempfile
import subprocess
import time
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('holder', Path(__file__).with_name('hold-performance.py'))
holder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(holder)


class Lease:
    def __init__(self):
        self.r, self.w = os.pipe()
        self.closed = False

    def fileno(self):
        return self.r

    def recv(self, n):
        return os.read(self.r, n)

    def close(self):
        if not self.closed:
            self.closed = True
            os.close(self.r)
            os.close(self.w)


class HolderTests(unittest.TestCase):
    def setUp(self):
        self.lease = Lease()
        self.uid = patch.object(holder.os, 'geteuid', return_value=1000)
        self.uid.start()

    def tearDown(self):
        self.uid.stop()
        self.lease.close()

    def acquire(self, op):
        self.assertEqual(op, 'acquire')
        return self.lease, {'ok': True}

    def test_preserves_fex_descriptor_arguments_and_exit_status(self):
        with tempfile.TemporaryDirectory() as d:
            source = Path(d) / 'executable-fd'
            source.write_text('FEX executable descriptor')
            fd = os.open(source, os.O_RDONLY)
            os.set_inheritable(fd, True)
            output = Path(d) / 'result'
            code = ('import os,sys,pathlib; '
                    'assert os.read(int(os.environ["FEX_EXECVEFD"]),100) == b"FEX executable descriptor"; '
                    'assert sys.argv[2:] == ["space argument", "--java-exec", "native-java"]; '
                    'pathlib.Path(sys.argv[1]).write_text("preserved"); sys.exit(7)')
            try:
                with patch.dict(os.environ, {'FEX_EXECVEFD': str(fd)}):
                    status = holder.supervise([sys.executable, '-c', code, str(output),
                                               'space argument', '--java-exec', 'native-java'], self.acquire)
                self.assertEqual(status, 7)
                self.assertEqual(output.read_text(), 'preserved')
                self.assertTrue(self.lease.closed)
            finally:
                os.close(fd)

    def test_missing_executable_releases_request(self):
        self.assertEqual(holder.supervise(['/no-such-hytale-test-executable'], self.acquire), 127)
        self.assertTrue(self.lease.closed)

    def test_failed_acquisition_does_not_launch(self):
        with tempfile.TemporaryDirectory() as d:
            marker = Path(d) / 'not-created'
            def fail(_):
                raise RuntimeError('simulated profile error')
            with self.assertRaisesRegex(RuntimeError, 'simulated profile error'):
                holder.supervise([sys.executable, '-c', f'open({str(marker)!r},"w").close()'], fail)
            self.assertFalse(marker.exists())

    def test_sigterm_forwarding_and_release(self):
        with tempfile.TemporaryDirectory() as d:
            ready = Path(d) / 'ready'
            trigger_code = ('import os,pathlib,signal,sys,time; '
                            'ready=pathlib.Path(sys.argv[1]); deadline=time.monotonic()+5\n'
                            'while not ready.exists() and time.monotonic()<deadline: time.sleep(.01)\n'
                            'if ready.exists(): os.kill(int(sys.argv[2]),signal.SIGTERM)')
            trigger = subprocess.Popen([sys.executable, '-c', trigger_code,
                                        str(ready), str(os.getpid())])
            code = f'import pathlib,time; pathlib.Path({str(ready)!r}).touch(); time.sleep(10)'
            status = holder.supervise([sys.executable, '-c', code], self.acquire)
            trigger.wait(timeout=6)
            self.assertEqual(status, 143)
            self.assertTrue(self.lease.closed)


if __name__ == '__main__':
    unittest.main(verbosity=2)
