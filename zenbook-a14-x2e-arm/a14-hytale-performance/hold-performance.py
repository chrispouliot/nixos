#!/usr/bin/env python3
"""Hold the existing A14 performance lease while FEX runs, preserving binfmt FDs."""
import importlib.util
import os
import select
import signal
import sys


def supervise(command, acquire):
    if os.geteuid() == 0:
        raise RuntimeError('Hytale must run as your normal user, not root')
    conn, _ = acquire('acquire')
    child = None
    pending = []
    old_handlers = {}

    def forward(signum, _frame):
        if not child:
            pending.append(signum)
        else:
            try:
                os.kill(child, signum)
            except ProcessLookupError:
                pass

    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        old_handlers[sig] = signal.signal(sig, forward)
    try:
        fork_mask = signal.pthread_sigmask(signal.SIG_BLOCK, set(old_handlers))
        try:
            child = os.fork()
        except BaseException:
            signal.pthread_sigmask(signal.SIG_SETMASK, fork_mask)
            raise
        if child == 0:
            # The performance socket must belong only to the supervisor.
            conn.close()
            for sig, handler in old_handlers.items():
                signal.signal(sig, handler)
            signal.pthread_sigmask(signal.SIG_SETMASK, fork_mask)
            try:
                # Unlike subprocess.Popen(close_fds=True), execv preserves the
                # inherited FEX_EXECVEFD and other inheritable launcher FDs.
                os.execv(command[0], command)
            except BaseException as exc:
                print(f'hytale-performance: cannot start game: {exc}', file=sys.stderr)
                os._exit(127)
        signal.pthread_sigmask(signal.SIG_SETMASK, fork_mask)
        for sig in pending:
            try:
                os.kill(child, sig)
            except ProcessLookupError:
                pass
        watching = True
        while True:
            done, status = os.waitpid(child, os.WNOHANG)
            if done:
                code = os.waitstatus_to_exitcode(status)
                return code if code >= 0 else 128 - code
            if watching:
                ready, _, _ = select.select([conn], [], [], .25)
                if ready:
                    try:
                        connected = bool(conn.recv(1))
                    except OSError:
                        connected = False
                    if not connected:
                        print('hytale-performance: profile service disconnected; '
                              'performance mode is no longer guaranteed', file=sys.stderr)
                        watching = False
            else:
                # Continue supervising the game even if the service restarts.
                select.select([], [], [], .25)
    finally:
        conn.close()
        for sig, handler in old_handlers.items():
            signal.signal(sig, handler)


def main():
    if len(sys.argv) < 3 or not os.path.isabs(sys.argv[2]):
        raise RuntimeError('Expected the power_mode.py path and an absolute FEX executable')
    spec = importlib.util.spec_from_file_location('a14_power_mode', sys.argv[1])
    controller = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(controller)
    return supervise(sys.argv[2:], controller.connect_request)


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (Exception, KeyboardInterrupt) as exc:
        print(f'hytale-performance: {exc or "interrupted"}', file=sys.stderr)
        sys.exit(1)
