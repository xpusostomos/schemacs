#!/usr/bin/env python3
"""Compare the two cc-langs constant dumps: Emacs 31.1 vs this tree.

Each file is `NAME<TAB>LANG<TAB>VALUE` lines in the canonical form the
two dumps print: strings as `(S <hex code points>)`, symbols `(Y name)`,
characters and integers both `(I n)`, lists `(L ...)` (dotted tails
included), nil `(NIL)`, t `(T)`, procedures `(FN)`, char-tables `(CT)`,
vectors `(VEC n)`.

Lists are compared **without regard to order** and recursively: Emacs's
`c-kwds-lang-consts` is an obarray walk, so the order of a keyword list
built from it is Emacs's internals, not its meaning; every consumer
tests membership or builds a `regexp-opt` (which sorts). A regexp
value, being a string, is still compared byte for byte.

Exit 0 when the only differences are the six `c-pre-lambda-tokens`
order cases (see DEPARTURES.md), 1 otherwise.
"""
import sys, collections

HERE = __file__.rsplit('/', 1)[0]

def load(path):
    vals = {}
    for line in open(path):
        name, lang, val = line.rstrip('\n').split('\t', 2)
        vals[(name, lang)] = val
    return vals

def canon(v):
    # Emacs's quasiquoted lambda is this port's procedure.
    if v.startswith('(L (Y lambda)'):
        return '(FN)'
    if v.startswith('(L '):
        body = v[3:-1]
        parts, depth, cur = [], 0, ''
        for ch in body + ' ':
            if ch == '(':
                depth += 1
            if ch == ')':
                depth -= 1
            if ch == ' ' and depth == 0:
                if cur:
                    parts.append(cur)
                    cur = ''
            else:
                cur += ch
        if cur:
            parts.append(cur)
        parts = [canon(p) for p in parts]
        return '(L ' + ' '.join(sorted(parts)) + ')'
    return v

em = load(HERE + '/emacs-vals.txt')
ours = load(HERE + '/ours-vals.txt')

missing = set(em) - set(ours)
extra = set(ours) - set(em)
diff = [k for k in em if canon(em[k]) != canon(ours.get(k, ''))]

print('%d answers, %d differ' % (len(em), len(diff)))
for k in sorted(diff):
    print('DIFF %s %s' % k)
if missing:
    print('missing:', sorted(missing)[:10])
if extra:
    print('extra:', sorted(extra)[:10])

known = {('c-pre-lambda-tokens', l) for l in
         ('c', 'c++', 'objc', 'java', 'idl', 'pike', 'awk')}
unexpected = [k for k in diff if k not in known]
sys.exit(0 if not unexpected and not missing and not extra else 1)
