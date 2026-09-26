"""Cross-process claims on a recording.

The macOS app processes new recordings on its own, and so does the launchd
watcher (``transcribe watch``). Left to themselves, both pick up the same file,
transcribe it twice, and file two copies of every meeting before one of them
fails to move a source the other already moved.

A claim is an advisory ``flock`` on a file under ``~/.transcribe/locks``. The
kernel drops it when the holder exits, crash included, so a claim can never be
left stale by a process that died holding it.
"""

import fcntl
import hashlib
import os
from contextlib import contextmanager

from . import config as config_mod


class AlreadyClaimed(RuntimeError):
    """Raised when another process is already working on the same file."""


def _lock_path(path):
    # Read at call time, not import time, so tests can redirect CONFIG_DIR.
    directory = config_mod.CONFIG_DIR / "locks"
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    digest = hashlib.sha256(os.path.abspath(path).encode("utf-8")).hexdigest()[:32]
    return directory / f"{digest}.lock"


@contextmanager
def claim(path):
    """Hold an exclusive claim on ``path`` for the duration of the block.

    Raises ``AlreadyClaimed`` straight away rather than waiting: the other
    process will finish the job, and queueing behind it would only process the
    file a second time once it had.
    """
    handle = open(_lock_path(path), "a+")  # noqa: SIM115 - held open for the flock
    try:
        try:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as e:
            raise AlreadyClaimed(f"{os.path.basename(path)} is already being processed") from e
        try:
            yield
        finally:
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
    finally:
        # The lock file itself is left behind on purpose. Unlinking it would let
        # a process that opened it a moment earlier lock an orphaned inode while
        # a third locks the new one, and both would believe they hold the claim.
        handle.close()
