#!/usr/bin/env python3
"""Report definitions that a library cannot export, because the name is imported.

GNU Guile resolves a `(define X ...)' in a library body whose name X is also
exported by one of that library's own imports by keeping the *import*: the
definition is silently lost.  R7RS agrees that defining over an imported
binding is an error, so this is a real constraint and not a Guile quirk to
work around - it just has no diagnostic here, and neither the test suites nor
`tools/syntax-check.scm' can see it.

We hit it with `newline'.  Every one of our editor libraries imports
`(scheme base)', and Guile's `(scheme base)' exports `newline' (R7RS-small
says it should not, but Guile's does), so `(define newline ...)' in
`schemacs/editor/simple.sld' was dropped and the keymap ended up bound to
Scheme's output procedure instead of the editing command.  The suites stayed
green; the editor inserted nothing when RET was pressed.

The fix is R7RS's: export the name by `rename' from a differently-spelled
definition, which is what `newline-command' does.

This script checks every `.sld' in the tree against the union of the R7RS
module export lists, which is what any library importing `(scheme base)'
gets.  Exit status is 1 if anything is reported.
"""
import glob
import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

MODULES = ['(scheme base)', '(scheme char)', '(scheme write)', '(scheme file)',
           '(scheme cxr)', '(scheme case-lambda)', '(scheme lazy)',
           '(scheme inexact)', '(scheme read)', '(scheme process-context)',
           '(scheme load)']

DUMP = '''
(import (scheme base) (scheme write))
(for-each
 (lambda (m)
   (catch #t
     (lambda ()
       (let ((i (resolve-interface m)))
         (display m) (display "\\t")
         (for-each (lambda (p) (display (car p)) (display " "))
                   (module-map (lambda (k v) (cons k v)) i))
         (newline)))
     (lambda (k . a) #f)))
 (list %s))
''' % ' '.join("'%s" % m for m in MODULES)

DEFRE = re.compile(
    r'^    \(define(?:-record-type|-syntax|-values|-constant|-parameter)?\s+\(?([^\s()]+)')


def r7rs_exports():
    out = subprocess.run(
        ['guile', '--no-auto-compile', '--r7rs', '-L', REPO, '-c', DUMP],
        capture_output=True, text=True,
        env=dict(os.environ, GUILE_WARN_DEPRECATED='no')).stdout
    names = set()
    for line in out.split('\n'):
        if '\t' not in line:
            continue
        names |= set(line.split('\t', 1)[1].split())
    if not names:
        sys.exit('could not read the R7RS export lists from guile')
    return names


def main():
    r7rs = r7rs_exports()
    reported = 0
    for path in sorted(glob.glob(os.path.join(REPO, 'schemacs/**/*.sld'),
                                 recursive=True)):
        src = open(path).read()
        start = src.find('\n  (begin')
        if start < 0:
            continue
        body = src[start:]
        for line in body.split('\n'):
            m = DEFRE.match(line)
            if m and m.group(1) in r7rs:
                print('%s: defines `%s\', which (scheme base) also exports - '
                      'the definition will be lost' % (
                          os.path.relpath(path, REPO), m.group(1)))
                reported += 1
    if reported:
        print()
        print('Export such a name by rename from a differently-spelled '
              'definition; see newline-command in schemacs/editor/simple.sld')
        return 1
    print('ok: no definition shadows an imported name (%d checked)'
          % len(glob.glob(os.path.join(REPO, 'schemacs/**/*.sld'),
                          recursive=True)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
