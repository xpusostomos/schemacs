import importlib.util, re, sys, os

HERE = os.path.dirname(os.path.abspath(__file__))
WORK = os.environ.get('CCGEN_WORK', '/tmp/ccgen')

spec = importlib.util.spec_from_file_location('sexp', HERE + '/sexp.py')
S = importlib.util.module_from_spec(spec); spec.loader.exec_module(S)

generated = open(WORK + '/out.scm').read()
gen_by_name = {}
gen_order = []
for chunk in generated.split('\n\n'):
    chunk = chunk.strip('\n')
    if not chunk:
        continue
    m = re.match(r'^;; (\S+)\n', chunk)
    name = m.group(1)
    gen_by_name.setdefault(name, []).append(chunk)
    gen_order.append(name)

exec(open(HERE + '/handports.py').read())

src = open(os.environ.get('CC_LANGS_SRC',
    '/home/chris/GITE/emacs/lisp/progmodes/cc-langs.el')).read()
forms = S.parse(src)
form_names = []
for f in forms:
    if isinstance(f, list) and f and isinstance(f[0], S.Sym) and \
       str(f[0]) in ('c-lang-defconst', 'c-lang-defvar', 'c-lang-setvar'):
        form_names.append((str(f[0]), str(f[1])))

out = []
used_gen = {k: 0 for k in gen_by_name}
hand_done = set()

def next_gen(name):
    i = used_gen[name]
    used_gen[name] += 1
    return gen_by_name[name][i]

for kind, name in form_names:
    if not out:
        out.append(C_FILTER_OPS.strip('\n'))
    if kind == 'c-lang-defconst' and name == 'c-keywords':
        out.append(C_KWDS.strip('\n'))
    if name in hand_done:
        continue
    if name in HAND_REPLACE:
        text, consumed = HAND_REPLACE[name]
        if name not in hand_done:
            hand_done |= consumed
            out.append(text.strip('\n'))
        continue
    if name in SKIP:
        if name not in hand_done:
            hand_done.add(name)
            if SKIP[name]:
                out.append(SKIP[name].strip('\n'))
        continue
    out.append(next_gen(name))

text = '\n\n'.join(out)
open(WORK + '/block.scm', 'w').write(text)
print('wrote', len(out), 'entries', file=sys.stderr)
leftover = {k: len(v) - used_gen[k] for k, v in gen_by_name.items()
            if len(v) - used_gen[k] != 0 and k not in hand_done
            and k not in SKIP}
print('unused generated chunks:', leftover, file=sys.stderr)
