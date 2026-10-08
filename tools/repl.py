#!/usr/bin/env python3
"""Talk to a running schemacs through Guile's REPL server.

`se` opens the door when `SCHEMACS_REPL` names a port, or when it was
started with `--server[=PORT]` - the same thing from the command line. Then
an editor that is already running - blocked in its own event loop, with a
window up - can be asked what it is doing and told to do something else:

    SCHEMACS_REPL=37146 ./se -w /tmp/file.txt &
    tools/repl.py '(+ 1 2)'                  # a plain expression
    tools/repl.py '(render! (*current-frame*))'

`se --repl[=PORT]` is the same conversation without Python: a REPL client
(`schemacs/repl-client.sld`) that connects to a running editor's door and
hands the terminal over to it.

Why this exists: the alternative for driving the GTK backend is a
compositor - `wtype` to type at it and `grim` to look at it - and that is
unreliable in a way that is worse than not working. A keyed run goes to
whichever window the compositor has focused, which is not necessarily the
editor; a silent mis-focus then produces a screenshot of *something else*
that looks like evidence. Every conclusion drawn that way is worthless, and
one was drawn here before the mis-focus was noticed. A REPL cannot
mis-focus: it is the process itself.

Expressions are evaluated in `(guile-user)` - **a module the editor has
already given its own names to** (`start-repl!` runs
`open-editor-namespace!`, which imports every `(schemacs editor ...)`
library there, because GNU Emacs reaches `find-file` from `eval` and a bare
Guile module has no `find-file` at all). So an expression names nothing:

    tools/repl.py '(text-editor-to-string (car (buffer-list)))'

`-m MODULE` still imports first, for a name an editor does not export, and
is no longer needed for the editor's own. **A running editor only has this
if it was started with this code** - the import happens as the door opens -
so an editor left over from an earlier session answers like one from before
the change.
"""
import argparse
import os
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

    read_until_prompt()             # up to the first prompt - and nothing
                                    # before it: the editor suppresses the
                                    # welcome banner (`%inhibit-welcome-message')
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


def port_files():
    """Every back-door port file, newest first.

    `start-repl!' writes the port it took to
    `$XDG_RUNTIME_DIR/schemacs-repl-PID` (or `/tmp`, when the variable is
    unset), so the port is *read* rather than computed - the way
    `emacsclient` reads `$XDG_RUNTIME_DIR/emacs/server` rather than working
    out a socket. The pid is in the name, which is what tells a live
    editor's file from one a killed editor left behind.
    """
    import glob
    import os
    pattern = os.path.join(os.environ.get('XDG_RUNTIME_DIR') or '/tmp',
                           'schemacs-repl-*.port')
    found = []
    for path in glob.glob(pattern):
        try:
            pid = int(path.rsplit('-', 1)[1].split('.')[0])
        except (IndexError, ValueError):
            continue
        try:
            with open(path) as handle:
                port = int(handle.read().strip())
        except (OSError, ValueError):
            continue
        try:
            os.kill(pid, 0)          # gone? then the file is a leftover
        except OSError:
            continue
        found.append((os.stat(path).st_mtime, pid, port, path))
    return sorted(found, reverse=True)


def interactive(port, modules=()):
    """Read an expression, send it, print what the editor said - repeat.

    There is no parser and no local state in this client: each line goes to
    the editor's Guile REPL as it stands, which is what makes the *session*
    a session - the module on the other side is the same one between lines,
    so `(define x 5)' on one line is readable on the next. A blank line, or
    end of input, leaves.
    """
    for module in modules:
        talk(port, '(import %s)' % module)
    print('# the editor\'s REPL on port %d; a blank line leaves' % port)
    while True:
        try:
            line = input('schemacs> ')
        except EOFError:
            print()
            return 0
        if not line.strip():
            return 0
        try:
            result = talk(port, line)
        except OSError as why:
            sys.stderr.write('lost the editor: %s\n' % why)
            return 1
        if result:
            print(result)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('expr', nargs='*', help='expressions to evaluate; with '
                    'none at a terminal, talk to the editor line by line; '
                    'with none and no terminal, list the editors instead, '
                    'as PID PORT FILE')
    ap.add_argument('--pid', type=int, default=None,
                    help='the editor process id, when several have the back '
                         'door open: its port is found from the file it wrote')
    ap.add_argument('-p', '--port', type=int, default=None,
                    help="the port, when you know it: `SCHEMACS_REPL=37146 "
                         "./se FILE` opens the door there. Without this the "
                         "port is read from the file the editor wrote, which "
                         "is what an init file calling `(start-repl!)` makes.")
    ap.add_argument('-m', '--module', action='append', default=[],
                    help='a module to import first')
    args = ap.parse_args()

    # Which editors there are, newest first: the answer to "nobody knows
    # what the port is". Only a live editor's file is listed - a killed one
    # leaves its file behind.
    found = port_files() if args.port is None else []
    if args.pid is not None:
        found = [entry for entry in found if entry[1] == args.pid]
    if found:
        for _mtime, fpid, port, path in found:
            print(fpid, port, path)

    if args.port is not None:
        port = args.port
    elif found:
        port = found[0][2]                # the newest
    else:
        sys.stderr.write(
            'no editor with the back door open'
            + ('' if args.pid is None else ' (pid %d)' % args.pid)
            + '.\nOpen one with `SCHEMACS_REPL=<port> ./se ...`, or with\n'
              '  (import (schemacs repl))\n  (start-repl!)\n'
              'in ~/.config/schemacs/init.scm - which writes the port to\n'
              '%s/schemacs-repl-<pid>.port, where this reads it.\n'
              % (os.environ.get('XDG_RUNTIME_DIR') or '/tmp'))
        return 1

    if not args.expr:
        # Nothing to evaluate: at a terminal, *be* the REPL - a prompt is
        # what someone at a terminal wants, and the one-shot form is for a
        # script. Piped, this is the listing above and nothing else, which
        # is what makes it usable from another program.
        if sys.stdin.isatty():
            return interactive(port, args.module)
        return 0

    text = ''.join('(import %s)' % m for m in args.module) + ' '.join(args.expr)
    result = talk(port, text)
    if result:
        print(result)
    return 0


if __name__ == '__main__':
    sys.exit(main())
