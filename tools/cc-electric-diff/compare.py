#!/usr/bin/env python3
"""Compare the two sides of the electric-command differential."""
import sys

def rows(path):
    out = {}
    order = []
    for line in open(path, encoding='utf-8'):
        line = line.rstrip('\n')
        if not line:
            continue
        name, text, point = line.split('\t')
        # Emacs's `ding` (blink-matching-open in batch) writes a BEL
        # before the scenario's output line.
        name = name.lstrip('\x07')
        out[name] = (text, point)
        order.append(name)
    return out, order

def decode(s):
    return (s.replace('\\\\', '\x00')
             .replace('\\n', '\n')
             .replace('\\t', '\t')
             .replace('\x00', '\\'))

def known(path='known.txt'):
    out = {}
    try:
        for line in open(path, encoding='utf-8'):
            line = line.rstrip('\n')
            if not line:
                continue
            name, reason = line.split('\t', 1)
            out[name] = reason
    except FileNotFoundError:
        pass
    return out

def main(emacs_path, ours_path):
    e, order = rows(emacs_path)
    o, _ = rows(ours_path)
    kn = known()
    bad = 0
    known_seen = 0
    for name in order:
        if name not in o:
            print(f'MISSING {name}')
            bad += 1
            continue
        if e[name] != o[name]:
            if name in kn:
                known_seen += 1
                print(f'KNOWN {name}: {kn[name]}')
                continue
            bad += 1
            et, ep = e[name]
            ot, op = o[name]
            print(f'DIFF {name}: point emacs={ep} ours={op}')
            if et != ot:
                print(f'  emacs: {decode(et)!r}')
                print(f'  ours : {decode(ot)!r}')
    print(f'{len(order)} scenarios, {bad} different'
          + (f', {known_seen} known' if known_seen else ''))
    return 1 if bad else 0

if __name__ == '__main__':
    sys.exit(main(sys.argv[1], sys.argv[2]))
