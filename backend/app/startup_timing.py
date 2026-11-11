"""Request-scoped, payload-free startup timing across async/threadpool boundaries."""
from contextlib import contextmanager
from contextvars import ContextVar
from dataclasses import dataclass, field
from functools import wraps
import logging
from threading import Lock
import time
from uuid import uuid4


@dataclass
class StartupTiming:
    trace: str = field(default_factory=lambda: uuid4().hex)
    durations: dict[str, float] = field(default_factory=dict)
    lock: Lock = field(default_factory=Lock)

    def header(self):
        with self.lock:
            return ', '.join(f'{name};dur={duration:.2f}' for name, duration in self.durations.items())


current: ContextVar[StartupTiming | None] = ContextVar('startup_timing', default=None)


@contextmanager
def stage(name):
    timing = current.get()
    if timing is None:
        yield
        return
    started = time.perf_counter()
    succeeded = False
    try:
        yield
        succeeded = True
    finally:
        elapsed = (time.perf_counter() - started) * 1000
        with timing.lock:
            timing.durations[name] = timing.durations.get(name, 0) + elapsed
        logging.getLogger('spoken.startup').info(
            'startup_stage trace=%s stage=%s duration_ms=%.2f success=%s',
            timing.trace, name, elapsed, succeeded)


def timed(name):
    def decorate(function):
        @wraps(function)
        def invoke(*args, **kwargs):
            with stage(name):
                return function(*args, **kwargs)
        return invoke
    return decorate
