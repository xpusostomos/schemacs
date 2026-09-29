#!/usr/bin/env python3
"""Report which names each banner section of a library uses but does not define.

Crude but useful: strips comments/strings, finds top-level `(define ...)`
forms inside the file's `(begin ...)`, attributes each to the nearest
preceding banner comment, then for each section lists the symbols it
mentions that are defined by some *other* section (or nowhere).
"""
import re, sys, collections

path = sys.argv[1]
src = open(path).read()
lines = src.split('\n')

# Strip block comments (#| |#), line comments (;), and strings.
def strip(text):
    out = []
    i = 0
    n = len(text)
    depth = 0
    while i < n:
        c = text[i]
        if depth == 0 and c == ';':
            while i < n and text[i] != '\n':
                i += 1
            continue
        if text.startswith('#|', i):
            depth += 1; i += 2; continue
        if text.startswith('|#', i) and depth:
            depth -= 1; i += 2; continue
        if depth == 0 and c == '"':
            i += 1
            while i < n:
                if text[i] == '\\': i += 2; continue
                if text[i] == '"': i += 1; break
                i += 1
            continue
        if depth == 0 and c == '#' and i + 1 < n and text[i+1] == '\\':
            i += 3 if text.startswith('#\\', i) and i+2 < n and re.match(r'[a-zA-Z0-9]', text[i+2]) else 3
            continue
        if depth == 0 and text.startswith('#(', i):
            i += 2; continue
        if depth: i += 1; continue
        if c == '\n':
            out.append('\n'); i += 1; continue
        if c == ';':
            while i < n and text[i] != '\n': i += 1
            continue
        out.append(c); i += 1
    return ''.join(out)

clean = strip(src)
# Map cleaned offsets back to line numbers is hard; instead do a
# per-line strip which is good enough (no multi-line strings here).
def strip_line(l):
    out = []
    i = 0
    n = len(l)
    while i < n:
        if l[i] == ';':
            break
        if l[i] == '"':
            i += 1
            while i < n and l[i] != '"':
                if l[i] == '\\': i += 1
                i += 1
            i += 1
            continue
        out.append(l[i]); i += 1
    return ''.join(out)

banners = []   # (line_index, title)
for idx, l in enumerate(lines):
    m = re.match(r'\s*;;\s+([A-Z][^;]*?)\s*$', l)
    if m and '----' not in l:
        # a banner is a line of dashes followed by a title line
        if idx > 0 and set(lines[idx-1].strip()) <= set('-;') and len(lines[idx-1].strip()) > 10:
            banners.append((idx, m.group(1)))

def section_of(lineno):
    cur = '(header)'
    for (i, t) in banners:
        if i <= lineno:
            cur = t
    return cur

# Names defined outside (begin ...) -- the import/export region.
head = '\n'.join(lines[:289])
def names_in(text):
    return set(re.findall(r"[^\s()\[\]'\",;`]+", text))

imported = names_in('\n'.join(
    strip_line(l) for l in lines[17:123]))

# Top-level defines inside (begin ...): a line matching ^    (define
defs = collections.defaultdict(list)   # name -> [lineno]
defre = re.compile(r'^    \(define(?:-record-type|-syntax|-values|-values\*|-constant|-parameter)?\s+\(?([^\s()]+)')
for idx, l in enumerate(lines[289:], start=290):
    m = defre.match(l)
    if m:
        defs[m.group(1).strip()].append(idx)

# Symbols used per section (only lines in the body).
use = collections.defaultdict(set)
for idx, l in enumerate(lines[289:], start=290):
    sec = section_of(idx)
    for s in names_in(strip_line(l)):
        use[sec].add(s)

defined = set(defs.keys())
sections = [t for (i, t) in banners]
print("sections:", sections)
print()
for sec in sections:
    # names defined by other sections
    foreign = {}
    for s in sorted(use[sec]):
        if s in defined and section_of(defs[s][0]) != sec:
            foreign.setdefault(section_of(defs[s][0]), []).append(s)
    undef = sorted(s for s in use[sec]
                   if s not in defined and s not in imported
                   and not re.match(r'^[0-9]', s)
                   and s not in ('define','lambda','if','let','let*','letrec','letrec*','cond','else','when','unless','and','or','not','begin','quote','quasiquote','unquote','set!','car','cdr','cons','list','append','null?','pair?','eq?','eqv?','equal?','map','for-each','apply','values','call-with-values','call/cc','call-with-current-continuation','error','display','newline','string-append','string-length','string-ref','substring','string=?','string<?','vector','vector-ref','vector-length','do','case','let-values','define-values','define-record-type','make-parameter','parameterize','case-lambda','dynamic-wind','with-exception-handler','raise','guard','reverse','length','assoc','assq','member','memq','string->list','list->string','number->string','string->number','char->integer','integer->char','char=?','char<?','<','>','<=','>=','=','+','-','*','/','1+','-1+','max','min','abs','quotient','remainder','modulo','even?','odd?','zero?','vector-set!','list-tail','list-ref','string-copy','string-set!','make-string','vector->list','list->vector','symbol->string','string->symbol','eof-object?','read','write','write-char','open-input-string','open-output-string','get-output-string','call-with-port','call-with-input-file','call-with-output-file','close-port','exact->inexact','inexact->exact'))
    if foreign or undef:
        print(f"--- {sec}")
        for k in sorted(foreign):
            print(f"      from [{k}]: {' '.join(foreign[k])}")
        if undef:
            print(f"      UNRESOLVED: {' '.join(undef)}")
