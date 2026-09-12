"""Test-only in-process stream transport for hosts that prohibit UNIX sockets.

Uses anonymous pipes to exercise the coordinator's real selector/EOF handling.
Never imported by the installed service or command.
"""
from collections import deque
import os
from pathlib import Path
import select
import socket


class PipeSocket:
    registry = {}

    def __init__(self, *args, **kwargs):
        self.r, self.w = os.pipe()
        self.pending = deque()
        self.path = None
        self.blocking = True
        self.timeout = None
        self.closed = False

    def fileno(self):
        return self.r

    def bind(self, path):
        if Path(path).exists():
            raise FileExistsError(path)
        Path(path).touch()
        self.path = path
        self.registry[path] = self

    def listen(self, *_):
        pass

    def accept(self):
        os.read(self.r, 1)
        return self.pending.popleft(), ''

    def connect(self, path):
        listener = self.registry[path]
        os.close(self.r)
        os.close(self.w)
        peer = PipeSocket()
        os.close(peer.r)
        os.close(peer.w)
        peer.r, self.w = os.pipe()
        self.r, peer.w = os.pipe()
        listener.pending.append(peer)
        os.write(listener.w, b'1')

    def setblocking(self, value):
        self.blocking = value
        os.set_blocking(self.r, value)

    def settimeout(self, value):
        self.timeout = value

    def sendall(self, data):
        while data:
            data = data[os.write(self.w, data):]

    def recv(self, count):
        if self.blocking and self.timeout is not None:
            ready, _, _ = select.select([self.r], [], [], self.timeout)
            if not ready:
                raise TimeoutError('test pipe timed out')
        return os.read(self.r, count)

    def close(self):
        if self.closed:
            return
        self.closed = True
        os.close(self.r)
        os.close(self.w)
        if self.path:
            self.registry.pop(self.path, None)
