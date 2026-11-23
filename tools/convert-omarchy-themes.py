#!/usr/bin/env python3
"""Convert omarchy.el's Modus-derived themes into schemacs theme files.

The bundled themes are not face data: each file is a call into
`modus-themes-theme` (modus-themes.el), a generator that expands a palette
into a full face set.  Porting the generator is a different, very large
job; what this does instead is the transcription the etc/themes converter
did - a real Emacs, which carries modus-themes, expands each theme, and
the resulting `theme-settings` (the exact list `custom-theme-set-faces`
and `custom-theme-set-variables` are given) is written out as this tree's
theme file.

    tools/convert-omarchy-themes.py [--emacs EMACS] [--themes DIR]
                                    [--out DIR]

Defaults: emacs on PATH, ~/GITE/omarchy.el/themes,
schemacs/external/omarchy/themes.

Departures, both structural and named in every file's header:
  * the generator is not ported - the faces are the values it produced;
  * Emacs's `nil' is written as `#f' in an attribute value and as `()' in
    quoted data, because this tree's face code is Scheme's and `()' is
    true where Elisp's nil is false.
"""

import argparse
import os
import re
import subprocess
import sys
import tempfile

# ---------------------------------------------------------------------
# An Elisp reader for prin1 output
# ---------------------------------------------------------------------


class Sym(str):
    """A symbol, distinguished from a string."""


class Vec(list):
    """A vector ([...] in prin1 output), as distinct from a list."""


class Dotted:
    def __init__(self, items, tail):
        self.items = items
        self.tail = tail

    def __repr__(self):
        return "Dotted(%r, %r)" % (self.items, self.tail)


class Char:
    def __init__(self, code):
        self.code = code


ESCAPES = {
    "n": "\n", "t": "\t", "r": "\r", "f": "\f", "v": "\v",
    "a": "\a", "b": "\b", "e": "\x1b", "\\": "\\", '"': '"',
}


class Reader:
    def __init__(self, text):
        self.text = text
        self.i = 0

    def eof(self):
        return self.i >= len(self.text)

    def skip(self):
        while not self.eof():
            c = self.text[self.i]
            if c in " \t\n\r":
                self.i += 1
            elif c == ";":
                while not self.eof() and self.text[self.i] != "\n":
                    self.i += 1
            else:
                break

    def read(self):
        self.skip()
        if self.eof():
            raise EOFError
        c = self.text[self.i]
        if c == "(":
            return self.read_list()
        if c == "[":
            return self.read_vector()
        if c == ")":
            raise ValueError("unexpected ) at %d" % self.i)
        if c == "'":
            self.i += 1
            return [Sym("quote"), self.read()]
        if c == '"':
            return self.read_string()
        if c == "#":
            if self.text.startswith("#'", self.i):
                self.i += 2
                return [Sym("function"), self.read()]
            raise ValueError("unsupported # syntax at %d: %r"
                             % (self.i, self.text[self.i:self.i + 10]))
        if c == "?":
            return self.read_char()
        if c in ")]":
            raise ValueError("unexpected %r at %d" % (c, self.i))
        return self.read_atom()

    def read_list(self):
        self.i += 1
        items = []
        while True:
            self.skip()
            if self.eof():
                raise EOFError
            c = self.text[self.i]
            if c == ")":
                self.i += 1
                return items
            if c == "." and (self.i + 1 >= len(self.text)
                             or self.text[self.i + 1] in " \t\n\r()[]"):
                self.i += 1
                tail = self.read()
                self.skip()
                if self.eof() or self.text[self.i] != ")":
                    raise ValueError("bad dotted list")
                self.i += 1
                return Dotted(items, tail)
            items.append(self.read())

    def read_vector(self):
        self.i += 1
        items = []
        while True:
            self.skip()
            if self.eof():
                raise EOFError
            if self.text[self.i] == "]":
                self.i += 1
                return Vec(items)
            items.append(self.read())

    def read_string(self):
        self.i += 1
        out = []
        while True:
            if self.eof():
                raise EOFError
            c = self.text[self.i]
            self.i += 1
            if c == '"':
                return "".join(out)
            if c != "\\":
                out.append(c)
                continue
            if self.eof():
                raise EOFError
            e = self.text[self.i]
            self.i += 1
            if e in ESCAPES:
                out.append(ESCAPES[e])
            elif e == "x":
                j = self.i
                while j < len(self.text) and self.text[j] in "0123456789abcdefABCDEF":
                    j += 1
                out.append(chr(int(self.text[self.i:j], 16)))
                self.i = j
            elif e in "01234567":
                j = self.i - 1
                while j < len(self.text) and self.text[j] in "01234567" and j - (self.i - 1) < 3:
                    j += 1
                out.append(chr(int(self.text[self.i - 1:j], 8)))
                self.i = j
            elif e == "C":
                # \C-x, \C-\x etc.  Nothing in these dumps needs it.
                out.append("C")
            else:
                out.append(e)

    def read_char(self):
        self.i += 1
        if self.eof():
            raise EOFError
        c = self.text[self.i]
        self.i += 1
        if c != "\\":
            return Char(ord(c))
        e = self.text[self.i]
        self.i += 1
        return Char(ord(ESCAPES.get(e, e)))

    def read_atom(self):
        start = self.i
        while not self.eof():
            c = self.text[self.i]
            if c in " \t\n\r()[]\";":
                break
            self.i += 1
        tok = self.text[start:self.i]
        if tok == "nil":
            return []
        if tok == "t":
            return Sym("t")
        if re.fullmatch(r"-?[0-9]+", tok):
            return int(tok)
        if re.fullmatch(r"-?[0-9]*\.[0-9]+([eE][-+]?[0-9]+)?", tok) or \
                re.fullmatch(r"-?[0-9]+\.[0-9]*([eE][-+]?[0-9]+)?", tok):
            return float(tok)
        return Sym(tok)


# ---------------------------------------------------------------------
# Emitting Scheme
# ---------------------------------------------------------------------


def scheme_string(s):
    out = ['"']
    for c in s:
        if c == "\\":
            out.append("\\\\")
        elif c == '"':
            out.append('\\"')
        elif c == "\n":
            out.append("\\n")
        elif c == "\t":
            out.append("\\t")
        elif c == "\r":
            out.append("\\r")
        else:
            out.append(c)
    out.append('"')
    return "".join(out)


def scheme_symbol(sym):
    name = str(sym)
    if name == "t":
        # A display conjunct's `t`: the tree's face-spec-set-match-display
        # accepts the symbol as well as `#t`, and the symbol is what a
        # theme file's data carries.
        return "t"
    return name


def data(v, nil_is_empty=True):
    """A value as Scheme *data* (as inside a quote)."""
    if v == []:
        return "()"
    if isinstance(v, Sym):
        return scheme_symbol(v)
    if isinstance(v, str):
        return scheme_string(v)
    if isinstance(v, bool):
        return "#t" if v else "#f"
    if isinstance(v, (int, float)):
        return repr(v)
    if isinstance(v, Char):
        return "(integer->char %d)" % v.code
    if isinstance(v, Vec):
        return "#(" + " ".join(data(x) for x in v) + ")"
    if isinstance(v, list):
        return "(" + " ".join(data(x) for x in v) + ")"
    if isinstance(v, Dotted):
        return "(" + " ".join(data(x) for x in v.items) + " . " + \
            data(v.tail) + ")"
    raise ValueError("cannot emit %r" % (v,))


def spec(v, display=False):
    """A face spec as Scheme data.

    Inside a spec, `nil' in an attribute value is Emacs's false and is
    `#f'; a nil *display* (the first element of an entry) matches every
    display in Emacs (`face-spec-set-match-display`), which is `()`.
    """
    if v == []:
        return "()" if display else "#f"
    if isinstance(v, Sym):
        return scheme_symbol(v)
    if isinstance(v, str):
        return scheme_string(v)
    if isinstance(v, bool):
        return "#t" if v else "#f"
    if isinstance(v, (int, float)):
        return repr(v)
    if isinstance(v, Char):
        return "(integer->char %d)" % v.code
    if isinstance(v, list):
        return "(" + " ".join(spec(x) for x in v) + ")"
    if isinstance(v, Dotted):
        return "(" + " ".join(spec(x) for x in v.items) + " . " + \
            spec(v.tail) + ")"
    raise ValueError("cannot emit %r" % (v,))


def spec_entry(v):
    """One `(DISPLAY . ATTRS)' entry of a spec."""
    if isinstance(v, list) and v and v[0] == []:
        rest = " ".join(spec(x) for x in v[1:])
        return "(()" + (" " + rest if rest else "") + ")"
    return spec(v)


def emit_theme(name, doc, props, settings, header):
    faces = []
    variables = []
    for s in settings:
        if not isinstance(s, list) or len(s) < 4:
            continue
        prop, symbol, _theme, value = s[0], s[1], s[2], s[3]
        if prop == Sym("theme-face"):
            faces.append((symbol, value))
        elif prop == Sym("theme-value"):
            variables.append((symbol, value))

    lines = [header, "", "(import (schemacs theme))", ""]
    lines.append("(define-theme %s" % name)
    lines.append("  " + scheme_string(doc or ""))
    if props:
        prop_items = []
        i = 0
        while i + 1 < len(props):
            prop_items.append(scheme_symbol(props[i]))
            prop_items.append(spec(props[i + 1]))
            i += 2
        lines.append("  (" + " ".join(prop_items) + "))")
    else:
        lines.append("  ())")
    lines.append("")
    lines.append("(custom-theme-set-faces")
    lines.append(" '%s" % name)
    for symbol, value in faces:
        # VALUE is a *list of entries*; each entry is
        # `(DISPLAY . ATTRIBUTE-PLIST)`. The spec's own parentheses are
        # what tell `face-spec-choose` the difference between the spec
        # and one of its entries - dropping them made the display
        # conjunct list read as an entry, which is the error that
        # "expecting pair: class" named.
        if isinstance(value, list):
            if value == []:
                body = "(%s ())" % scheme_symbol(symbol)
            else:
                entries = " ".join(spec_entry(x) for x in value)
                body = "(%s (%s))" % (scheme_symbol(symbol), entries)
        else:
            body = "(%s (%s))" % (scheme_symbol(symbol), spec(value))
        lines.append(" '%s" % body)
    lines.append(")")
    lines.append("")
    if variables:
        lines.append("(custom-theme-set-variables")
        lines.append(" '%s" % name)
        for symbol, value in variables:
            if isinstance(value, Vec):
                exp = data(value)
            elif isinstance(value, list) and value and value[0] == Sym("quote"):
                exp = "'" + data(value[1])
            elif isinstance(value, list) and value:
                # A bare list as a variable's value: these dumps hold
                # only quoted forms, vectors and self-evaluating values
                # (`defcustom` stores the expression unevaluated); a
                # bare list would be code and is refused rather than
                # guessed at.
                raise ValueError("unquoted form as theme variable value: %r"
                                 % (value,))
            else:
                exp = data(value)
            lines.append(" '(%s %s)" % (scheme_symbol(symbol), exp))
        lines.append(")")
    lines.append("")
    return "\n".join(lines)


def run_emacs(emacs, themes_dir):
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    candidates = [os.environ.get("EMACS_ETC_THEMES", ""),
                  os.path.expanduser("~/GITE/emacs/etc/themes"),
                  os.path.join(os.path.dirname(here), "emacs", "etc", "themes")]
    emacs_themes = next((d for d in candidates
                         if d and os.path.isdir(d)), "")
    script = r"""
(add-to-list 'load-path %s)
(add-to-list 'load-path %s)
(add-to-list 'custom-theme-load-path %s)
(with-temp-file %s
  (let ((print-length nil) (print-level nil) (print-quoted t))
    (dolist (file (directory-files %s nil "-theme\\.el\\'"))
      (let ((name (intern (substring file 0 (- (length file) 9)))))
        (condition-case err
            (progn
              (load-theme name t)
              (prin1 (list name
                           (get name 'theme-documentation)
                           (get name 'theme-properties)
                           (get name 'theme-settings))
                     (current-buffer))
              (terpri (current-buffer)))
          (error (message "skip %%s: %%s" name (error-message-string err))))))))
""" % (
        '"%s"' % emacs_themes if emacs_themes else "nil",
        '"%s"' % os.path.dirname(themes_dir),
        '"%s"' % themes_dir,
        '"%s"' % os.path.join(tempfile.gettempdir(), "omarchy-themes.dump"),
        '"%s"' % themes_dir,
    )
    path = os.path.join(tempfile.gettempdir(), "dump-omarchy.el")
    with open(path, "w") as port:
        port.write(script)
    out = os.path.join(tempfile.gettempdir(), "omarchy-themes.dump")
    if os.path.exists(out):
        os.unlink(out)
    r = subprocess.run([emacs, "-Q", "--batch", "-l", path],
                       capture_output=True, text=True, timeout=1200)
    sys.stderr.write(r.stderr[-2000:])
    with open(out, encoding="utf-8") as port:
        return port.read()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--emacs", default="emacs")
    ap.add_argument("--themes", default=os.path.expanduser(
        "~/GITE/omarchy.el/themes"))
    ap.add_argument("--out", default=os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        "schemacs", "external", "omarchy", "themes"))
    args = ap.parse_args()

    text = run_emacs(args.emacs, args.themes)
    reader = Reader(text)
    os.makedirs(args.out, exist_ok=True)
    count = 0
    while True:
        try:
            form = reader.read()
        except EOFError:
            break
        name, doc, props, settings = form
        header = (
            ";;; %s-theme.scm --- %s, derived from Modus\n"
            ";; Generated by tools/convert-omarchy-themes.py from\n"
            ";; omarchy.el's themes/%s-theme.el; do not edit by hand.\n"
            ";;\n"
            ";; The faces below are what `modus-themes-theme' expanded the\n"
            ";; palette to in GNU Emacs - the generator itself is not\n"
            ";; ported, only the `theme-settings' it produced."
            % (name, doc.split(",")[0] if doc else name, name))
        out = emit_theme(name, doc, props, settings, header)
        path = os.path.join(args.out, "%s-theme.scm" % name)
        with open(path, "w", encoding="utf-8") as port:
            port.write(out)
        count += 1
        print("wrote %s (%d faces)" % (path, len(out)))
    print("%d themes" % count)


if __name__ == "__main__":
    main()
