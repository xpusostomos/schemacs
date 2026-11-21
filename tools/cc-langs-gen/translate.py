import importlib.util, sys, re, os

HERE = os.path.dirname(os.path.abspath(__file__))
WORK = os.environ.get('CCGEN_WORK', '/tmp/ccgen')
SRC = os.environ.get('CC_LANGS_SRC',
                     '/home/chris/GITE/emacs/lisp/progmodes/cc-langs.el')

spec = importlib.util.spec_from_file_location('sexp', HERE + '/sexp.py')
S = importlib.util.module_from_spec(spec); spec.loader.exec_module(S)
Sym, Str, Q = S.Sym, S.Str, S.Q


class Unsupported(Exception):
    pass


# ---------------------------------------------------------------- strings

def decode_elisp_string(raw):
    assert raw[0] == '"' and raw[-1] == '"'
    s = raw[1:-1]
    out = []
    i = 0
    n = len(s)
    while i < n:
        c = s[i]
        if c != '\\':
            out.append(c); i += 1; continue
        e = s[i + 1]
        if e == '\\': out.append('\\')
        elif e == '"': out.append('"')
        elif e == 'n': out.append('\n')
        elif e == 't': out.append('\t')
        elif e == 'r': out.append('\r')
        elif e == 'f': out.append('\f')
        elif e == 'v': out.append('\v')
        elif e == 'a': out.append('\a')
        elif e == 'b': out.append('\b')
        elif e == 'd': out.append('\x7f')
        elif e == 'e': out.append('\x1b')
        elif e == 's': out.append('\x20')   # \s- is super, bare \s is space
        elif e == 'x':
            j = i + 2
            while j < n and s[j] in '0123456789abcdefABCDEF': j += 1
            out.append(chr(int(s[i + 2:j] or '0', 16)))
            i = j; continue
        elif e in '01234567':
            j = i + 1
            while j < n and j < i + 4 and s[j] in '01234567': j += 1
            out.append(chr(int(s[i + 1:j], 8)))
            i = j; continue
        elif e == '^':
            j = i + 2
            ch = s[j]
            j += 1
            if ch == '?': out.append('\x7f')
            else: out.append(chr(ord(ch) & 0x1f))
            i = j; continue
        elif e in 'CMSAHs':
            # modifier escape; scan the dash and the base char, approximate
            raise Unsupported('modifier escape in string: \\' + e)
        elif e == '\n':
            pass  # backslash-newline is nothing
        else:
            out.append(e)  # Emacs ignores the backslash
        i += 2
    return ''.join(out)


def encode_scheme_string(value):
    # Guile's reader: `\x' needs at least two hex digits and `;' is not a
    # terminator, so emit exactly two and protect a following hex digit by
    # escaping it too.
    out = ['"']
    i = 0
    n = len(value)
    while i < n:
        ch = value[i]
        o = ord(ch)
        if ch == '\\': out.append('\\\\')
        elif ch == '"': out.append('\\"')
        elif ch == '\n': out.append('\\n')
        elif ch == '\t': out.append('\\t')
        elif ch == '\r': out.append('\\r')
        elif ch == '\f': out.append('\\f')
        elif o < 32 or o == 127:
            out.append('\\x%02x' % o)
            if i + 1 < n and value[i + 1] in '0123456789abcdefABCDEF':
                out.append('\\x%02x' % ord(value[i + 1]))
                i += 1
        else: out.append(ch)
        i += 1
    out.append('"')
    return ''.join(out)


# ---------------------------------------------------------------- chars

CHAR_NAMES = {
    0: '#\\null', 7: '#\\alarm', 8: '#\\backspace', 9: '#\\tab',
    10: '#\\newline', 11: '#\\vtab', 12: '#\\page', 13: '#\\return',
    27: '#\\escape', 32: '#\\space', 127: '#\\delete',
}

def char_literal(codepoint):
    if codepoint in CHAR_NAMES:
        return CHAR_NAMES[codepoint]
    if 33 <= codepoint <= 126:
        return '#\\' + chr(codepoint)
    return '#\\x%x' % codepoint


def decode_char_literal(raw):
    assert raw[0] == '?'
    body = raw[1:]
    if not body.startswith('\\'):
        return ord(body)
    b = body[1:]
    if b == '\\':
        return 92
    simple = {'n': 10, 't': 9, 'r': 13, 'f': 12, 'v': 11, 'a': 7,
              'b': 8, 'd': 127, 'e': 27, 's': 32, ' ': 32}
    if b in simple:
        return simple[b]
    if b.startswith('x'):
        return int(b[1:], 16)
    if b and b[0] in '01234567':
        return int(b, 8)
    if b.startswith('^'):
        ch = b[1:]
        return 127 if ch == '?' else ord(ch) & 0x1f
    if len(b) == 1:
        return ord(b)
    raise Unsupported('char literal ' + raw)


# ---------------------------------------------------------------- symbols

def encode_symbol(name):
    name = re.sub(r'\\(.)', r'\1', name)
    if re.match(r'^(?:[^\s()\[\]{}";|\\\']|[+\-.*/<>!?=_:$%&~^@])+$', name) and \
       not re.match(r'^[0-9]', name) and name not in ('',):
        # Guile identifiers: also reject things starting with '.', '#'
        return name
    # Guile's default reader has no |bars|; its extended symbol syntax
    # `#{...}#` names any symbol (measured: eq? to string->symbol).
    return '#{' + name + '}#'

# ---------------------------------------------------------------- translate

RENAMES = {
    'consp': 'pair?',
    'listp': 'list?',
    'symbolp': 'symbol?',
    'stringp': 'string?',
    'numberp': 'number?',
    'integerp': 'integer?',
    'floatp': 'number?',
    'functionp': 'procedure?',
    'vectorp': 'vector?',
    'null': '%c-false',
    'char-table-p': 'char-table?',
    'substring': '%substring',
    'string': '%string',
    'length': '%length',
    'string=': 'string=?',
    'string-equal': 'string-equal',
    'eq': 'eq?',
    'eql': 'eqv?',
    'equal': 'equal?',
    'string<': 'string<?',
    'regexp-opt': 'regexp-opt',
    'regexp-opt-depth': 'regexp-opt-depth',
    'regexp-quote': 'regexp-quote',
    'mapconcat': 'mapconcat',
}

KNOWN_CALLS = {
    'c-lang-const', 'c-make-keywords-re', 'concat', 'append', 'and', 'or',
    'not', 'null', 'list', 'cons', 'car', 'cdr', 'cadr', 'cddr', 'caar',
    'cdar', 'caddr', 'cdddr', 'length', 'string-match', 'memq', 'remq',
    'delq', 'nreverse', 'reverse', 'nconc', 'c-concat-separated',
    'c-mode-var', 'c-mode-symbol', 'c-make-bare-char-alt',
    'c-lang-defconst-eval-immediately', 'c-major-mode-is', 'c-filter-ops',
    'c--mapcan', 'c--set-difference', 'c--intersection',
    'c--delete-duplicates', 'c-with-syntax-table', 'make-syntax-table',
    'copy-syntax-table', 'modify-syntax-entry', 'c-populate-syntax-table',
    'char-syntax', 'c-int-to-char', 'intern', 'error', 'string', 'eval',
    'regexp-unmatchable', 'upcase', 'downcase', 'identity', 'nth',
    'nthcdr', 'stringp', 'symbolp', 'listp', 'consp', 'numberp',
    'c-add-language', 'c-characterp', 'c-put-char-property',
    'c-get-char-property', 'c-clear-char-property', 'c-clear-char-properties',
    'c-clear-char-property-with-value', 'c-put-char-properties',
    'c-get-char-properties', 'c-parse-quotes-before-change',
    'c-parse-quotes-after-change', 'c-depropertize-new-text',
    'c-extend-region-for-CPP', 'c-before-change-include-<>',
    'c-neutralize-syntax-in-and-after', 'include', 'require',
    'eval-when-compile', 'when', 'unless', 'if', 'cond', 'lambda',
    'quote', 'quasiquote', 'unquote', 'unquote-splicing', 'function',
    'progn', 'let', 'let*', 'setq',
    'mapcar', 'assoc', 'aref', 'elt', 'remove', 'delete',
    '+', '-', '*', '/', '=', '<', '>', '<=', '>=',
    'c-int-to-char', 'c-characterp', 'char-syntax', 'modify-syntax-entry',
    'copy-syntax-table', 'make-syntax-table', 'c-mode-var',
    'c-make-keywords-re', 'c-filter-ops', 'c-with-syntax-table',
    'regexp-opt', 'regexp-opt-depth', 'regexp-quote', 'concat',
    'c--delete-duplicates', 'c--mapcan', 'c--set-difference',
    'c--intersection', 'c-lang-const', 'c-lang-defconst-eval-immediately',
    'c-major-mode-is', 'length', 'substring',
    'regexp-strings', 'plain-strings', 'c-regular-keywords-regexp',
    'regexp-opt', 'regexp-opt-depth', 'regexp-quote', 'substring',
    'string=', 'eq', 'eql', 'equal', 'funcall', 'mapcar',
    'c-lang-const-eval-immediately', 'c-char-escaped',
    'c-string-innards', 'c-ml-string-opener', 'c-forward-token-2',
    'c-backward-token-2', 'c-forward-token-1', 'c-backward-token-1',
    'c-syntactic-re-search-forward', 'c-syntactic-re-search-backward',
    'c-forward-sws', 'c-backward-sws', 'c-in-comment', 'c-search-char-forward',
    'c-semi-pos', 'c-pos-of-preprocessor', 'c-at-comment-start',
    'c-alpha', 'c-alnum', 'c-digit', 'c-upper', 'c-lower',
}

EXPR_HEADS_RENAME = {'substring', 'string=', 'eq', 'eql', 'equal', 'string<'}

STRING_ARG_POSITIONS = {'concat': tuple(range(64))}

LIST_ARG_POSITIONS = {
    'append': tuple(range(64)),
    'c--set-difference': (0, 1),
    'c--intersection': (0, 1),
    'c--delete-duplicates': (0,),
    'c-make-keywords-re': (1,),
    'c-make-bare-char-alt': (0,),
    'cons': (1,),
    'nreverse': (0,),
    'reverse': (0,),
    'mapcar': (1,),
    'memq': (1,),
    'delq': (1,),
    'remq': (1,),
    'assoc': (1,),
    'c-concat-separated': (0,),
    'regexp-opt': (0,),
    'mapconcat': (1,),
    'elt': (0,),
    'c-filter-ops': (0,),
}


def translate_expr(x, indent=0):
    pad = ' ' * indent
    if isinstance(x, Q):
        # Emacs chars are integers; in *expression* position a literal
        # has to be the code point it compares/counts as (`(= (elt s 0)
        # ?x)'). In quoted data the character object is kept (see
        # translate_data) - that is what this tree's character
        # functions take.
        return str(decode_char_literal(str(x)))
    if isinstance(x, Str):
        return encode_scheme_string(decode_elisp_string(str(x)))
    if isinstance(x, Sym):
        name = str(x)
        if name == 't':
            return '#t'
        if name == 'nil':
            return '#f'
        if re.fullmatch(r'[-+]?[0-9]+(\\.[0-9]+)?', name):
            return name
        if name.startswith(':'):
            return "'" + name
        return encode_symbol(name)
    if not isinstance(x, list):
        raise Unsupported('atom ' + repr(x))
    if not x:
        return "'()"
    head = x[0]
    if head == 'quote':
        return "'" + translate_data(x[1])
    if head == 'function':
        arg = x[1]
        if isinstance(arg, list) and arg and arg[0] == 'lambda':
            return translate_expr(arg, indent)
        if isinstance(arg, Sym):
            return encode_symbol(str(arg))
        raise Unsupported('function of ' + S.dump(arg))
    if head == 'quasiquote':
        return '`' + translate_qq(x[1], indent)
    if head == 'lambda':
        params = x[1]
        if not isinstance(params, list) or any(isinstance(p, list) for p in params):
            raise Unsupported('lambda params ' + S.dump(params))
        body = x[2:]
        return '(lambda (%s) %s)' % (
            ' '.join(encode_symbol(str(p)) for p in params),
            ' '.join(translate_expr(b, indent + 2) for b in body))
    if head == 'if':
        test = '(%%c-true %s)' % translate_expr(x[1], indent)
        if len(x) == 3:
            return '(if %s %s #f)' % (test, translate_expr(x[2], indent))
        if len(x) == 4:
            return '(if %s %s %s)' % (test, translate_expr(x[2], indent),
                                      translate_expr(x[3], indent))
        return '(if %s %s (begin %s))' % (
            test, translate_expr(x[2], indent),
            ' '.join(translate_expr(b, indent + 2) for b in x[3:]))
    if head == 'when':
        return '(if (%%c-true %s) (begin %s) #f)' % (
            translate_expr(x[1], indent),
            ' '.join(translate_expr(b, indent + 2) for b in x[2:]))
    if head == 'unless':
        return '(if (%%c-true %s) #f (begin %s))' % (
            translate_expr(x[1], indent),
            ' '.join(translate_expr(b, indent + 2) for b in x[2:]))
    if head == 'cond':
        clauses = []
        for cl in x[1:]:
            if not isinstance(cl, list):
                raise Unsupported('cond clause ' + S.dump(cl))
            test = cl[0]
            if isinstance(test, Sym) and str(test) == 't':
                clauses.append('(else %s)' % ' '.join(
                    translate_expr(b, indent + 2) for b in cl[1:]))
            else:
                clauses.append('((%%c-true %s) %s)' % (
                    translate_expr(test, indent + 1),
                    ' '.join(translate_expr(b, indent + 2) for b in cl[1:])))
        last = x[-1] if len(x) > 1 else None
        has_else = (isinstance(last, list) and last and
                    isinstance(last[0], Sym) and str(last[0]) == 't')
        if not has_else:
            clauses.append('(else #f)')
        return '(cond %s)' % ' '.join(clauses)
    if isinstance(head, Sym):
        name = str(head)
        if name == 'not' and len(x) == 2:
            return '(not (%%c-true %s))' % translate_expr(x[1], indent + 1)
        if name == 'or' and len(x) > 1:
            parts = ['(and (%%c-true %s) %s)' % (
                        translate_expr(a, indent + 1),
                        translate_expr(a, indent + 1))
                     for a in x[1:-1]]
            parts.append(translate_expr(x[-1], indent + 1))
            return '(or %s)' % ' '.join(parts)
        if name == 'and' and len(x) > 1:
            body = translate_expr(x[-1], indent + 2)
            for a in reversed(x[1:-1]):
                body = '(if (%%c-true %s) %s #f)' % (
                    translate_expr(a, indent + 2), body)
            return body
        if name in ('1+', '1-'):
            if len(x) != 2:
                raise Unsupported('%s arity' % name)
            return '(%s %s %s)' % ('+' if name == '1+' else '-',
                                   translate_expr(x[1], indent + 1),
                                   '1')
        if name in ('let', 'let*'):
            bindings = x[1]
            if not isinstance(bindings, list):
                raise Unsupported('let bindings')
            parts = []
            for b in bindings:
                if isinstance(b, Sym):
                    parts.append('(%s \'())' % encode_symbol(str(b)))
                elif isinstance(b, list) and len(b) == 2 and isinstance(b[0], Sym):
                    parts.append('(%s %s)' % (encode_symbol(str(b[0])),
                                              translate_expr(b[1], indent + 2)))
                else:
                    raise Unsupported('let binding ' + S.dump(b))
            body = ' '.join(translate_expr(b, indent + 2) for b in x[2:])
            return '(%s (%s) %s)' % (name, ' '.join(parts), body)
        if name == 'setq':
            pairs = x[1:]
            if len(pairs) % 2:
                raise Unsupported('odd setq')
            def build(i):
                var = pairs[i]
                val = translate_expr(pairs[i + 1], indent + 4)
                tmp = '%%q%d' % i
                if i + 2 >= len(pairs):
                    return ('(let ((%s %s)) (set! %s %s) %s)'
                            % (tmp, val, encode_symbol(str(var)), tmp, tmp))
                inner = build(i + 2)
                return ('(let ((%s %s)) (set! %s %s) %s)'
                        % (tmp, val, encode_symbol(str(var)), tmp, inner))
            return build(0)
        if name == 'push':
            if len(x) != 3:
                raise Unsupported('push arity')
            var = encode_symbol(str(x[2]))
            return '(let ((%%pv %s)) (set! %s (cons %%pv %s)) %s)' % (
                translate_expr(x[1], indent + 2), var, var, var)
        if name == 'while':
            loop = '%%while%d' % indent
            body = ' '.join(translate_expr(b, indent + 2) for b in x[2:])
            return '(let %s () (if %s (begin %s (%s)) #f))' % (
                loop, translate_expr(x[1], indent + 2), body, loop)
        if name == 'progn':
            return '(begin %s)' % ' '.join(
                translate_expr(b, indent + 1) for b in x[1:])
        if name == 'funcall':
            f = translate_expr(x[1], indent + 1)
            return '(%s %s)' % (f, ' '.join(
                translate_expr(a, indent + 1) for a in x[2:]))
        if name == 'mapcar':
            return '(mapcar %s %s)' % (translate_expr(x[1], indent + 1),
                                       translate_expr(x[2], indent + 1))
        if name in ('let', 'let*', 'setq', 'while', 'dolist', 'push',
                    'condition-case', 'catch', 'throw', 'pop',
                    'progn', 'save-match-data', 'save-excursion',
                    'setcdr', 'setcar', 'obarray-make'):
            raise Unsupported('head ' + name)
        if name in KNOWN_CALLS:
            fn = RENAMES.get(name, name)
            args = []
            for i, a in enumerate(x[1:]):
                prev = x[i] if i > 0 else None
                if (isinstance(prev, Sym) and str(prev) in
                        (':test', ':test-not', ':key', ':if', ':if-not')
                        and isinstance(a, list) and len(a) == 2
                        and a[0] == 'quote' and isinstance(a[1], Sym)):
                    # Emacs writes `:test \='string-equal'' - a function
                    # *name*; a symbol is not applicable here, so the
                    # ported call hands the procedure itself.
                    nm = str(a[1])
                    args.append(RENAMES.get(nm, encode_symbol(nm)))
                    continue
                txt = translate_expr(a, indent + 1)
                if i in LIST_ARG_POSITIONS.get(name, ()):
                    if not (isinstance(a, list) and a and a[0] == 'quote'):
                        txt = '(or %s \'())' % txt
                if i in STRING_ARG_POSITIONS.get(name, ()):
                    txt = '(or %s "")' % txt
                args.append(txt)
            return '(%s %s)' % (fn, ' '.join(args))
        raise Unsupported('unknown call ' + name)
    raise Unsupported('bad head ' + S.dump(head))


def translate_data(x):
    if isinstance(x, Q):
        return char_literal(decode_char_literal(str(x)))
    if isinstance(x, Str):
        return encode_scheme_string(decode_elisp_string(str(x)))
    if isinstance(x, Sym):
        name = str(x)
        if name == 'nil':
            return '#f'
        if re.fullmatch(r'[-+]?[0-9]+(\\.[0-9]+)?', name):
            return name
        return encode_symbol(name)
    if isinstance(x, list):
        if not x:
            return '()'
        return '(' + ' '.join(translate_data(e) for e in x) + ')'
    raise Unsupported('data atom ' + repr(x))


def translate_qq(x, indent):
    # quasiquote: data with expression holes. `nil' here is list
    # structure that will be evaluated (`(append ...,@xs nil)'), so it is
    # the empty list; a *quoted* nil is an element value (see
    # translate_data).
    if isinstance(x, Sym) and str(x) == 'nil':
        # The quasiquote builds *code*: a bare `()` is not a Scheme
        # expression, so nil is written `'()` - the empty list as a
        # value.
        return "(quote ())"
    if isinstance(x, list):
        if x and isinstance(x[0], Sym) and str(x[0]) == 'unquote':
            return ',' + translate_expr(x[1], indent)
        if x and isinstance(x[0], Sym) and str(x[0]) == 'unquote-splicing':
            arg = x[1]
            if isinstance(arg, list) and arg and arg[0] == 'quote':
                return ',@' + translate_expr(arg, indent)
            return ',@(or ' + translate_expr(arg, indent) + " '())" 
        return '(' + ' '.join(translate_qq(e, indent) for e in x) + ')'
    return translate_data(x)


def form_name(f):
    return str(f[1]) if isinstance(f, list) and len(f) > 1 and isinstance(f[1], Sym) else '?'


def main():
    src = open(SRC).read()
    forms = S.parse(src)
    ok = []
    bad = []
    for f in forms:
        if not isinstance(f, list) or not f or not isinstance(f[0], Sym):
            continue
        head = str(f[0])
        if head == 'c-lang-defconst':
            name = form_name(f)
            rest = f[2:]
            doc = None
            if rest and isinstance(rest[0], Str) and str(rest[0]).startswith('"'):
                doc = decode_elisp_string(str(rest[0])); rest = rest[1:]
            if len(rest) % 2:
                bad.append((name, 'odd args', S.dump(f)))
                continue
            try:
                pairs = []
                for i in range(0, len(rest), 2):
                    lang = rest[i]
                    val = rest[i + 1]
                    ltxt = translate_data(lang)
                    vtxt = translate_expr(val)
                    pairs.append(ltxt)
                    pairs.append(vtxt)
                ok.append((name, '(c-lang-defconst %s%s\n  %s)' % (
                    encode_symbol(name),
                    ('\n  ' + encode_scheme_string(doc)) if doc else '',
                    '\n  '.join(pairs))))
            except Unsupported as e:
                bad.append((name, str(e), S.dump(f)))
        elif head in ('c-lang-defvar', 'c-lang-setvar'):
            name = form_name(f)
            try:
                ok.append((name, '(%s %s %s)' % (
                    head, translate_data(f[1]),
                    translate_expr(f[2]))))
            except Unsupported as e:
                bad.append((name, str(e), S.dump(f)))
    print('translated', len(ok), 'unsupported', len(bad), file=sys.stderr)
    for name, why, dump in bad:
        print('UNSUPPORTED %s: %s' % (name, why), file=sys.stderr)
    with open(WORK + '/out.scm', 'w') as out:
        for name, txt in ok:
            out.write(';; ' + name + '\n' + txt + '\n\n')
    with open(WORK + '/bad.txt', 'w') as out:
        for name, why, dump in bad:
            out.write('\n;;;; UNSUPPORTED %s: %s\n%s\n' % (name, why, dump))


main()
