#!/usr/bin/env python3
"""Audit: for functions present in BOTH Emacs and schemacs, compare the
number of `save-excursion' calls (see plans/SAVE-EXCURSION.md).

Both sides are parsed by their own reader - Emacs reads the .el with
`read', Guile reads the .scm with `read' - so neither direction depends on
a hand-rolled paren matcher."""
import os, subprocess, sys, glob, tempfile

# The two helpers are each language's own reader: Emacs `read`s the .el,
# Guile `read`s the .scm, so neither side depends on a hand-rolled paren
# matcher. (One was tried: it reported 31 save-excursions in
# `query-replace-descr', which has none.)
_EL = r"""(defun count-se (tree)
  (cond ((eq tree 'save-excursion) 1)
        ((consp tree) (+ (count-se (car tree)) (count-se (cdr tree))))
        ((vectorp tree) (let ((n 0)) (dotimes (i (length tree)) (setq n (+ n (count-se (aref tree i))))) n))
        (t 0)))
(defun walk (tree file)
  (when (consp tree)
    (when (memq (car tree) '(defun defsubst defmacro cl-defun define-inline))
      (let ((name (cadr tree)))
        (when (symbolp name)
          (condition-case nil
              (princ (format "%s\t%s\t%d\n" file name (count-se (cddr tree))))
            (error nil)))))
    (dolist (x tree) (condition-case nil (walk x file) (error nil)))))
(with-temp-buffer
  (insert-file-contents se-file)
  (goto-char (point-min))
  (let (form (go t))
    (while go
      (condition-case nil (setq form (read (current-buffer)))
        (error (setq go nil) (setq form nil)))
      (when (and go form) (condition-case nil (walk form (file-name-base se-file)) (error nil))))))
"""

_SCM = r"""(use-modules (ice-9 format))
(define (count-se t)
  (cond ((eq? t 'save-excursion) 1)
        ((pair? t) (+ (count-se (car t)) (count-se (cdr t))))
        ((vector? t) (let loop ((i 0) (n 0))
                       (if (= i (vector-length t)) n
                           (loop (+ i 1) (+ n (count-se (vector-ref t i)))))))
        (else 0)))
(define (name-of form)
  (let ((target (and (pair? (cdr form)) (cadr form))))
    (cond ((pair? target) (car target))
          ((symbol? target) target)
          (else #f))))
(define (walk t base)
  (when (pair? t)
    (when (and (memq (car t) '(define define-command)) (pair? (cdr t)))
      (let ((n (name-of t)))
        (when (symbol? n)
          (catch #t (lambda () (format #t "~a\t~a\t~d~%" base n (count-se (cddr t))))
                 (lambda _ #t)))))
    (for-each (lambda (x) (catch #t (lambda () (walk x base)) (lambda _ #t))) t)))
(let* ((f (cadr (command-line)))
       (base (basename f ".scm")))
  (catch #t
    (lambda ()
      (call-with-input-file f
        (lambda (p)
          (let loop ()
            (let ((d (read p)))
              (unless (eof-object? d) (walk d base) (loop)))))))
    (lambda _ #t)))
"""

_HELP = tempfile.mkdtemp(prefix='se-audit-')
open(os.path.join(_HELP, 'se-emacs.el'), 'w').write(_EL)
open(os.path.join(_HELP, 'se-scm.scm'), 'w').write(_SCM)

EMACS = os.path.expanduser('~/GITE/emacs')
REPO = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else '.')
# Libraries whose Emacs side is a .c file: the specpdl idiom there
# (`record_unwind_current_buffer"/`unbind_to') is not `save-excursion'.
SKIP = {'arrays', 'buffer-text', 'character', 'charset', 'cmds', 'coding',
        'data', 'dispnew', 'editfns', 'env', 'fileio', 'frame',
        'indentc', 'insdel', 'keyboard', 'keymap', 'marker', 'minibuf',
        'region-cache', 'search', 'syntax', 'textprop', 'timefns', 'undo',
        'test-display', 'casefiddle', 'diredc', 'xdisp', 'process',
        'character', 'blink-cursor'}


def emacs_counts(el):
    r = subprocess.run(['emacs', '-Q', '--batch',
                        '--eval', f'(setq se-file "{el}")',
                        '-l', os.path.join(_HELP, 'se-emacs.el')],
                       capture_output=True, text=True)
    out = {}
    for line in r.stdout.splitlines():
        parts = line.split('\t')
        if len(parts) == 3 and parts[2].isdigit():
            out[parts[1]] = int(parts[2])
    return out


def scm_counts(scm):
    r = subprocess.run(['guile', '--no-auto-compile', '-s', os.path.join(_HELP, 'se-scm.scm'), scm],
                       capture_output=True, text=True)
    out = {}
    for line in r.stdout.splitlines():
        parts = line.split('\t')
        if len(parts) == 3 and parts[2].isdigit():
            out[parts[1]] = int(parts[2])
    return out


missing, differ, not_ported = [], [], 0
for scm in sorted(glob.glob(f'{REPO}/schemacs/editor/*.scm')):
    lib = os.path.basename(scm)[:-4]
    if lib.endswith('-tests') or lib in SKIP:
        continue
    hits = (glob.glob(f'{EMACS}/lisp/**/{lib}.el', recursive=True)
            + glob.glob(f'{EMACS}/lisp/{lib}.el'))
    if not hits:
        print(f'# no .el for {lib}', file=sys.stderr)
        continue
    theirs = emacs_counts(hits[0])
    ours = scm_counts(scm)
    for name, ecnt in sorted(theirs.items()):
        if name not in ours:
            if ecnt:
                not_ported += 1
            continue
        scnt = ours[name]
        if ecnt != scnt:
            differ.append((lib, name, ecnt, scnt))
            if ecnt > 0 and scnt == 0:
                missing.append((lib, name, ecnt))

print(f'## Emacs guards with save-excursion; we have the function and do not ({len(missing)})\n')
for lib, name, ecnt in missing:
    print(f'  {lib:14s} {name:40s} emacs {ecnt}   ours 0')
print(f'\n## Other differences ({len(differ) - len(missing)})\n')
for lib, name, ecnt, scnt in differ:
    if ecnt > 0 and scnt == 0:
        continue
    print(f'  {lib:14s} {name:40s} emacs {ecnt}   ours {scnt}')
print(f'\n## Emacs functions with save-excursion that are not ported at all: {not_ported}')
