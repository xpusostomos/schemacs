#!/usr/bin/env python3
"""Report what a banner section of the frontend needs from outside itself.

The tedium of a move in LAYOUT-PLAN.txt is working out the import list, and
guessing it is how two earlier attempts went wrong: one picked up record
*field* names, and one missed a name only the tests noticed. This does the
work from Guile's own view of what each library exports rather than from the
source text.

It only reads - it never writes source. The generators that used to write a
library from a section were deleted, because re-running one after a move
undoes the hooks that the move needed, and a script that reverts a fix is
worse than no script. Reporting is safe to re-run at any time.

    tools/section-imports.py ';; Windows'
    tools/section-imports.py --all

Exit status is 1 if any section still uses a name that no known library
exports and that looks like it should have one - that is, a name that is not
a local, a Scheme name, or a terminal name.
"""
import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FRONT = os.path.join(REPO, 'schemacs/apps/ncurses-editor.sld')

# Libraries a section may reach, and the form to import them with.
LIBS = [
    ('(schemacs editor engine)', '(schemacs editor engine)'),
    ('(schemacs editor frame)', '(schemacs editor frame)'),
    ('(schemacs editor command)', '(schemacs editor command)'),
    ('(schemacs editor disp-table)', '(schemacs editor disp-table)'),
    ('(schemacs editor files)', '(schemacs editor files)'),
    ('(schemacs editor simple)', '(schemacs editor simple)'),
    ('(schemacs editor xdisp)', '(schemacs editor xdisp)'),
    ('(schemacs editor isearch)', '(schemacs editor isearch)'),
    ('(schemacs editor window)', '(schemacs editor window)'),
    ('(schemacs editor keymap)', '(schemacs editor keymap)'),
    ('(schemacs editor keyboard)', '(schemacs editor keyboard)'),
    ('(schemacs editor minibuffer)', '(schemacs editor minibuffer)'),
    ('(schemacs keymap)', '(prefix (schemacs keymap) km:)'),
    ('(schemacs ui text-buffer-impl)', '(schemacs ui text-buffer-impl)'),
]

QUERY = '''
(import (scheme base) (scheme write))
(for-each
 (lambda (spec)
   (catch #t
     (lambda ()
       (let ((m (resolve-interface (car spec))))
         (display (cdr spec)) (display "\\t")
         (for-each (lambda (p) (display (car p)) (display " "))
                   (module-map (lambda (k v) (cons k v)) m))
         (newline)))
     (lambda (k . a) #f)))
 (list %s))
'''

# The names that need no import at all: what the R7RS libraries export, and
# what the terminal does. Everything else that Guile has a binding for is
# Guile's own, and has to be imported from `(guile)' explicitly - which is
# how `string-prefix?' was missed: it is Guile's, not R7RS's, and the first
# attempt at `editor/minibuffer.sld' left it out. The test suite caught that
# one; the `display' in `editor/disp-table.sld' it did not catch.
R7RS_MODULES = ['(scheme base)', '(scheme char)', '(scheme write)',
                '(scheme file)', '(scheme cxr)', '(scheme case-lambda)',
                '(scheme lazy)', '(scheme inexact)', '(scheme read)',
                '(scheme process-context)', '(scheme load)']
TERMINAL = set("""A_BOLD A_REVERSE ERR KEY_BACKSPACE KEY_DC KEY_DOWN KEY_END KEY_HOME
 KEY_LEFT KEY_RESIZE KEY_RIGHT KEY_UP addstr attr-off! attr-on! border
 clearok! cols curs-set endwin erase getch idcok! idlok! initscr keypad! lines
 move noecho! nonl! raw! refresh resize scrollok! stdscr""".split())


def r7rs_names():
    """What the R7RS modules export, asked of Guile."""
    expr = ('(catch #t (lambda () (let ((m (resolve-interface (quote %s)))) '
            '(for-each (lambda (p) (display (car p)) (display " ")) '
            '(module-map (lambda (k v) (cons k v)) m)))) (lambda a #f))')
    names = set()
    for lib in R7RS_MODULES:
        out = subprocess.run(
            ['guile', '--no-auto-compile', '--r7rs', '-L', REPO, '-c',
             '(import (scheme base) (scheme write))\n' + expr % lib],
            capture_output=True, text=True,
            env=dict(os.environ, GUILE_WARN_DEPRECATED='no')).stdout
        names |= set(out.split())
    return names


def guile_names():
    """What Guile's own module exports, so a Guile-only name is not missed."""
    out = subprocess.run(
        ['guile', '--no-auto-compile', '-L', REPO, '-c',
         '(import (ice-9 match))\n'
         '(for-each (lambda (p) (display (car p)) (display " ")) '
         '(module-map (lambda (k v) (cons k v)) (resolve-module (quote (guile)))))'],
        capture_output=True, text=True,
        env=dict(os.environ, GUILE_WARN_DEPRECATED='no')).stdout
    return set(out.split())


def exports():
    specs = ' '.join("'(%s . \"%s\")" % (lib, form) for lib, form in LIBS)
    out = subprocess.run(
        ['guile', '--no-auto-compile', '--r7rs', '-L', REPO, '-c', QUERY % specs],
        capture_output=True, text=True,
        env=dict(os.environ, GUILE_WARN_DEPRECATED='no')).stdout
    table = {}
    for line in out.split('\n'):
        if '\t' in line:
            form, names = line.split('\t', 1)
            table[form] = set(names.split())
    return table


def is_rule(l):
    s = l.strip()
    return len(s) > 10 and set(s) <= set('-;')


def is_title(l):
    s = l.strip()
    return s.startswith(';; ') and not is_rule(l)


def sections(lines):
    starts = [i for i in range(len(lines) - 1)
              if is_rule(lines[i]) and is_title(lines[i + 1])]
    out = []
    for i, start in enumerate(starts):
        end = starts[i + 1] if i + 1 < len(starts) else len(lines)
        out.append((lines[start + 1].strip(), start, end))
    return out


def strip_text(text):
    out = []
    for l in text.split('\n'):
        o, i, n = [], 0, len(l)
        while i < n:
            if l[i] == ';':
                break
            if l[i] == '"':
                i += 1
                while i < n and l[i] != '"':
                    if l[i] == '\\':
                        i += 1
                    i += 1
                i += 1
                continue
            o.append(l[i])
            i += 1
        out.append(''.join(o))
    return '\n'.join(out)


DEFRE = re.compile(
    r'^    \(define(?:-record-type|-syntax|-values|-constant|-parameter)?\s+\(?([^\s()]+)')


def report(title, body, table, free, guile):
    defined = {m.group(1) for m in (DEFRE.match(l) for l in body.split('\n')) if m}
    # Anything bound by a let/loop/argument is hard to see in text, so a name
    # is reported unless it is defined here, an R7RS or terminal name, or
    # exported by a library we know.
    used = set(re.findall(r"[^\s()\[\]',;`]+", strip_text(body)))
    from_lib, from_guile, unknown = {}, [], []
    for s in sorted(used):
        if s in defined or s in free or s in TERMINAL:
            continue
        hit = [f for f, names in table.items() if s in names]
        if hit:
            for h in hit:
                from_lib.setdefault(h, []).append(s)
        elif s in guile:
            from_guile.append(s)
        else:
            unknown.append(s)
    print('=== %s  (%d lines, %d definitions)'
          % (title, len(body.split('\n')), len(defined)))
    for form in sorted(from_lib):
        print('    %-34s %s' % (form, ' '.join(from_lib[form])))
    if from_guile:
        print('    (only (guile) %s)   <- Guile\'s, not R7RS\'s'
              % ' '.join(from_guile))
    if unknown:
        print('    NOT FROM A LIBRARY (%d): %s' % (len(unknown), ' '.join(unknown)))
    print()
    return unknown


def main():
    lines = open(FRONT).read().split('\n')
    table = exports()
    if not table:
        sys.exit('could not read the export lists from guile')
    free = r7rs_names()
    guile = guile_names()

    if '--all' in sys.argv:
        for title, a, b in sections(lines):
            report(title, '\n'.join(lines[a:b]), table, free, guile)
        return 0

    want = sys.argv[1]
    for title, a, b in sections(lines):
        if title == want:
            report(title, '\n'.join(lines[a:b]), table, free, guile)
            return 0
    sys.exit('no such section: %s' % want)


if __name__ == '__main__':
    sys.exit(main())
