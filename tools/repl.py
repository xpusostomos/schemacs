#!/usr/bin/env python3
"""Talk to a running schemacs through Guile's REPL server.

`seg` passes `--listen` to Guile when `SCHEMACS_REPL` names a port, so an
editor that is already running - blocked in its own event loop, with a
window up - can be asked what it is doing and told to do something else.

    SCHEMACS_REPL=37146 ./seg /tmp/file.txt &
    tools/repl.py '(+ 1 2)'                  # a plain expression
    tools/repl.py -m '(schemacs editor xdisp)' '(render! (*current-frame*))'

Why this exists: the alternative for driving the GTK backend is a
compositor - `wtype` to type at it and `grim` to look at it - and that is
unreliable in a way that is worse than not working. A keyed run goes to
whichever window the compositor has focused, which is not necessarily the
editor; a silent mis-focus then produces a screenshot of *something else*
that looks like evidence. Every conclusion drawn that way is worthless, and
one was drawn here before the mis-focus was noticed. A REPL cannot
mis-focus: it is the process itself.

Expressions are evaluated in `(guile-user)`, so a module's names are
reached by naming it:

    tools/repl.py -m '(schemacs editor engine)' '(text-editor-to-string (car (buffer-list)))'
"""
import argparse
import socket
import sys
import time

PROMPT = 'scheme@(guile-user)>'


def talk(port, text, timeout=25.0):
    """Send TEXT to the REPL on PORT; answer everything it printed.

    Reading stops at the next bare prompt, which is how the REPL says it
    has finished - the expression has been evaluated and there is nothing
    more coming. A prompt inside the *output* (an expression that printed
    one) is not confused for it because only a trailing one ends the read.
    """
    sock = socket.create_connection(('127.0.0.1', port), timeout=timeout)
    sock.settimeout(timeout)
    buf = b''

    def read_until_prompt():
        nonlocal buf
        while not buf.rstrip().endswith(b'>'):
            try:
                chunk = sock.recv(65536)
            except socket.timeout:
                break
            if not chunk:
                break
            buf += chunk

    read_until_prompt()             # the banner, up to the first prompt
    if b'[1]>' in buf or b'[2]>' in buf:
        # a previous call left the REPL in an error's nested prompt; get
        # back to the top level rather than evaluating inside it
        buf = b''
        sock.sendall(b',q\n')
        read_until_prompt()
    buf = b''
    sock.sendall(text.encode() + b'\n')
    read_until_prompt()
    sock.close()
    out = buf.decode('utf-8', 'replace')
    # drop the echoed prompt and the echoed response markers
    return '\n'.join(line for line in out.split('\n')
                     if not line.startswith(PROMPT)).strip()


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('expr', nargs='+', help='expressions to evaluate')
    ap.add_argument('-p', '--port', type=int,
                    default=37146, help='the REPL port (default 37146)')
    ap.add_argument('-m', '--module', action='append', default=[],
                    help='a module to import first')
    args = ap.parse_args()
    text = ''.join('(import %s)' % m for m in args.module) + ' '.join(args.expr)
    result = talk(args.port, text)
    if result:
        print(result)
    return 0


if __name__ == '__main__':
    sys.exit(main())
