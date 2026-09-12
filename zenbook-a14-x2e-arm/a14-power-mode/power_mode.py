#!/usr/bin/env python3
"""A14 profile coordinator. Root writes sysfs; clients only hold socket leases."""
import json
import os
from pathlib import Path
import selectors
import signal
import socket
import subprocess
import sys
import time

SOCKET = '/run/a14-power-mode/control.sock'


def log(message):
    print(message, file=sys.stderr, flush=True)


class Hardware:
    def __init__(self, sysroot=Path('/sys')):
        self.sysroot = Path(sysroot)

    def policies(self):
        paths = sorted((self.sysroot / 'devices/system/cpu/cpufreq').glob('policy*'))
        if {p.name for p in paths} != {'policy0', 'policy6', 'policy12'}:
            raise RuntimeError('Expected UX3407NA policies 0, 6 and 12; refusing partial setup')
        return paths

    def fan(self):
        paths = list((self.sysroot / 'bus/i2c/drivers/asus-glymur-ec').glob('*/fan_profile'))
        if len(paths) != 1:
            raise RuntimeError('Persistent fan_profile interface missing: boot the patched kernel; '
                               'fan_profile_trial is not supported')
        return paths[0]

    @staticmethod
    def fan_state(path):
        return {k: int(v) for k, v in (item.split('=', 1) for item in path.read_text().split())}

    def governors(self, policies, governor):
        for p in policies:
            path = p / 'scaling_governor'
            if path.read_text().strip() != governor:
                path.write_text(governor + '\n')
                if path.read_text().strip() != governor:
                    raise RuntimeError(f'{p.name} did not accept governor {governor}')

    def apply(self, performance):
        governor = 'performance' if performance else 'schedutil'
        profile = 0 if performance else 1
        policies, fan = self.policies(), self.fan()
        for p in policies:
            if governor not in (p / 'scaling_available_governors').read_text().split():
                raise RuntimeError(f'{p.name} does not support {governor}')
        state = self.fan_state(fan)
        if state.get('suspended'):
            raise RuntimeError('EC is suspended; profile will be retried')
        # More cooling before raising the governor; lower demand before quiet.
        if not performance:
            self.governors(policies, governor)
        if (state.get('desired') != profile or state.get('last_requested') != profile
                or state.get('last_error') != 0):
            fan.write_text(str(profile) + '\n')
            state = self.fan_state(fan)
            if (state.get('desired') != profile or state.get('last_requested') != profile
                    or state.get('last_error') != 0):
                raise RuntimeError('EC did not acknowledge the requested fan profile')
        if performance:
            self.governors(policies, governor)

    def snapshot(self):
        return {
            'governors': {p.name: (p / 'scaling_governor').read_text().strip()
                          for p in self.policies()},
            'fan_request': self.fan_state(self.fan()),
        }


class Coordinator:
    def __init__(self, hardware, path=SOCKET):
        self.hardware, self.path = hardware, path
        self.selector = selectors.DefaultSelector()
        self.clients = {}
        self.running = True
        self.last_error = None
        self.listener = None

    def active(self):
        return sum(client['active'] for client in self.clients.values())

    def reconcile(self):
        try:
            self.hardware.apply(bool(self.active()))
            if self.last_error:
                log('Profile control recovered')
            self.last_error = None
            return True
        except Exception as exc:
            error = str(exc)
            if error != self.last_error:
                log('Profile error: ' + error)
            self.last_error = error
            return False

    def close(self, conn):
        client = self.clients.pop(conn, None)
        if client is None:
            return
        self.selector.unregister(conn)
        conn.close()
        if client['active']:
            self.reconcile()
            log(f'Performance request released; active={self.active()}')

    def respond(self, conn, value):
        try:
            conn.sendall((json.dumps(value) + '\n').encode())
            return True
        except OSError:
            self.close(conn)
            return False

    def request(self, conn, message):
        client = self.clients[conn]
        if client['active']:
            self.close(conn)
            return
        if message == {'op': 'acquire'}:
            client['active'] = True
            if not self.reconcile():
                error = self.last_error
                client['active'] = False
                self.reconcile()
                self.respond(conn, {'ok': False, 'error': error})
                self.close(conn)
                return
            if self.respond(conn, {'ok': True, 'mode': 'performance', 'active': self.active()}):
                log(f'Performance request acquired; active={self.active()}')
        elif message == {'op': 'status'}:
            result = {'ok': self.last_error is None,
                      'mode': 'performance' if self.active() else 'quiet',
                      'active': self.active(), 'error': self.last_error}
            try:
                result.update(self.hardware.snapshot())
            except Exception as exc:
                result.update(ok=False, error=str(exc))
            self.respond(conn, result)
            self.close(conn)
        else:
            self.respond(conn, {'ok': False, 'error': 'Only acquire and status are supported'})
            self.close(conn)

    def serve(self):
        # This is a root-owned RuntimeDirectory, never a caller-selected path.
        self.hardware.apply(False)
        path = Path(self.path)
        if path.exists():
            path.unlink()
        listener = self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(self.path)
        os.chmod(self.path, 0o660)
        listener.listen(32)
        listener.setblocking(False)
        self.selector.register(listener, selectors.EVENT_READ)
        log('A14 quiet mode active: schedutil, quiet fans; AC/battery independent')
        next_check = time.monotonic() + 5
        try:
            while self.running:
                for key, _ in self.selector.select(max(0, min(1, next_check - time.monotonic()))):
                    conn = key.fileobj
                    if conn is listener:
                        conn, _ = listener.accept()
                        conn.setblocking(False)
                        if len(self.clients) >= 128:
                            conn.close()
                            continue
                        self.clients[conn] = {'active': False, 'data': b'',
                                              'deadline': time.monotonic() + 5}
                        self.selector.register(conn, selectors.EVENT_READ)
                        continue
                    try:
                        data = conn.recv(1024)
                    except (ConnectionError, OSError):
                        self.close(conn)
                        continue
                    if not data:
                        self.close(conn)
                        continue
                    client = self.clients[conn]
                    client['data'] += data
                    if len(client['data']) > 1024:
                        self.close(conn)
                    elif b'\n' in client['data']:
                        try:
                            message = json.loads(client['data'])
                        except (ValueError, UnicodeError):
                            self.close(conn)
                        else:
                            self.request(conn, message)
                now = time.monotonic()
                for conn, client in list(self.clients.items()):
                    if not client['active'] and now >= client['deadline']:
                        self.close(conn)
                if now >= next_check:
                    # Read sysfs; write only on changed state or a previous error.
                    self.reconcile()
                    next_check = now + 5
        finally:
            for conn in list(self.clients):
                self.selector.unregister(conn)
                conn.close()
            self.clients.clear()
            self.reconcile()
            self.selector.unregister(listener)
            listener.close()
            self.selector.close()
            path.unlink(missing_ok=True)


def connect_request(op, path=SOCKET):
    conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    conn.settimeout(15)
    try:
        conn.connect(path)
        conn.sendall((json.dumps({'op': op}) + '\n').encode())
        data = b''
        while b'\n' not in data:
            chunk = conn.recv(1024)
            if not chunk:
                raise RuntimeError('Profile service disconnected before acknowledging the request')
            data += chunk
            if len(data) > 16384:
                raise RuntimeError('Oversized profile response')
        result = json.loads(data)
        if not result.get('ok'):
            raise RuntimeError(result.get('error') or 'Profile request failed')
        conn.settimeout(None)
        return conn, result
    except BaseException:
        conn.close()
        raise


def run_client(command, hold=False, path=SOCKET):
    if os.geteuid() == 0:
        raise RuntimeError('Run performancemode as your normal user, without sudo')
    conn, _ = connect_request('acquire', path)
    child = None
    interrupted = 0
    old_handlers = {}

    def forward(signum, _frame):
        nonlocal interrupted
        interrupted = signum
        if child is not None and child.poll() is None:
            # The child inherits the terminal process group, preserving TTY input.
            # SIGINT from the terminal also reaches it; explicit forwarding covers
            # signals sent specifically to this wrapper.
            try:
                child.send_signal(signum)
            except ProcessLookupError:
                pass

    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        old_handlers[sig] = signal.signal(sig, forward)
    try:
        if hold:
            log('Performance mode active. Press Ctrl+C to release this request.')
        else:
            child = subprocess.Popen(command, close_fds=True)
            if interrupted:
                child.send_signal(interrupted)
        while True:
            if hold and interrupted:
                return 128 + interrupted
            if child is not None and child.poll() is not None:
                code = child.returncode
                return code if code >= 0 else 128 - code
            # Detect service loss promptly. Applications keep running as the user;
            # no silent claim that performance mode remains active after failure.
            import select
            ready, _, _ = select.select([conn], [], [], 0.25)
            if ready and not conn.recv(1):
                log('Profile service disconnected; performance mode is no longer guaranteed.')
                if hold:
                    return 1
                code = child.wait()
                return code if code >= 0 else 128 - code
    finally:
        conn.close()
        for sig, handler in old_handlers.items():
            signal.signal(sig, handler)


def main():
    if sys.argv[1:] == ['--daemon']:
        if os.geteuid() != 0:
            raise RuntimeError('The profile service must run as root')
        coordinator = Coordinator(Hardware())
        for sig in (signal.SIGINT, signal.SIGTERM):
            signal.signal(sig, lambda *_: setattr(coordinator, 'running', False))
        coordinator.serve()
        return 0
    args = sys.argv[1:]
    if args == ['--status']:
        conn, state = connect_request('status')
        conn.close()
        print(json.dumps(state, indent=2))
        print('fan_request records EC requests, not hardware profile readback.')
        return 0
    if args == ['--hold']:
        return run_client([], hold=True)
    if args and args[0] == '--':
        args = args[1:]
    if not args or args[0] in ('-h', '--help'):
        print('Usage: performancemode COMMAND [ARGS...]\n'
              '       performancemode --hold\n'
              '       performancemode --status\n\n'
              'Requests performance governor and normal fans until COMMAND exits.\n'
              'The last request ending restores schedutil and quiet fans.\n'
              'Wrap the foreground game command, not a launcher that exits early.')
        return 0
    return run_client(args)


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (Exception, KeyboardInterrupt) as exc:
        log(f'performancemode: {exc or "interrupted"}')
        sys.exit(1)
