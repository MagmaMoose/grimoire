"""Action items across every meeting, and which of them are done.

The notes give every meeting its own next steps. What anyone actually wants to
know is what is still owed across all of them, which is what this collects.

Done state is shared with the macOS app through ``~/.transcribe/action-items-done.json``,
a sorted list of keys. A key is the meeting folder's path and the action's own
text, ``<folder>|<owner><title><detail>``, exactly as the app builds it, so a tick
in either place shows up in the other.
"""

import hashlib
import json
import os
import re
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path

from . import config as config_mod

DONE_FILE = "action-items-done.json"

# Diarization labels and the notes' own placeholder: a voice nobody put a name
# to, which says nothing about whose job something is.
_ANONYMOUS_OWNER = re.compile(
    r"^(unassigned|unknown( speaker)?|n/?a|none|tbd|nobody|"
    r"(speaker|spk|voice|participant)[\s_#-]*([0-9]+|[a-z]))$",
    re.IGNORECASE,
)


@dataclass
class ActionItem:
    folder: Path
    meeting: str
    date: datetime | None
    owner: str
    title: str
    detail: str

    @property
    def key(self):
        return action_key(self.folder, self.owner, self.title, self.detail)

    @property
    def ref(self):
        """A short handle for the command line, stable while the action is."""
        return hashlib.sha256(self.key.encode("utf-8")).hexdigest()[:8]

    @property
    def assigned(self):
        return named_owner(self.owner)


def named_owner(owner):
    """The owner as a person's name, or None for "Unassigned" and "Speaker 2"."""
    text = (owner or "").strip()
    if not text or _ANONYMOUS_OWNER.match(text):
        return None
    return text


def is_mine(owner, user_name):
    """True when ``owner`` names the user, by full name or first name."""
    name = named_owner(owner)
    me = (user_name or "").strip()
    if not name or not me:
        return False
    if name.lower() == me.lower():
        return True
    first = me.split()[0].lower()
    return first in {word.lower().strip(".,") for word in name.split()}


def _canonical(folder):
    # The app built keys from a directory URL, which can carry a trailing slash.
    text = str(folder)
    return text[:-1] if len(text) > 1 and text.endswith("/") else text


def action_key(folder, owner, title, detail):
    return f"{_canonical(folder)}|{owner}{title}{detail}"


def _normalise(key):
    folder, separator, rest = key.partition("|")
    return f"{_canonical(folder)}{separator}{rest}" if separator else key


def _done_path():
    # Read at call time so tests can redirect CONFIG_DIR.
    return config_mod.CONFIG_DIR / DONE_FILE


def load_done():
    try:
        stored = json.loads(_done_path().read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return set()
    if not isinstance(stored, list):
        return set()
    return {_normalise(str(key)) for key in stored}


def save_done(keys):
    path = _done_path()
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}")
    temporary.write_text(json.dumps(sorted(keys)), encoding="utf-8")
    os.replace(temporary, path)


def _meeting_date(folder, payload):
    stamp = payload.get("recording_started_at")
    if stamp:
        try:
            return datetime.fromisoformat(stamp) + timedelta(seconds=float(payload.get("start", 0)))
        except (TypeError, ValueError):
            pass
    for fmt, width in (("%Y-%m-%d %H%M", 15), ("%Y-%m-%d %H-%M-%S", 19), ("%Y-%m-%d", 10)):
        try:
            return datetime.strptime(folder.name[:width], fmt)
        except ValueError:
            continue
    return None


def collect(destination, since_days=None):
    """Every action item in the library, newest meeting first."""
    root = Path(destination)
    if not root.is_dir():
        return []
    cutoff = datetime.now() - timedelta(days=float(since_days)) if since_days else None

    items = []
    for folder in root.iterdir():
        if not folder.is_dir():
            continue
        try:
            payload = json.loads((folder / "notes.json").read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if not isinstance(payload, dict):
            continue
        notes = payload.get("notes") or {}
        date = _meeting_date(folder, payload)
        if cutoff and date and date < cutoff:
            continue
        title = notes.get("title") or payload.get("title") or folder.name
        for step in notes.get("next_steps") or []:
            if not isinstance(step, dict):
                continue
            items.append(
                ActionItem(
                    folder=folder,
                    meeting=title,
                    date=date,
                    owner=step.get("owner") or "",
                    title=step.get("title") or "",
                    detail=step.get("detail") or "",
                )
            )
    items.sort(key=lambda item: item.date or datetime.min, reverse=True)
    return items


def set_done(items, refs, done=True):
    """Mark the actions whose ref is in ``refs``. Returns the ones changed."""
    wanted = {ref.lower() for ref in refs}
    matched = [item for item in items if item.ref in wanted]
    keys = load_done()
    for item in matched:
        if done:
            keys.add(item.key)
        else:
            keys.discard(item.key)
    if matched:
        save_done(keys)
    return matched


def run(args, config):
    """``transcribe actions`` -- list, tick off, or untick action items."""
    destination = config.get("destination_directory")
    if not destination:
        print("✗ No destination_directory configured.")
        return 1

    since = None
    for arg in args:
        if arg.startswith("--since-days="):
            try:
                since = float(arg.split("=", 1)[1])
            except ValueError:
                print(f"✗ Not a number of days: {arg}")
                return 1
    items = collect(destination, since_days=since)

    verbs = [arg for arg in args if not arg.startswith("--")]
    if verbs and verbs[0] in {"done", "undo"}:
        refs = verbs[1:]
        if not refs:
            print(f"Usage: transcribe actions {verbs[0]} <ref> [more refs]")
            return 1
        changed = set_done(items, refs, done=verbs[0] == "done")
        for item in changed:
            state = "✓ Done" if verbs[0] == "done" else "○ Outstanding"
            print(f"{state}: {item.title} ({item.meeting})")
        unknown = {ref.lower() for ref in refs} - {item.ref for item in changed}
        for ref in sorted(unknown):
            print(f"✗ No action item with ref {ref}")
        return 0 if changed and not unknown else 1

    done = load_done()
    user = config.get("user_name") or ""
    if "--mine" in args:
        if not user.strip():
            print("✗ Set user_name in the config to see only your own actions.")
            return 1
        items = [item for item in items if is_mine(item.owner, user) or not item.assigned]
    show_done = "--done" in args or "--all" in args
    show_open = "--done" not in args
    shown = [
        item
        for item in items
        if (item.key in done and show_done) or (item.key not in done and show_open)
    ]

    if "--json" in args:
        print(
            json.dumps(
                [
                    {
                        "ref": item.ref,
                        "done": item.key in done,
                        "owner": item.assigned,
                        "title": item.title,
                        "detail": item.detail,
                        "meeting": item.meeting,
                        "date": item.date.isoformat() if item.date else None,
                        "folder": str(item.folder),
                    }
                    for item in shown
                ],
                indent=2,
                ensure_ascii=False,
            )
        )
        return 0

    outstanding = sum(1 for item in items if item.key not in done)
    print(f"{outstanding} outstanding of {len(items)} action item(s)\n")
    for item in shown:
        mark = "✓" if item.key in done else "○"
        owner = f"  ({item.assigned})" if item.assigned else ""
        when = f"{item.date:%Y-%m-%d}" if item.date else "undated"
        print(f"{mark} [{item.ref}] {item.title}{owner}")
        print(f"      {when} · {item.meeting}")
    if not shown:
        print("Nothing to show.")
    else:
        print("\nTick one off with: transcribe actions done <ref>")
    return 0
