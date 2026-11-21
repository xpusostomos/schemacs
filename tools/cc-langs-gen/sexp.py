import re, sys

class Sym(str): pass
class Str(str): pass
class Q(str):
    """char literal"""
    pass

def tokenize(s):
    i=0; n=len(s)
    while i<n:
        c=s[i]
        if c.isspace(): i+=1; continue
        if c==';':
            while i<n and s[i]!='\n': i+=1
            continue
        if c in '()[]':
            yield c; i+=1; continue
        if c=='"':
            j=i+1; buf=[]
            while j<n:
                if s[j]=='\\': buf.append(s[j:j+2]); j+=2; continue
                if s[j]=='"': break
                buf.append(s[j]); j+=1
            yield ('str', s[i:j+1]); i=j+1; continue
        if c=='?':
            # char literal ?x ?\n ?\( ?\s ?\C-a
            j=i+1
            if j<n and s[j]=='\\':
                j+=1
                if j<n: j+=1
                while j<n and (s[j].isalnum() or s[j]=='-') and s[j-1]=='\\'=='\\':
                    break
                # handle \C-x, \sX, \SX etc
                if j<n and s[j-1]=='\\' and j<n:
                    pass
                while j<n and (s[j].isalnum() or s[j] in '-_'):
                    j+=1
            else:
                j+=1
            yield ('char', s[i:j]); i=j; continue
        if c=="'":
            yield 'quote'; i+=1; continue
        if c=='`':
            yield 'quasiquote'; i+=1; continue
        if c==',':
            if i+1<n and s[i+1]=='@': yield 'unquote-splicing'; i+=2
            else: yield 'unquote'; i+=1
            continue
        if c=='#':
            # #'fun, #(...), #xNN, #<...>
            if i+1<n and s[i+1]=="'":
                yield 'function'; i+=2; continue
            j=i+1
            while j<n and not s[j].isspace() and s[j] not in '()[]': j+=1
            yield ('atom', s[i:j]); i=j; continue
        j=i
        while j<n:
            ch=s[j]
            if ch=='\\':
                j+=2; continue
            if ch.isspace() or ch in '()[]";': break
            j+=1
        yield ('atom', s[i:j]); i=j
    yield ('eof',None)

def parse(s):
    it=list(tokenize(s)); pos=[0]
    def peek(): return it[pos[0]]
    def next_():
        t=it[pos[0]]; pos[0]+=1; return t
    def rd(depth=0):
        t=next_()
        if t=='(' or t=='[':
            close=')' if t=='(' else ']'
            out=[]
            while True:
                t2=peek()
                if t2==close: next_(); return out
                if t2==('eof',None): raise ValueError('eof in list')
                out.append(rd(depth+1))
        if t in ('quote','quasiquote','unquote','unquote-splicing','function'):
            return [Sym(t), rd(depth+1)]
        if isinstance(t,tuple):
            if t[0]=='str': return Str(t[1])  # keep raw including quotes
            if t[0]=='char': return Q(t[1])
            if t[0]=='atom': return Sym(t[1])
        return t
    forms=[]
    while peek()!=('eof',None):
        forms.append(rd())
    return forms

def dump(x):
    if isinstance(x, Q): return x
    if isinstance(x, Str): return x
    if isinstance(x, Sym): return x
    if isinstance(x, list):
        return '('+' '.join(dump(e) for e in x)+')'
    return str(x)

if __name__=='__main__':
    forms=parse(open(sys.argv[1]).read())
    for f in forms[:3]:
        print(dump(f)); print('---')
