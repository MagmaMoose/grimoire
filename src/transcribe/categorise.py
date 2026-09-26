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

Beside the categories, a meeting can carry named fields the user defines in
``group_fields`` -- "Company", "Project" -- one value each. Those are what the
app groups the library by when a category is too broad. They live in the same
file, under ``fields``, and are filled in the same request.
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


def _read(folder):
    try:
        with open(Path(folder) / TAGS_FILE, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        # ValueError covers a malformed file and a non-UTF-8 one alike; both
        # mean "no usable categories", not "stop the run".
        return {}
    return data if isinstance(data, dict) else {}


def read_tags(folder):
    """Categories already on one meeting."""
    names = _read(folder).get("names")
    return [str(name) for name in names] if isinstance(names, list) else []


def read_fields(folder):
    """Named fields on one meeting, such as ``{"Company": "Acme"}``."""
    fields = _read(folder).get("fields")
    if not isinstance(fields, dict):
        return {}
    return {str(key): str(value) for key, value in fields.items() if str(value).strip()}


def write_tags(folder, names, fields=None):
    """Write categories, matching the shape the macOS app reads.

    ``fields`` of None keeps whatever fields the file already has, so writing
    categories never wipes a Company the user set by hand.
    """
    path = Path(folder) / TAGS_FILE
    cleaned = _dedupe(names)
    kept = read_fields(folder) if fields is None else _clean_fields(fields)
    if not cleaned and not kept:
        path.unlink(missing_ok=True)
        return []
    payload = {"names": cleaned}
    if kept:
        payload["fields"] = kept
    with open(path, "w") as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.write("\n")
    return cleaned


def _clean_fields(fields):
    return {
        str(key).strip(): str(value).strip()
        for key, value in (fields or {}).items()
        if str(key).strip() and str(value).strip()
    }


def existing_field_values(destination, field):
    """Every value ``field`` already has across the library, most common first."""
    counts = {}
    root = Path(destination)
    if not root.is_dir():
        return []
    for tags_file in root.glob(f"*/{TAGS_FILE}"):
        value = read_fields(tags_file.parent).get(field)
        if value:
            counts[value] = counts.get(value, 0) + 1
    return [name for name, _ in sorted(counts.items(), key=lambda item: -item[1])]


def group_fields(config):
    """The field names the user groups meetings by, in the order they gave."""
    fields = config.get("group_fields") or []
    if isinstance(fields, str):
        fields = [fields]
    return [str(field).strip() for field in fields if str(field).strip()]


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


def _field_request(folder, fields, overwrite):
    """The schema and prompt additions for the fields this meeting still needs."""
    current = read_fields(folder)
    missing = [field for field in fields if overwrite or not current.get(field)]
    if not missing:
        return [], None, ""

    destination = Path(folder).parent
    properties = {}
    known = []
    for field in missing:
        properties[field] = {
            "type": "string",
            "description": (
                f"The {field} this meeting belongs to, as a short proper name. An "
                "empty string when the meeting does not make it clear."
            ),
        }
        values = existing_field_values(destination, field)
        if values:
            known.append(
                f"\n\nExisting {field} values. Reuse one whenever it is the same "
                f"{field}:\n" + "\n".join(f"- {value}" for value in values[:40])
            )
    schema = {
        "type": "object",
        "description": "Which of these groupings the meeting belongs to.",
        "properties": properties,
    }
    return missing, schema, "".join(known)


def categorise_meeting(folder, config, vocabulary=(), overwrite=False):
    """Assign categories, and any ``group_fields``, to one meeting folder.

    Returns the categories written, or None when there was nothing to do.
    """
    folder = Path(folder)
    fields = group_fields(config)
    has_names = bool(read_tags(folder))
    missing, field_schema, field_known = _field_request(folder, fields, overwrite)
    if not overwrite and has_names and not missing:
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

    schema = CATEGORY_SCHEMA
    system = (
        "You label meetings with short, reusable categories. Prefer an "
        "existing category over a new one. A category names the kind of "
        "meeting or its subject area, never its specific content: "
        "'Architecture', not 'The Kubernetes migration discussion'."
    )
    if field_schema:
        schema = {
            **CATEGORY_SCHEMA,
            "properties": {**CATEGORY_SCHEMA["properties"], "fields": field_schema},
        }
        system += (
            " You also say which "
            + ", ".join(missing)
            + " the meeting belongs to, using the attendees, their organisations "
            "and what was discussed. Leave one empty rather than guess."
        )

    result = complete_json(
        config,
        system,
        f"Meeting:\n{context}{known}{field_known}",
        schema,
        max_tokens=int(config.get("category_max_tokens", 2000)),
    )
    if not result:
        return None

    names = _dedupe(result.get("categories") or [])[:MAX_TAGS_PER_MEETING]
    if has_names and not overwrite:
        names = read_tags(folder)
    answered = result.get("fields") if isinstance(result.get("fields"), dict) else {}
    merged = read_fields(folder)
    for field in missing:
        value = str(answered.get(field) or "").strip()
        if value:
            merged[field] = value
    if not names and not merged:
        return None
    return write_tags(folder, names, merged) or names


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

        filled = read_fields(path)
        extra = "".join(
            f", {field}: {filled[field]}" for field in group_fields(config) if field in filled
        )
        print(f"✓ {path.name}: {', '.join(names)}{extra}")
        # Feed new categories back so later meetings in the same run reuse them.
        for name in names:
            if name not in vocabulary:
                vocabulary.append(name)

    return 1 if failures == len(folders) else 0


def categorise_quietly(folder, config):
    """Label a meeting that just got its notes, without ever failing the run.

    Categories are what the app groups meetings by, and nobody tags a hundred
    meetings by hand. Doing it as each meeting is filed keeps the grouping
    current without a separate pass. A meeting that already has categories is
    left alone.
    """
    if not config.get("auto_categorise", True) or not is_configured(config):
        return None
    try:
        destination = config.get("destination_directory") or Path(folder).parent
        names = categorise_meeting(folder, config, existing_vocabulary(destination))
    except Exception as e:
        print(f"  Warning: could not categorise ({type(e).__name__}: {e})")
        return None
    if names:
        print(f"  ✓ Categories: {', '.join(names)}")
    return names


def run_tag(args, config):
    """``transcribe tag <folder>`` -- show or change a meeting's categories and fields."""
    folder = None
    add, remove, sets, unsets = [], [], {}, []
    index = 0
    while index < len(args):
        arg = args[index]
        if arg in {"--add", "--remove", "--set", "--unset"}:
            if index + 1 >= len(args):
                print(f"✗ {arg} needs a value")
                return 1
            value = args[index + 1]
            index += 2
            if arg == "--add":
                add.append(value)
            elif arg == "--remove":
                remove.append(value)
            elif arg == "--unset":
                unsets.append(value)
            else:
                field, separator, text = value.partition("=")
                if not separator or not field.strip():
                    print(f"✗ --set takes FIELD=VALUE, not {value!r}")
                    return 1
                sets[field.strip()] = text.strip()
            continue
        if folder is None and not arg.startswith("--"):
            folder = arg
        index += 1

    if folder is None or not Path(folder).is_dir():
        print("Usage: transcribe tag <meeting folder> [--add CATEGORY] [--remove CATEGORY]")
        print("                                       [--set FIELD=VALUE] [--unset FIELD]")
        return 1

    names = read_tags(folder)
    fields = read_fields(folder)
    if add or remove or sets or unsets:
        dropped = {name.lower() for name in remove}
        names = [name for name in names if name.lower() not in dropped] + add
        fields.update({key: value for key, value in sets.items() if value})
        for key in unsets + [key for key, value in sets.items() if not value]:
            fields.pop(key, None)
        names = write_tags(folder, names, fields)
        fields = read_fields(folder)

    print(f"Categories: {', '.join(names) if names else '(none)'}")
    for key in sorted(fields):
        print(f"{key}: {fields[key]}")
    return 0
