"""Game translations (like AGS translation files): <game_dir>/lang/<locale>.po, gettext format.

`python3 tools/adv.py i18n LOCALE` collects every text the player can see and creates or updates
the file: speech lines, dialog options, item and character names, the title (from the scripts,
via `--adv-strings`), hotspot names and descriptions (scenes), chapter titles (scene/*.json) and
texts in the game's GDScript (`tr("...")` and speech-like literals "Name: text").
Existing translations are kept; texts no longer in the game are kept at the end as obsolete
(#~). An empty msgstr means "not translated yet": the game shows the original text.
"""
import json
import re
import tempfile
from pathlib import Path

TSCN_PROP = re.compile(r'^(display_name|description) = "((?:[^"\\]|\\.)*)"', re.M)
GD_TR = re.compile(r'\btr\("((?:[^"\\]|\\.)*)"\)')
GD_SPEECH = re.compile(r'"((?:[A-Z][a-z]+(?: [A-Z][a-z]+)?): (?:[^"\\]|\\.)*)"')


def game_dir(root):
    proj = (root / "project.godot").read_text(encoding="utf-8")
    m = re.search(r'^(?:avventura/)?general/game_dir="res://([^"]*)"', proj, re.M)
    return root / (m.group(1) if m else "game")


def unescape(s):
    return s.encode("utf-8").decode("unicode_escape").encode("latin-1").decode("utf-8")


def po_quote(s):
    s = s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\t", "\\t")
    return '"%s"' % s


def parse_po(text):
    """[(msgid, msgstr, flags, obsolete)] in file order, header excluded."""
    out = []
    entry = {"id": None, "str": "", "flags": "", "field": None, "obsolete": False}

    def flush():
        if entry["id"]:
            out.append((entry["id"], entry["str"], entry["flags"], entry["obsolete"]))
        entry.update({"id": None, "str": "", "flags": "", "field": None, "obsolete": False})

    for raw in text.splitlines() + [""]:
        line = raw.strip()
        obsolete = line.startswith("#~")
        if obsolete:
            line = line[2:].strip()
        if not line:
            flush()
            continue
        if line.startswith("#,"):
            entry["flags"] = line[2:].strip()
        elif line.startswith("#"):
            continue
        elif line.startswith("msgid "):
            if entry["field"] == "str":
                flush()
            entry["id"] = unescape(line[6:].strip()[1:-1])
            entry["field"] = "id"
            entry["obsolete"] = obsolete
        elif line.startswith("msgstr "):
            entry["str"] = unescape(line[7:].strip()[1:-1])
            entry["field"] = "str"
        elif line.startswith('"'):
            if entry["field"] == "id":
                entry["id"] += unescape(line[1:-1])
            elif entry["field"] == "str":
                entry["str"] += unescape(line[1:-1])
    return out


def collect(root, gdir, script_strings):
    """[(text, comment, ref)] in a stable order: scripts first, then scenes, chapters, GDScript."""
    out = []
    for s in script_strings:
        out.append((s["text"], s["who"], "%s:%d" % (s["file"], s["line"])))
    for p in sorted(gdir.rglob("*.tscn")):
        text = p.read_text(encoding="utf-8")
        for m in TSCN_PROP.finditer(text):
            line = text.count("\n", 0, m.start()) + 1
            out.append((unescape(m.group(2)), "hotspot" if m.group(1) == "display_name" else "look",
                        "%s:%d" % (p.relative_to(gdir), line)))
    for p in sorted((gdir / "scene").glob("*.json")):
        try:
            title = json.loads(p.read_text(encoding="utf-8")).get("meta", {}).get("chapter", "")
        except ValueError:
            title = ""
        if title:
            out.append((title, "chapter", str(p.relative_to(gdir))))
    for p in sorted(gdir.rglob("*.gd")):
        text = p.read_text(encoding="utf-8")
        for rx in (GD_TR, GD_SPEECH):
            for m in rx.finditer(text):
                line = text.count("\n", 0, m.start()) + 1
                out.append((unescape(m.group(1)), "gdscript", "%s:%d" % (p.relative_to(gdir), line)))
    return [o for o in out if o[0].strip()]


def write_po(path, locale, entries, old, obsolete):
    lines = ['msgid ""', 'msgstr ""', po_quote("Language: %s\n" % locale),
             po_quote("Content-Type: text/plain; charset=UTF-8\n"), ""]
    for text, (comments, refs) in entries.items():
        for c in sorted(set(comments)):
            lines.append("#. %s" % c)
        lines.append("#: " + " ".join(refs[:4]))
        msgstr, flags = old.get(text, ("", ""))
        if flags:
            lines.append("#, " + flags)
        lines.append("msgid " + po_quote(text))
        lines.append("msgstr " + po_quote(msgstr))
        lines.append("")
    for text, msgstr in obsolete:
        lines.append("#~ msgid " + po_quote(text))
        lines.append("#~ msgstr " + po_quote(msgstr))
        lines.append("")
    path.write_text("\n".join(lines), encoding="utf-8")


def run(root, godot, locale):
    gdir = game_dir(root)
    with tempfile.NamedTemporaryFile(suffix=".json", delete=False) as f:
        tmp = Path(f.name)
    code, out = godot(["--", "--adv-strings=" + str(tmp)])
    if code != 0 or not tmp.exists() or tmp.stat().st_size == 0:
        print(out)
        return 1
    script_strings = json.loads(tmp.read_text(encoding="utf-8"))
    tmp.unlink()
    entries = {}
    for text, comment, ref in collect(root, gdir, script_strings):
        c, r = entries.setdefault(text, ([], []))
        c.append(comment)
        r.append(ref)
    path = gdir / "lang" / (locale + ".po")
    old = {}
    if path.exists():
        for msgid, msgstr, flags, _obs in parse_po(path.read_text(encoding="utf-8")):
            if msgstr or msgid not in old:
                old[msgid] = (msgstr, flags)
    obsolete = [(k, v[0]) for k, v in old.items() if k not in entries and v[0]]
    path.parent.mkdir(exist_ok=True)
    write_po(path, locale, entries, old, obsolete)
    done = sum(1 for t in entries if old.get(t, ("", ""))[0])
    print("%s: %d texts, %d translated, %d to translate, %d obsolete" %
          (path.relative_to(root), len(entries), done, len(entries) - done, len(obsolete)))
    return 0
