"""Assign categories to meetings from their notes.

Tagging a hundred meetings by hand never happens, so the categories stay empty
and the feature is dead. The LLM has already read every transcript to write the
notes; asking it for a label as well is nearly free.

Categories are written to ``tags.json`` beside the notes, which is where the
macOS app reads them. ``notes.json`` is deliberately left alone: reprocessing a
meeting rewrites that file, which would silently discard the categories.

The existing vocabulary is passed in every request. Without it the model invents
a new near-synonym each time -- "1:1", "One-on-one", "1-on-1" -- and the result
is a hundred categories that group nothing.
"""

import json
from pathlib import Path

from .llm import complete_json, is_configured

TAGS_FILE = "tags.json"

# Enough to describe a meeting, few enough to still group things. A model given
# no ceiling labels everything with five tags and the categories stop meaning
# anything.
MAX_TAGS_PER_MEETING = 3

CATEGORY_SCHEMA = {
    "type": "object",
    "properties": {
        "categories": {
            "type": "array",
            "description": (
                f"Between one and {MAX_TAGS_PER_MEETING} short categories for this meeting."
            ),
            "items": {
                "type": "string",
                "description": (
                    "A short noun phrase, one to three words, in Title Case. "
                    "Describes the kind of meeting or its subject area, e.g. "
                    "'Standup', 'Architecture', 'Hiring', 'Customer Call'."
                ),
            },
        }
    },
    "required": ["categories"],
}


def existing_vocabulary(destination):
    """Every category already in use across the library, most common first."""
    counts = {}
    root = Path(destination)
    if not root.is_dir():
        return []
    for tags_file in root.glob(f"*/{TAGS_FILE}"):
        for name in read_tags(tags_file.parent):
            counts[name] = counts.get(name, 0) + 1
    return [name for name, _ in sorted(counts.items(), key=lambda item: -item[1])]


def read_tags(folder):
    """Categories already on one meeting."""
    try:
        with open(Path(folder) / TAGS_FILE, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        # ValueError covers a malformed file and a non-UTF-8 one alike; both
        # mean "no usable categories", not "stop the run".
        return []
    names = data.get("names") if isinstance(data, dict) else None
    return [str(name) for name in names] if isinstance(names, list) else []


def write_tags(folder, names):
    """Write categories, matching the shape the macOS app reads."""
    path = Path(folder) / TAGS_FILE
    cleaned = _dedupe(names)
    if not cleaned:
        path.unlink(missing_ok=True)
        return []
    with open(path, "w") as handle:
        json.dump({"names": cleaned}, handle, indent=2, sort_keys=True)
        handle.write("\n")
    return cleaned


def _dedupe(names):
    """Trim, drop blanks, and collapse case-insensitive duplicates.

    A bare string is wrapped rather than iterated. A model that answers with
    "Architecture" instead of ["Architecture"] would otherwise produce one
    category per letter, and the schema is a request, not a guarantee.
    """
    if isinstance(names, str):
        names = [names]
    seen, result = set(), []
    for name in names or []:
        cleaned = str(name).strip()
        if cleaned and cleaned.lower() not in seen:
            seen.add(cleaned.lower())
            result.append(cleaned)
    return result


def _meeting_summary(folder):
    """The part of a meeting worth sending: what it was about, not every word."""
    try:
        with open(Path(folder) / "notes.json", encoding="utf-8") as handle:
            payload = json.load(handle)
        if not isinstance(payload, dict):
            return None
    except (OSError, ValueError):
        return None

    notes = payload.get("notes") or {}
    event = payload.get("calendar_event") or {}
    parts = [
        f"Title: {notes.get('title') or payload.get('title') or Path(folder).name}",
        f"Summary: {notes.get('summary', '')}",
    ]
    if event.get("title"):
        parts.append(f"Calendar title: {event['title']}")
    attendees = payload.get("attendees") or event.get("attendees") or []
    if attendees:
        parts.append(f"Attendees: {', '.join(attendees[:12])}")
    headings = [section.get("heading", "") for section in notes.get("sections") or []]
    if headings:
        parts.append(f"Themes: {', '.join(h for h in headings if h)}")
    return "\n".join(parts)


def categorise_meeting(folder, config, vocabulary=(), overwrite=False):
    """Assign categories to one meeting folder.

    Returns the categories written, or None when there was nothing to do.
    """
    folder = Path(folder)
    if not overwrite and read_tags(folder):
        return None
    if not is_configured(config):
        return None

    context = _meeting_summary(folder)
    if not context:
        return None

    known = (
        "\n\nCategories already in use. Reuse one of these whenever it fits, "
        "rather than inventing a near-synonym:\n" + "\n".join(f"- {name}" for name in vocabulary)
        if vocabulary
        else ""
    )

    result = complete_json(
        config,
        (
            "You label meetings with short, reusable categories. Prefer an "
            "existing category over a new one. A category names the kind of "
            "meeting or its subject area, never its specific content: "
            "'Architecture', not 'The Kubernetes migration discussion'."
        ),
        f"Meeting:\n{context}{known}",
        CATEGORY_SCHEMA,
        max_tokens=int(config.get("category_max_tokens", 2000)),
    )
    if not result:
        return None

    names = _dedupe(result.get("categories") or [])[:MAX_TAGS_PER_MEETING]
    if not names:
        return None
    return write_tags(folder, names)


def categorise_folders(folders, config, overwrite=False):
    """Categorise several meetings, growing the shared vocabulary as it goes."""
    if not folders:
        print("No meeting folders given.")
        return 1
    if not is_configured(config):
        print("✗ No LLM provider configured. Set an API key in the settings first.")
        return 1

    destination = config.get("destination_directory") or Path(folders[0]).parent
    vocabulary = existing_vocabulary(destination)
    failures = 0

    for folder in folders:
        path = Path(folder)
        if not path.is_dir():
            print(f"✗ Not a folder: {folder}")
            failures += 1
            continue

        try:
            names = categorise_meeting(path, config, vocabulary, overwrite=overwrite)
        except Exception as e:
            print(f"✗ {path.name}: {type(e).__name__}: {e}")
            failures += 1
            continue
        if names is None:
            existing = read_tags(path)
            if existing and not overwrite:
                print(f"· {path.name}: already categorised ({', '.join(existing)})")
            else:
                print(f"✗ {path.name}: could not categorise")
                failures += 1
            continue

        print(f"✓ {path.name}: {', '.join(names)}")
        # Feed new categories back so later meetings in the same run reuse them.
        for name in names:
            if name not in vocabulary:
                vocabulary.append(name)

    return 1 if failures == len(folders) else 0
