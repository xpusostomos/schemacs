#!/usr/bin/env python3
"""Report GNU Emacs `defcustom`s that this tree defines without `define-custom`.

A user option is a variable a user is meant to set.  GNU Emacs marks one
with `defcustom' (or, for a C `DEFVAR', with an entry in `cus-start.el' -
that half of the audit is in DEPARTURES.md's 2026-10-14 section and is not
repeated here).  This tree's spelling of `defcustom' is `define-custom',
which makes the variable a parameter with its documentation, type and
group recorded.

A variable that is defined some other way - `(define *foo* (make-parameter
...))`, a plain `(define foo ...)`, or a buffer-local accessor pair whose
default is hard-coded - is therefore a user option that has not been
declared as one: `custom-variable-p' is false, `describe-variable' does
not know it and the Customize UI cannot list it.

Usage:

    python3 tools/defcustom-audit.py [EMACS-LISP-DIR]

EMACS-LISP-DIR defaults to $GITE/emacs/lisp, then to the sibling checkout
`../../GITE/emacs/lisp`; it must contain the Emacs Lisp sources.  Exit 0
when every Emacs defcustom this tree defines is a `define-custom`, 1 when
some are not (they are printed), 2 on a usage error.

The scan strips strings and comments on both sides before matching, so a
`(defcustom ...)` quoted in a docstring or a comment does not count.
"""

import os
import re
import sys

TREE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def sanitize(src, elisp=False):
    """Blank out strings and comments, keeping every index (and newline).

    Indices are preserved so a caller can compute a line number from the
    sanitized text and report it against the original.
    """
    out = []
    i = 0
    n = len(src)
    in_str = False
    in_comment = False
    while i < n:
        c = src[i]
        if in_comment:
            if c == '\n':
                in_comment = False
                out.append('\n')
            else:
                out.append(' ')
            i += 1
            continue
        if in_str:
            if c == '\\':
                out.append('  ')
                i += 2
                continue
            if c == '"':
                in_str = False
                out.append('"')
                i += 1
                continue
            out.append('\n' if c == '\n' else ' ')
            i += 1
            continue
        if c == ';':
            in_comment = True
            out.append(' ')
            i += 1
            continue
        if elisp and c == '?':
            # `?X' / `?\(' is a character literal in Elisp; blank it so a
            # paren in one is not mistaken for code.
            out.append('?')
            i += 1
            if i < n:
                if src[i] == '\\' and i + 1 < n:
                    out.append(' ')
                    i += 1
                out.append(' ')
                i += 1
            continue
        if not elisp and c == '#':
            # Guile: `#\X' character literals and `#{...}#' symbols.
            if src.startswith('#\\', i):
                out.append('  ')
                i += 2
                if i < n:
                    out.append(' ')
                    i += 1
                    if src[i - 1].isalnum():
                        while i < n and (src[i].isalnum() or src[i] in '-_'):
                            out.append(' ')
                            i += 1
                continue
            if src.startswith('#{', i):
                j = src.find('}#', i + 2)
                if j < 0:
                    out.append('#')
                    i += 1
                    continue
                out.append(' ' * (j + 2 - i))
                i = j + 2
                continue
        if c == '"':
            in_str = True
            out.append('"')
            i += 1
            continue
        out.append(c)
        i += 1
    return ''.join(out)


def emacs_defcustoms(lisp_dir):
    """Map each defcustom name to the file that first defines it."""
    names = {}
    pattern = re.compile(r'\(defcustom\s+([^\s()\'";]+)')
    for root, _dirs, files in os.walk(lisp_dir):
        for fn in files:
            if not fn.endswith('.el'):
                continue
            path = os.path.join(root, fn)
            try:
                raw = open(path, encoding='utf-8', errors='replace').read()
            except OSError:
                continue
            for m in pattern.finditer(sanitize(raw, elisp=True)):
                names.setdefault(m.group(1), path)
    return names


def our_definitions(tree_dir):
    """Yield (file, line, name, kind) for each top-level variable definition.

    Kinds are `param' (a `(make-parameter ...)' binding), `define-custom',
    `accessor' (a zero-argument reader with a `set!NAME' writer, this
    tree's buffer-local pair) and `plain' (any other variable `define').
    """
    rows = []
    for root, _dirs, files in os.walk(tree_dir):
        # Skip the test suites and tooling when the whole repo is walked.
        rel = os.path.relpath(root, tree_dir)
        if rel != '.' and rel.split(os.sep)[0] in ('.git', 'test', 'tools'):
            continue
        for fn in files:
            if not fn.endswith('.scm'):
                continue
            path = os.path.join(root, fn)
            try:
                raw = open(path, encoding='utf-8', errors='replace').read()
            except OSError:
                continue
            text = sanitize(raw)
            def line_of(pos):
                return text.count('\n', 0, pos) + 1
            setters = set(re.findall(r'\(define\s+\(set!([^\s()]+)\s', text))
            for m in re.finditer(r'\(define\s+\(([^\s()]+)\)\s', text):
                if m.group(1) in setters:
                    rows.append((path, line_of(m.start()), m.group(1),
                                 'accessor'))
            for m in re.finditer(r'\(define-custom\s+([^\s()]+)', text):
                rows.append((path, line_of(m.start()), m.group(1),
                             'define-custom'))
            for m in re.finditer(r'\(define\s+([^\s()]+)\s+(\S)', text):
                name = m.group(1)
                if name.startswith('('):
                    continue
                head = ''
                if m.group(2) == '(':
                    hm = re.match(r'\(([^\s()]+)', text[m.start(2):])
                    head = hm.group(1) if hm else ''
                if head == 'lambda':
                    continue
                kind = 'param' if head == 'make-parameter' else 'plain'
                rows.append((path, line_of(m.start()), name, kind))
    return rows


def main(argv):
    if len(argv) > 2:
        sys.stderr.write('usage: defcustom-audit.py [EMACS-LISP-DIR]\n')
        return 2
    if len(argv) == 2:
        lisp_dir = argv[1]
    else:
        lisp_dir = os.environ.get('EMACS_LISP')
        if not lisp_dir:
            lisp_dir = os.path.join(TREE, '..', '..', 'GITE', 'emacs', 'lisp')
    if not os.path.isdir(lisp_dir):
        sys.stderr.write('defcustom-audit: no Emacs Lisp sources at %s\n'
                         % os.path.abspath(lisp_dir))
        return 2

    defcustoms = emacs_defcustoms(lisp_dir)
    rows = our_definitions(os.path.join(TREE, 'schemacs'))
    declared = set(row[2] for row in rows if row[3] == 'define-custom')

    def base_name(name):
        if name.startswith('*') and name.endswith('*') and len(name) > 2:
            return name[1:-1]
        return name

    def declared_somewhere(name):
        candidates = (name, base_name(name), '*' + base_name(name) + '*')
        return any(c in declared for c in candidates)

    todo = []
    for path, line, name, kind in rows:
        if kind == 'define-custom':
            continue
        if base_name(name) not in defcustoms:
            continue
        todo.append((path, line, name, kind, defcustoms[base_name(name)]))

    # An accessor pair *backed by* a define-custom is this tree's shape for
    # a buffer-local defcustom (the parameter is the default, the slot is
    # the buffer's value) - that is done, not a duplicate.  A plain or
    # parameter definition beside a define-custom is a real duplicate: the
    # second binding shadows the first.
    real = []
    duplicates = []
    for row in todo:
        if declared_somewhere(row[2]):
            if row[3] == 'accessor':
                continue
            duplicates.append(row)
        else:
            real.append(row)

    for path, line, name, kind, el in sorted(real):
        print('%s:%d: %s is a defcustom in %s but is defined as %s here'
              % (os.path.relpath(path, TREE), line, name,
                 os.path.relpath(el, lisp_dir), kind))
    for path, line, name, kind, el in sorted(duplicates):
        print('%s:%d: %s has a define-custom and a %s definition'
              % (os.path.relpath(path, TREE), line, name, kind))
    if real or duplicates:
        print('%d Emacs defcustom(s) not declared with define-custom'
              % (len(real) + len(duplicates)))
        return 1
    print('every Emacs defcustom this tree defines is a define-custom')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
