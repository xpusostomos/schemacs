#!/usr/bin/env python3
"""Rewrite `make-parameter` variables into ordinary variables + `fluid-let`.

Chris, 2026-10-14: *"having custom variables as parameters is a worse
departure than the supposed thing it tries to fix"*, then *"ok start work"*.

What changes, per file:

    (define *x* (make-parameter v))   ->  (define *x* v)
    (*x*)                             ->  *x*
    (*x* v)                           ->  (set! *x* v)
    (parameterize ((*x* v) ...) ...)  ->  (fluid-let ((*x* v) ...) ...)

and `(only (schemacs fluid) fluid-let)` goes into the file's imports,
because `parameterize` is core syntax and `fluid-let` is ours.

**Why a textual rewrite and not a read-and-reprint.** The comments in this
tree are its documentation and Guile's printer would discard them along
with the hand-made layout. So edits are made in place and the only parsing
is the paren matching needed to find where a form ends.

**Three things it has to know**, each found by reading its own report:

  * Parameters are not all starred. `(define current-display
    (make-parameter #f))` is one too, so the tool first collects the
    *names* from every definition site in the tree and works from that set
    rather than from a pattern for asterisks.
  * Names travel with prefixes - `(prefix (schemacs editor dispnew) dn:)`
    makes `current-display` callable as `dn:current-display` - so a call is
    matched on the name after any `prefix:` part.
  * **Not every `parameterize` is ours.** `coop-server.scm` rebinds Guile's
    own `current-input-port`/`current-output-port`/`current-warning-port`,
    which are real parameter objects and stay `parameterize`. A form is
    renamed only when every one of its targets is a variable this tool is
    converting.

    tools/fluidize.py            # report only
    tools/fluidize.py --apply    # do it
"""

import glob
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# `*` is in the class because most of this tree's variables are spelled
# `*name*`; a plain `*` also matches, which is Guile's multiplication, but
# only names found at a definition site are ever rewritten.
IDENT = r'[A-Za-z0-9!?<>=+/_.*-]+'
PREFIXED = r'(?:[A-Za-z0-9_-]+:)*(' + IDENT + r')'


def code_mask(text):
    """Same length as TEXT: code characters as they are, everything else
    (`;` comments, strings, character literals) as `#`.

    `#` is neither whitespace nor a paren, so a string containing a space
    is not mistaken for an argument boundary and a `(*x*)` in a comment is
    never touched. Both of those were bugs in the first version.
    """
    out = list(text)
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == ';':
            while i < n and text[i] != '\n':
                out[i] = '#'
                i += 1
        elif c == '"':
            out[i] = 'S'
            i += 1
            while i < n:
                if text[i] == '\\':
                    out[i] = 'S'
                    i += 1
                    if i < n:
                        out[i] = 'S'
                        i += 1
                    continue
                out[i] = 'S'
                if text[i] == '"':
                    i += 1
                    break
                i += 1
        elif c == '#' and i + 1 < n and text[i + 1] == '\\':
            out[i] = 'S'
            i += 1
            out[i] = 'S'
            i += 1
            while i < n and (text[i].isalnum() or text[i] in '+-'):
                out[i] = 'S'
                i += 1
        else:
            i += 1
    return ''.join(out)


def matching_paren(mask, i):
    depth = 0
    while i < len(mask):
        if mask[i] == '(':
            depth += 1
        elif mask[i] == ')':
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1


def has_code(mask, a, b):
    """Whether MASK[A:B] is an argument at all: a comment is not one, a
    string is. A definition's value is very often preceded by its doc
    comment, which must not be counted."""
    return any(mask[i] not in '# \t\n\r' for i in range(a, b))


def split_args(mask, open_index, close_index):
    """The argument spans of the form whose parens are at OPEN_INDEX and
    CLOSE_INDEX - the head of the form is dropped."""
    spans, depth, start = [], 1, open_index + 1
    i = open_index + 1
    while i < close_index:
        c = mask[i]
        if c == '(':
            depth += 1
        elif c == ')':
            depth -= 1
        elif depth == 1 and c.isspace():
            if has_code(mask, start, i):
                spans.append((start, i))
            start = i + 1
            while start < close_index and mask[start].isspace():
                start += 1
            i = start
            continue
        i += 1
    if has_code(mask, start, close_index):
        spans.append((start, close_index))
    return spans[1:]


def parameter_names(paths):
    """Every name defined with `make-parameter`, from the whole tree.

    The *base* name is what is recorded: a file that imports it with a
    prefix writes `dn:current-display`, and that is the same parameter.
    """
    names = {}
    for path in paths:
        text = open(path, encoding='utf-8').read()
        if 'make-parameter' not in text:
            continue
        mask = code_mask(text)
        for m in re.finditer(r'\(define\s+' + PREFIXED + r'[\s#]+\(make-parameter\b',
                             mask):
            names[m.group(1)] = path
    return names


def rewrite(path, text, params, problems):
    mask = code_mask(text)
    edits = []

    def note(what, index):
        problems.append((what, '%s:%d' % (os.path.relpath(path, REPO),
                                          text.count('\n', 0, index) + 1)))

    # 1. definitions: (define *x* (make-parameter v)) -> (define *x* v)
    for m in re.finditer(r'\(define\s+' + PREFIXED + r'[\s#]+\(make-parameter\b', mask):
        open_i = text.index('(make-parameter', m.start())
        close_i = matching_paren(mask, open_i)
        if close_i < 0:
            note('unbalanced make-parameter', m.start())
            continue
        args = split_args(mask, open_i, close_i)
        if len(args) != 1:
            note('make-parameter with %d arguments' % len(args), m.start())
            continue
        a, b = args[0]
        edits.append((open_i, close_i + 1, text[a:b].strip()))

    # 2. call sites of a known parameter: (*x*), (*x* v), (dn:current-display)
    for m in re.finditer(r'\(\s*' + PREFIXED, mask):
        if m.group(1) not in params:
            continue
        open_i = m.start()
        spelling = text[m.start() + 1:m.end()]
        after = m.end()
        # whitespace *or* non-code: a read is sometimes written
        # `(*x* ; why\n )', with the comment before the paren
        while after < len(mask) and (mask[after].isspace() or mask[after] == '#'):
            after += 1
        if after < len(mask) and mask[after] == ')':
            edits.append((open_i, after + 1, spelling))
            continue
        close_i = matching_paren(mask, open_i)
        if close_i < 0:
            note('unbalanced call of %s' % m.group(1), open_i)
            continue
        args = split_args(mask, open_i, close_i)
        if len(args) == 0:
            # nothing but comments in there: it is a read
            edits.append((open_i, close_i + 1, spelling))
            continue
        if len(args) != 1:
            note('%s called with %d arguments' % (m.group(1), len(args)), open_i)
            continue
        a, b = args[0]
        edits.append((open_i, close_i + 1,
                      '(set! %s %s)' % (spelling, text[a:b].strip())))

    # 3. parameterize -> fluid-let, but only when every target is ours
    for m in re.finditer(r'\(\s*parameterize(?=[\s)])', mask):
        open_i = m.start()
        close_i = matching_paren(mask, open_i)
        if close_i < 0:
            continue
        args = split_args(mask, open_i, close_i)
        targets, foreign = [], False
        if args:
            bs, be = args[0]
            if mask[bs] == '(':
                for a, b in split_args(mask, bs, matching_paren(mask, bs)):
                    while a < b and mask[a].isspace():
                        a += 1
                    head = re.match(r'\(\s*' + PREFIXED, mask[a:b])
                    if not head:
                        continue
                    targets.append(head.group(1))
                    if head.group(1) not in params:
                        foreign = True
        if foreign:
            note('parameterize left alone (not our parameters): %s'
                 % ', '.join(targets), open_i)
        else:
            edits.append((open_i, m.end(), '(fluid-let'))

    # 4. a `make-parameter` that is not a definition's: a macro template,
    #    or something to read
    for m in re.finditer(r'\(make-parameter\b', mask):
        if any(s <= m.start() < e for s, e, _ in edits):
            continue
        note('a make-parameter outside a definition', m.start())

    for start, end, replacement in sorted(edits, key=lambda e: -e[0]):
        text = text[:start] + replacement + text[end:]
    return text, edits


def add_import(text):
    """Put `(only (schemacs fluid) fluid-let)` in the file's import form."""
    if 'schemacs fluid' in text:
        return text
    m = re.search(r'^\s*\(import\s*$', text, re.M)
    if not m:
        return text
    return text[:m.end()] + '\n (only (schemacs fluid) fluid-let)' + text[m.end():]


def is_read(text, start, replacement):
    """An edit that turned a call into a bare name is a read."""
    return text[start] == '(' and not replacement.startswith('(')


def main():
    apply = '--apply' in sys.argv
    paths = sorted(glob.glob(os.path.join(REPO, 'schemacs/**/*.scm'),
                             recursive=True))
    params = parameter_names(paths)
    print('%d parameters defined in the tree' % len(params))
    problems, touched = [], []
    n_calls = n_pars = 0
    for path in paths:
        text = open(path, encoding='utf-8').read()
        if 'make-parameter' not in text and 'parameterize' not in text:
            continue
        new, edits = rewrite(path, text, params, problems)
        calls = sum(1 for s, e, r in edits if r.startswith('(set!')
                    or is_read(text, s, r))
        pars = sum(1 for s, e, r in edits if r == '(fluid-let')
        n_calls += calls
        n_pars += pars
        if pars:
            new = add_import(new)
        if calls or pars:
            touched.append((path, calls, pars))
        if apply and new != text:
            open(path, 'w', encoding='utf-8').write(new)
    print('%d files change; %d call sites; %d parameterize -> fluid-let'
          % (len(touched), n_calls, n_pars))
    print('%d problems to read by hand' % len(problems))
    for what, where in problems:
        print('   %-64s %s' % (what, where))
    if not apply:
        print('(report only; pass --apply to change anything)')


if __name__ == '__main__':
    main()
