"""Translates AGS script (.asc) into AdvScript handlers.

Covers the common adventure vocabulary (Say, Walk, inventory, rooms, dialogs, cutscenes,
Wait, views, the 9-verb "Verbs" template dispatch, ActiveInventory checks...). Anything
else is kept as a `# TODO AGS:` comment with the original code, so nothing is lost and a
person (or Claude) can finish it by hand.
"""
import re

GAME_FPS = 40

VERB_ACTIONS = {
    "eGA_LookAt": "look", "eGA_Open": "open", "eGA_Close": "close", "eGA_Use": "use",
    "eGA_Push": "push", "eGA_Pull": "pull", "eGA_PickUp": "pick", "eGA_TalkTo": "talk",
    "eGA_GiveTo": "give", "eGA_UseInv": "useinv", "eGA_WalkTo": "walk",
}
SUFFIX_VERBS = {
    "Look": "look", "Interact": "use", "Talk": "talk", "PickUp": "pick", "UseInv": "useinv",
    "AnyClick": "any", "OtherClick": "any", "WalksOnto": "walk_onto", "WalksOff": "walk_off",
    "Mode8": "mode8", "Mode9": "mode9",
}
DIRECTIONS = {"eDirectionLeft": "left", "eDirectionRight": "right", "eDirectionUp": "up",
              "eDirectionDown": "down", "eDirectionDownLeft": "left", "eDirectionDownRight": "right",
              "eDirectionUpLeft": "left", "eDirectionUpRight": "right"}


def snake(name):
    s = re.sub(r"([a-z0-9])([A-Z])", r"\1_\2", name)
    s = re.sub(r"[^A-Za-z0-9_]", "_", s)
    return s.lower().strip("_")


def strip_prefix(name, prefix):
    if len(name) > 1 and name[0] == prefix and name[1].isupper():
        return name[1:]
    return name


def char_id(name):
    if name == "player":
        return "player"
    return snake(strip_prefix(name, "c"))


def item_id(name):
    return snake(strip_prefix(name, "i"))


def obj_id(name):
    return snake(strip_prefix(name, "o"))


def hotspot_id(name):
    return snake(strip_prefix(name, "h"))


def room_id(n):
    return "room%s" % n


# --- tokenizer ----------------------------------------------------------------------------

TOKEN = re.compile(r"""
    (?P<ws>\s+) | (?P<lc>//[^\n]*) | (?P<bc>/\*.*?\*/) |
    (?P<str>"(?:\\.|[^"\\])*") | (?P<chr>'(?:\\.|[^'\\])') |
    (?P<num>\d+\.\d+|\d+) | (?P<id>[A-Za-z_][A-Za-z0-9_]*) |
    (?P<op>\+\+|--|\+=|-=|\*=|/=|==|!=|<=|>=|&&|\|\||->|[{}()\[\];,.*!<>+\-/%=&|?:^~])
""", re.S | re.X)


class Tok:
    def __init__(self, kind, val, pos):
        self.kind, self.val, self.pos = kind, val, pos

    def __repr__(self):
        return "%s:%s" % (self.kind, self.val)


def tokenize(src):
    out = []
    pos = 0
    while pos < len(src):
        m = TOKEN.match(src, pos)
        if not m:
            pos += 1
            continue
        kind = m.lastgroup
        if kind not in ("ws", "lc", "bc"):
            out.append(Tok(kind, m.group(kind), m.start()))
        pos = m.end()
    out.append(Tok("eof", "", len(src)))
    return out


# --- parser ---------------------------------------------------------------------------------

class Parser:
    def __init__(self, src):
        self.src = src
        self.t = tokenize(src)
        self.i = 0

    def peek(self, k=0):
        return self.t[min(self.i + k, len(self.t) - 1)]

    def next(self):
        t = self.t[self.i]
        self.i = min(self.i + 1, len(self.t) - 1)
        return t

    def accept(self, val):
        if self.peek().val == val and self.peek().kind in ("op", "id"):
            self.i += 1
            return True
        return False

    def expect(self, val):
        if not self.accept(val):
            raise SyntaxError("expected '%s' near %r" % (val, self.src[self.peek().pos:self.peek().pos + 40]))

    def text(self, a, b):
        return self.src[a:b].strip()

    # top level: returns {"functions": {name: {"params", "body", "src"}}, "globals": [src...]}
    def program(self):
        funcs, globs = {}, []
        while self.peek().kind != "eof":
            start = self.peek().pos
            if self._looks_like_function():
                name, params, body, end = self._function()
                funcs[name] = {"params": params, "body": body, "src": self.text(start, end)}
            else:
                self._skip_declaration()
                globs.append(self.text(start, self.t[self.i - 1].pos + len(self.t[self.i - 1].val)))
        return {"functions": funcs, "globals": globs}

    def _looks_like_function(self):
        j = self.i
        while self.t[j].kind == "id" or self.t[j].val == "*":
            j += 1
        return j > self.i and self.t[j].val == "(" and self.t[j - 1].kind == "id" and \
            self.t[self.i].val not in ("import", "export")

    def _function(self):
        while self.peek().val != "(":
            name = self.next().val
        params = []
        self.expect("(")
        depth = 1
        cur = []
        while depth:
            t = self.next()
            if t.val == "(":
                depth += 1
            elif t.val == ")":
                depth -= 1
                if depth == 0:
                    break
            if t.val == "," and depth == 1:
                params.append(cur)
                cur = []
            else:
                cur.append(t.val)
        if cur:
            params.append(cur)
        params = [p[-1] for p in params if p and p[-1] not in ("void",)]
        if self.peek().val == ";":
            self.next()
            return name, params, None, self.t[self.i - 1].pos + 1
        body = self.block()
        return name, params, body, self.t[self.i - 1].pos + 1

    def _skip_declaration(self):
        depth = 0
        while self.peek().kind != "eof":
            t = self.next()
            if t.val == "{":
                depth += 1
            elif t.val == "}":
                depth -= 1
                if depth <= 0 and self.peek().val == ";":
                    self.next()
                    return
                if depth <= 0:
                    return
            elif t.val == ";" and depth == 0:
                return

    def block(self):
        self.expect("{")
        stmts = []
        while not self.accept("}"):
            if self.peek().kind == "eof":
                break
            stmts.append(self.statement())
        return stmts

    def statement(self):
        start = self.peek().pos
        t = self.peek()
        if t.val == "{":
            return {"k": "block", "body": self.block()}
        if t.val == ";":
            self.next()
            return {"k": "empty"}
        if t.val == "if":
            self.next()
            self.expect("(")
            cond = self.expr()
            self.expect(")")
            then = self.statement()
            els = None
            if self.accept("else"):
                els = self.statement()
            return {"k": "if", "cond": cond, "then": then, "else": els, "src": self.text(start, self.peek().pos)}
        if t.val == "while":
            self.next()
            self.expect("(")
            cond = self.expr()
            self.expect(")")
            return {"k": "while", "cond": cond, "body": self.statement(), "src": self.text(start, self.peek().pos)}
        if t.val in ("return",):
            self.next()
            val = None if self.peek().val == ";" else self.expr()
            self.accept(";")
            return {"k": "return", "val": val}
        if t.val in ("for", "switch", "do"):
            return self._raw_statement(start)
        # declaration: Type name [= expr];  Type *name;
        if t.kind == "id" and (self.peek(1).kind == "id" or (self.peek(1).val == "*" and self.peek(2).kind == "id")) \
                and t.val not in ("return", "else"):
            self.next()
            self.accept("*")
            name = self.next().val
            val = None
            if self.accept("["):
                return self._raw_statement(start)
            if self.accept("="):
                val = self.expr()
            while self.accept(","):
                self.next()
                if self.accept("="):
                    self.expr()
            self.accept(";")
            return {"k": "decl", "name": name, "val": val, "src": self.text(start, self.peek().pos)}
        try:
            e = self.expr()
            self.accept(";")
            return {"k": "expr", "e": e, "src": self.text(start, self.peek().pos)}
        except SyntaxError:
            self.i = self._index_at(start)
            return self._raw_statement(start)

    def _index_at(self, pos):
        for k, t in enumerate(self.t):
            if t.pos >= pos:
                return k
        return len(self.t) - 1

    def _raw_statement(self, start):
        depth = 0
        while self.peek().kind != "eof":
            t = self.next()
            if t.val == "{":
                depth += 1
            elif t.val == "}":
                depth -= 1
                if depth == 0:
                    break
            elif t.val == ";" and depth == 0:
                break
        return {"k": "raw", "src": self.text(start, self.t[self.i - 1].pos + 1)}

    # expressions (precedence climbing)
    BIN = [["||"], ["&&"], ["|"], ["^"], ["&"], ["==", "!="], ["<", ">", "<=", ">="], ["+", "-"], ["*", "/", "%"]]

    def expr(self):
        left = self.binary(0)
        if self.peek().val in ("=", "+=", "-=", "*=", "/="):
            op = self.next().val
            return {"k": "assign", "op": op, "target": left, "val": self.expr()}
        return left

    def binary(self, level):
        if level == len(self.BIN):
            return self.unary()
        left = self.binary(level + 1)
        while self.peek().val in self.BIN[level] and self.peek().kind == "op":
            op = self.next().val
            left = {"k": "bin", "op": op, "a": left, "b": self.binary(level + 1)}
        return left

    def unary(self):
        if self.peek().val in ("!", "-") and self.peek().kind == "op":
            op = self.next().val
            return {"k": "un", "op": op, "a": self.unary()}
        if self.peek().val in ("++", "--"):
            op = self.next().val
            return {"k": "incdec", "op": op, "a": self.unary()}
        e = self.postfix()
        if self.peek().val in ("++", "--"):
            return {"k": "incdec", "op": self.next().val, "a": e}
        return e

    def postfix(self):
        e = self.primary()
        while True:
            if self.accept("."):
                e = {"k": "member", "obj": e, "name": self.next().val}
            elif self.peek().val == "(" and self.peek().kind == "op":
                self.next()
                args = []
                if not self.accept(")"):
                    while True:
                        args.append(self.expr())
                        if self.accept(")"):
                            break
                        self.expect(",")
                e = {"k": "call", "fn": e, "args": args}
            elif self.accept("["):
                idx = self.expr()
                self.expect("]")
                e = {"k": "index", "obj": e, "idx": idx}
            else:
                return e

    def primary(self):
        t = self.next()
        if t.kind == "num":
            return {"k": "num", "v": t.val}
        if t.kind == "str":
            return {"k": "str", "v": bytes(t.val[1:-1], "utf-8").decode("unicode_escape").encode("latin-1").decode("utf-8", "replace")}
        if t.kind == "chr":
            return {"k": "num", "v": str(ord(t.val[1:-1][-1]))}
        if t.kind == "id":
            if t.val == "new":
                raise SyntaxError("new")
            return {"k": "id", "v": t.val}
        if t.val == "(":
            e = self.expr()
            self.expect(")")
            return e
        raise SyntaxError("unexpected %r" % t.val)


def dotted(e):
    if e["k"] == "id":
        return e["v"]
    if e["k"] == "member":
        base = dotted(e["obj"])
        return base + "." + e["name"] if base else None
    return None


# --- translation -----------------------------------------------------------------------------

class Untranslatable(Exception):
    pass


class Translator:
    """Turns parsed AGS statements into AdvScript lines (4-space indentation)."""

    def __init__(self, player="player", overlays=(), engine_guis=(), music=()):
        self.player = player  # AGS script name of the main character, e.g. cRay
        self.overlays = set(overlays)        # GUI script names imported as overlays
        self.engine_guis = set(engine_guis)  # GUI script names replaced by the engine's interface
        self.music = set(music)              # audio clips of type Music
        self.excluded = set()                # script functions that are not imported
        self.todo = 0
        self.translated = 0
        self.used_items = set()
        self.used_chars = set()
        self.used_rooms = set()
        self.used_sounds = set()

    # expressions --------------------------------------------------------------
    def expr(self, e):
        k = e["k"]
        if k == "num":
            return e["v"]
        if k == "str":
            return '"%s"' % e["v"].replace('"', '\\"')
        if k == "id":
            v = e["v"]
            if v in ("true", "false", "null"):
                return v
            if v[:1] in "ic" and len(v) > 1 and v[1].isupper():
                raise Untranslatable(v)
            return snake(v)
        if k == "un":
            return ("not " if e["op"] == "!" else "-") + self.expr(e["a"])
        if k == "bin":
            ops = {"&&": "and", "||": "or"}
            a, b = e["a"], e["b"]
            # player.ActiveInventory == iX
            if e["op"] in ("==", "!=") and b["k"] == "id" and b["v"].startswith("i"):
                d = dotted(a) or ""
                if d.endswith(".ActiveInventory"):
                    raise Untranslatable("ActiveInventory")
            # cX.Room == N
            d = dotted(a) or ""
            if d.endswith(".Room") and b["k"] == "num":
                who = d[:-5]
                fn = "room()" if who in ("player", self.player) else "room_of(%s)" % char_id(who)
                return '%s %s "%s"' % (fn, e["op"], room_id(b["v"]))
            if e["op"] in ("&", "|", "^"):
                raise Untranslatable("bitwise")
            return "%s %s %s" % (self.expr(a), ops.get(e["op"], e["op"]), self.expr(b))
        if k == "call":
            name = dotted(e["fn"]) or ""
            args = e["args"]
            if name.endswith(".HasInventory") and args and args[0]["k"] == "id":
                who = name[:-13]
                item = item_id(args[0]["v"])
                self.used_items.add(item)
                if who in ("player", self.player):
                    return "has(%s)" % item
                return "has(%s, %s)" % (item, char_id(who))
            if name == "HasPlayerBeenInRoom" and args and args[0]["k"] == "num":
                return "visited(%s)" % room_id(args[0]["v"])
            if name == "Random" and args:
                return "random(0, %s)" % self.expr(args[0])
            if name == "Game.DoOnceOnly":
                raise Untranslatable("DoOnceOnly")
            raise Untranslatable(name)
        if k == "member":
            d = dotted(e) or ""
            if d in ("player.Room",):
                return "room()"
            raise Untranslatable(d)
        raise Untranslatable(k)

    def say_text(self, e):
        if e["k"] == "str":
            return e["v"]
        if e["k"] == "bin" and e["op"] == "+":
            return self.say_text(e["a"]) + self.say_text(e["b"])
        return "{%s}" % self.expr(e)

    # statements ----------------------------------------------------------------
    def block(self, stmts, ind):
        out = []
        i = 0
        while i < len(stmts):
            s = stmts[i]
            if s["k"] == "expr" and self._is_call(s, "StartCutscene"):
                # gather until EndCutscene (or end of block) into a cutscene: block
                j = i + 1
                while j < len(stmts) and not (stmts[j]["k"] == "expr" and self._is_call(stmts[j], "EndCutscene")):
                    j += 1
                out.append(ind + "cutscene:")
                body = self.block(stmts[i + 1:j], ind + "    ")
                out += body if body else [ind + "    wait 0"]
                i = j + 1
                continue
            out += self.stmt(s, ind)
            i += 1
        return out

    @staticmethod
    def _body(lines, ind):
        """A block needs at least one real statement: comments alone get a no-op."""
        if not any(not l.strip().startswith("#") for l in lines):
            lines = list(lines) + [ind + "wait 0"]
        return lines

    def _is_call(self, s, name):
        e = s["e"]
        return e["k"] == "call" and dotted(e["fn"]) == name

    def todo_lines(self, src, ind):
        self.todo += 1
        return [ind + "# TODO AGS: " + line.strip() for line in src.strip().splitlines() if line.strip()]

    def stmt(self, s, ind):
        k = s["k"]
        if k in ("empty",):
            return []
        if k == "block":
            return self.block(s["body"], ind)
        if k == "return":
            return [ind + "stop"]
        if k == "decl":
            if s["val"] is None:
                return []
            try:
                return [ind + "set %s = %s" % (snake(s["name"]), self.expr(s["val"]))]
            except Untranslatable:
                return self.todo_lines(s["src"], ind)
        if k == "if":
            return self.if_stmt(s, ind)
        if k == "while":
            try:
                cond = self.expr(s["cond"])
            except Untranslatable:
                return self.todo_lines(s["src"], ind)
            body = self.stmt(s["body"], ind + "    ")
            return [ind + "while %s:" % cond] + self._body(body, ind + "    ")
        if k == "expr":
            try:
                lines = self.expr_stmt(s["e"], ind)
                self.translated += 1
                return lines
            except Untranslatable:
                return self.todo_lines(s["src"], ind)
        return self.todo_lines(s.get("src", ""), ind)

    def if_stmt(self, s, ind, kw="if"):
        cond = s["cond"]
        if cond["k"] == "call" and dotted(cond["fn"]) == "Game.DoOnceOnly":
            body = self.stmt(s["then"], ind + "    ")
            return [ind + "once:", ind + "    do:"] + ["    " + l for l in (body or [ind + "    wait 0"])]
        if cond["k"] == "call" and dotted(cond["fn"]) == "Verbs.MovePlayer" and len(cond["args"]) == 2:
            try:
                walk = ind + "walk to %s, %s" % (self.expr(cond["args"][0]), self.expr(cond["args"][1]))
            except Untranslatable:
                return self.todo_lines(s["src"], ind)
            return [walk] + self.stmt(s["then"], ind)
        try:
            c = self.expr(cond)
        except Untranslatable:
            return self.todo_lines(s["src"], ind)
        out = [ind + "%s %s:" % (kw, c)]
        out += self._body(self.stmt(s["then"], ind + "    "), ind + "    ")
        els = s["else"]
        if els is not None:
            if els["k"] == "if":
                sub = self.if_stmt(els, ind, "elif")
                if sub and sub[0].strip().startswith("elif"):
                    out += sub
                    return out
                out += [ind + "else:"] + ["    " + l for l in sub]
            else:
                out += [ind + "else:"] + self._body(self.stmt(els, ind + "    "), ind + "    ")
        return out

    def expr_stmt(self, e, ind):
        k = e["k"]
        if k == "assign":
            target = dotted(e["target"]) or ""
            val = e["val"]
            if target.endswith(".Visible") and val["k"] == "id" and val["v"] in ("true", "false"):
                obj = target[:-8]
                if obj.startswith("o") and len(obj) > 1 and obj[1].isupper():
                    return [ind + ("show " if val["v"] == "true" else "hide ") + obj_id(obj)]
                if obj in self.overlays:
                    return [ind + ("show " if val["v"] == "true" else "hide ") + gui_id(obj)]
                if obj in self.engine_guis:
                    return [ind + "# AGS: %s is replaced by the engine's interface" % obj]
                raise Untranslatable("gui")
            if target.endswith(".Enabled") and val["k"] == "id":
                obj = target[:-8]
                fn = hotspot_id if obj.startswith("h") else obj_id
                return [ind + ("enable " if val["v"] == "true" else "disable ") + fn(obj)]
            if e["target"]["k"] == "id":
                op = e["op"]
                if op in ("=", "+=", "-="):
                    return [ind + "set %s %s %s" % (snake(e["target"]["v"]), op, self.expr(val))]
            raise Untranslatable(target)
        if k == "incdec":
            if e["a"]["k"] == "id":
                return [ind + "set %s %s 1" % (snake(e["a"]["v"]), "+=" if e["op"] == "++" else "-=")]
            raise Untranslatable("incdec")
        if k != "call":
            raise Untranslatable(k)
        name = dotted(e["fn"]) or ""
        args = e["args"]
        obj, _, method = name.rpartition(".")
        if name == "Wait" and args:
            frames = self.expr(args[0])
            if frames.isdigit():
                return [ind + "wait %s" % _fmt(int(frames) / float(GAME_FPS))]
            return [ind + "wait %s / %d" % (frames, GAME_FPS)]
        if name in ("Display", "DisplayAt") and args:
            text = args[-1] if name == "Display" else args[-1]
            return [ind + "narrator: " + self.say_text(args[0] if name == "Display" else text)]
        if name == "Verbs.Unhandled" or name == "Unhandled":
            return []
        if name in ("EndCutscene",):
            return []
        if name == "PlayVideo" and args:
            return [ind + "video %s" % args[0]["v"].rsplit(".", 1)[0] if args[0]["k"] == "str" else ""]
        if method == "SayAt" and obj and len(args) == 4 and args[0]["k"] == "num" and args[1]["k"] == "num":
            who = char_id(obj) if obj != self.player else "player"
            self.used_chars.add(char_id(obj))
            return [ind + "%s@%s,%s: %s" % (who, args[0]["v"], args[1]["v"], self.say_text(args[3]))]
        if method in ("Say", "SayBackground", "Think") and obj and args:
            who = char_id(obj) if obj != self.player else "player"
            self.used_chars.add(char_id(obj))
            line = "%s: %s" % (who, self.say_text(args[0]))
            if method == "SayBackground":
                return [ind + "bg:", ind + "    " + line]
            return [ind + line]
        if method == "Walk" and obj and len(args) >= 2:
            who = char_id(obj) if obj != self.player else "player"
            flags = [dotted(a) for a in args[2:]]
            suffix = (" nowait" if "eNoBlock" in flags else "") + (" anywhere" if "eAnywhere" in flags else "")
            dx = _relative(args[0], obj + ".x")
            dy = _relative(args[1], obj + ".y")
            if dx is not None and dy is not None:
                return [ind + "walk %s by %s, %s%s" % (who, dx, dy, suffix)]
            return [ind + "walk %s to %s, %s%s" % (who, self.expr(args[0]), self.expr(args[1]), suffix)]
        if method == "FaceCharacter" and args and args[0]["k"] == "id":
            return [ind + "face %s %s" % (char_id(obj), char_id(args[0]["v"]))]
        if method == "FaceDirection" and args:
            d = DIRECTIONS.get(dotted(args[0]) or "")
            if d:
                return [ind + "face %s %s" % (char_id(obj), d)]
        if method in ("AddInventory", "LoseInventory") and args and args[0]["k"] == "id":
            item = item_id(args[0]["v"])
            self.used_items.add(item)
            op = "add" if method == "AddInventory" else "remove"
            who = "" if obj in ("player", self.player) else (" to " if op == "add" else " from ") + char_id(obj)
            return [ind + "inventory %s %s%s" % (op, item, who)]
        if method == "ChangeRoom" and args and args[0]["k"] == "num":
            r = room_id(args[0]["v"])
            self.used_rooms.add(r)
            pos = ""
            if len(args) >= 3:
                pos = " at %s, %s" % (self.expr(args[1]), self.expr(args[2]))
            if obj in ("player", self.player):
                return [ind + "goto %s%s" % (r, pos)]
            return [ind + "place %s in %s%s" % (char_id(obj), r, pos)]
        if method == "LockView" and args:
            return [ind + "anim %s %s loop" % (char_id(obj), snake(dotted(args[0]) or "view"))]
        if method == "UnlockView":
            return [ind + "anim %s idle" % char_id(obj)]
        if method == "SetAsPlayer":
            return [ind + "control %s" % char_id(obj)]
        if method == "Start" and obj.startswith("d"):
            return [ind + "dialog %s" % snake(obj[1:] if obj[1:2].isupper() else obj)]
        if method == "Play" and obj.startswith("a"):
            s = snake(obj[1:] if obj[1:2].isupper() else obj)
            self.used_sounds.add(s)
            return [ind + ("music %s" if obj in self.music else "sound %s") % s]
        if method == "Stop" and obj.startswith("a"):
            if obj in self.music or not self.music:
                return [ind + "music stop"]
            return []
        if obj == "" and name in self.excluded:
            raise Untranslatable(name)
        if obj == "" and re.match(r"^[a-z]\w*$", name) and all(a["k"] in ("num", "str", "id") for a in args):
            # call of a script function defined in the game
            arg = "(%s)" % ", ".join(self.expr(a) for a in args) if args else ""
            return [ind + "call %s%s" % (snake(name), arg)]
        raise Untranslatable(name)


def gui_id(name):
    """gKrug -> krug"""
    return snake(name[1:] if name[:1] == "g" and name[1:2].isupper() else name)


def _relative(e, base):
    """cRay.x + 789 -> 789 ; cRay.x - 376 -> -376 ; cRay.x -> 0"""
    if dotted(e) == base:
        return "0"
    if e["k"] == "bin" and e["op"] in ("+", "-") and dotted(e["a"]) == base and e["b"]["k"] == "num":
        if int(e["b"]["v"]) == 0:
            return "0"
        return ("-" if e["op"] == "-" else "") + e["b"]["v"]
    return None


def _fmt(x):
    s = ("%.2f" % x).rstrip("0").rstrip(".")
    return s or "0"


# --- handlers ---------------------------------------------------------------------------------

def split_by_verb(stmts):
    """Splits a Verbs-template dispatch (if UsedAction(eGA_X) ... else if ...) into
    {verb: [statements]}; statements outside any verb branch go to None."""
    out = {}

    def add(verb, items):
        out.setdefault(verb, []).extend(items)

    def walk(stmts, prefix):
        rest = []
        for s in stmts:
            if s["k"] == "if":
                verbs = _used_actions(s["cond"])
                if verbs:
                    for v in verbs:
                        add(v, prefix + [s["then"]])
                    if s["else"] is not None:
                        walk([s["else"]], prefix)
                    continue
                c = s["cond"]
                if c["k"] == "call" and dotted(c["fn"]) == "Verbs.MovePlayer":
                    inner = walk_inner(s["then"], prefix + [{"k": "movep", "cond": c}])
                    if not inner:
                        rest.append(s)
                    if s["else"] is not None:
                        walk([s["else"]], prefix)
                    continue
            if s["k"] == "block":
                walk(s["body"], prefix)
                continue
            rest.append(s)
        if rest:
            add(None, prefix + rest)

    def walk_inner(stmt, prefix):
        body = stmt["body"] if stmt["k"] == "block" else [stmt]
        if any(s["k"] == "if" and _used_actions(s["cond"]) for s in body):
            walk(body, prefix)
            return True
        return False

    walk(stmts, [])
    return out


def _used_actions(c):
    if c["k"] == "call" and dotted(c["fn"]) in ("Verbs.UsedAction", "UsedAction") and c["args"]:
        a = dotted(c["args"][0]) or ""
        return [VERB_ACTIONS[a]] if a in VERB_ACTIONS else None
    if c["k"] == "bin" and c["op"] == "||":
        a, b = _used_actions(c["a"]), _used_actions(c["b"])
        if a and b:
            return a + b
    return None


def split_by_item(stmts):
    """`if (player.ActiveInventory == iX) {...} else ...` -> {item_or_None: [statements]}.
    Statements before the first ActiveInventory check (a walk...) are shared by every branch."""
    flat = []
    for s in stmts:
        c = s.get("cond") if s["k"] == "if" else None
        if c and c["k"] == "call" and dotted(c["fn"]) == "Verbs.MovePlayer" and s["else"] is None:
            flat.append({"k": "if", "cond": c, "then": {"k": "block", "body": []}, "else": None, "src": ""})
            flat += s["then"]["body"] if s["then"]["k"] == "block" else [s["then"]]
        elif s["k"] == "block":
            flat += s["body"]
        else:
            flat.append(s)
    lead = []
    while flat and not (flat[0]["k"] == "if" and _active_item(flat[0]["cond"])):
        lead.append(flat.pop(0))
    if not flat:
        return {None: lead}
    out = _split_items(flat)
    return {k: lead + v for k, v in out.items()}


def _split_items(stmts):
    out = {}
    for s in stmts:
        if s["k"] == "if":
            node = s
            matched = False
            while node is not None and node["k"] == "if":
                item = _active_item(node["cond"])
                if item is None:
                    break
                matched = True
                out.setdefault(item, []).append(node["then"])
                node = node["else"]
            if matched:
                if node is not None:
                    out.setdefault(None, []).append(node)
                continue
        out.setdefault(None, []).append(s)
    return out


def _active_item(c):
    if c["k"] == "bin" and c["op"] == "==" and c["b"]["k"] == "id":
        d = dotted(c["a"]) or ""
        if d.endswith(".ActiveInventory"):
            return item_id(c["b"]["v"])
    return None


def handler_target(func_name):
    """'cMJoe_AnyClick' -> ('character', 'm_joe', 'any') ; 'hDoor_Look' -> ('hotspot', 'door', 'look')."""
    if "_" not in func_name:
        return None
    base, _, suffix = func_name.rpartition("_")
    verb = SUFFIX_VERBS.get(suffix)
    if verb is None:
        return None
    m = re.match(r"^region(\d+)$", base)
    if m:
        return ("region", "region%s" % m.group(1), verb)
    if len(base) > 1 and base[1].isupper():
        kind = {"c": "character", "i": "item", "h": "hotspot", "o": "object"}.get(base[0])
        if kind:
            fn = {"character": char_id, "item": item_id, "hotspot": hotspot_id, "object": obj_id}[kind]
            return (kind, fn(base), verb)
    if base.startswith("hHotspot") or base.startswith("oObject"):
        return ("hotspot" if base[0] == "h" else "object", snake(base[1:]), verb)
    return None


class Handlers:
    """Collects `on ...:` blocks; on duplicates the more specific AGS function wins
    (cX_Look beats the LookAt branch of cX_AnyClick), the other is kept commented out."""

    def __init__(self):
        self.order = []
        self.blocks = {}

    def add(self, head, body, tr, prio, origin):
        lines = _emit(head, body, tr)
        if not lines:
            return
        if head in self.blocks:
            old_prio, old_lines, old_origin = self.blocks[head]
            loser, keep = (lines, (old_prio, old_lines, old_origin)) if prio <= old_prio else (old_lines, (prio, lines, origin))
            loser_origin = origin if prio <= old_prio else old_origin
            self.blocks[head] = (keep[0], keep[1] + ["# AGS duplicate from %s, not used:" % loser_origin] +
                                 ["# " + l for l in loser if l.strip()] + [""], keep[2])
            return
        self.order.append(head)
        self.blocks[head] = (prio, lines, origin)

    def lines(self):
        out = []
        for h in self.order:
            out += self.blocks[h][1]
        return out


def translate_handlers(funcs, tr, target_names=None):
    """Turns event functions into `on ...:` blocks. Returns (lines, other_function_names)."""
    hs = Handlers()
    out = []
    other = []
    for name, f in funcs.items():
        if f["body"] is None:
            continue
        ht = handler_target(name)
        if ht is None:
            other.append(name)
            continue
        kind, target, verb = ht
        if target_names and target in target_names:
            target = target_names[target]
        if verb in ("walk_onto", "walk_off"):
            hs.add("on %s %s:" % (verb, target), f["body"], tr, 3, name)
            continue
        if verb in ("useinv",):
            parts = split_by_verb(f["body"])
            body = _expand_movep(parts.get("useinv", []) + parts.get(None, []))
            for item, b in split_by_item(body).items():
                hs.add("on use %s on %s:" % (item or "*", target), b, tr, 3, name)
            continue
        if verb in ("any", "talk", "look", "pick", "use"):
            parts = split_by_verb(f["body"])
            if list(parts.keys()) == [None]:
                head = "on * %s:" % target if verb == "any" else "on %s %s:" % (verb, target)
                hs.add(head, parts[None], tr, 1 if verb == "any" else 3, name)
                continue
            for v, body in parts.items():
                if v is None:
                    body = [s for s in body if s["k"] != "movep"]
                    if not _meaningful(body):
                        continue
                    v = verb if verb != "any" else "*"
                prio = 3 if v == verb else 2
                if v == "useinv":
                    for item, b in split_by_item(_expand_movep(body)).items():
                        hs.add("on use %s on %s:" % (item or "*", target), b, tr, prio, name)
                    continue
                head = "on give * to %s:" % target if v == "give" else "on %s %s:" % (v, target)
                hs.add(head, _expand_movep(body), tr, prio, name)
            continue
        out.append("# TODO AGS: event %s (%s) not translated" % (name, verb))
    return hs.lines() + out, other


def _expand_movep(body):
    out = []
    for s in body:
        if s["k"] == "movep":
            c = s["cond"]
            out.append({"k": "if", "cond": c, "then": {"k": "block", "body": []}, "else": None, "src": ""})
        else:
            out.append(s)
    return out


def _meaningful(body):
    for s in body:
        if s["k"] == "expr" and s["e"]["k"] == "call" and dotted(s["e"]["fn"]) in ("Verbs.Unhandled", "Unhandled"):
            continue
        if s["k"] in ("empty",):
            continue
        if s["k"] == "block" and not _meaningful(s["body"]):
            continue
        return True
    return False


def _emit(head, body, tr):
    if head.startswith("#"):
        return [head, ""]
    if not _meaningful(body):
        return []
    lines = tr.block(body, "    ")
    if not [l for l in lines if l.strip() and not l.strip().startswith("#")]:
        lines.append("    wait 0")
    return [head] + lines + [""]


def translate_function(name, f, tr):
    """A non-event function becomes an AdvScript `function`."""
    params = ", ".join(snake(p) for p in f["params"])
    head = "function %s%s:" % (snake(name), "(%s)" % params if params else "")
    lines = tr.block(f["body"] or [], "    ")
    if not [l for l in lines if l.strip() and not l.strip().startswith("#")]:
        lines.append("    wait 0")
    return [head] + lines + [""]
