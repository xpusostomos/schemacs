#!/usr/bin/env python3
"""Drive the real editor in a pty and check the things unit tests cannot see.

The unit suites never open a terminal and never redisplay, so a whole
class of bug is invisible to them:

  * a library moved without one of its imports - `editor/disp-table.sld`
    was moved with `(scheme base)' and `(scheme char)' but not
    `(scheme write)', so `display' was unbound. Every test passed and the
    editor died on its first redisplay.
  * a command run while a minibuffer is active acting on the wrong
    buffer, or an error the command loop swallows so that the prompt
    draws over the message and typed text leaks into the buffer.
  * a definition a library cannot export because the name is imported -
    `(define newline ...)' was dropped, and RET called Scheme's output
    procedure.  It clears the echo area as if a command had run, so only
    the file on disk shows it.

Both were found by hand, in a pty, after the suites were green. This
script is that check, kept.

Usage:  python3 tools/pty-check.py [name ...]
        (no arguments runs every check)

Each check starts `main-ncurses.scm` on a real terminal, sends keys, and
asserts on the screen and on the files left behind. Exit status is 0 when
every check passes.
"""
import os, pty, select, sys, time, base64

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

C_x = b"\x18"
C_c = b"\x03"
C_f = b"\x06"
C_a = b"\x01"
C_k = b"\x0b"
C_s = b"\x13"
C_u = b"\x15"
C_g = b"\x07"
C_q = b"\x11"   # C-q, quoted-insert
C_r = b"\x12"   # C-r, recursive-edit / find-file-read-only's chord
C_v = b"\x16"   # C-v, scroll-up / find-alternate-file's chord
M_TILDE = b"\x1b~"   # M-~
# The arrow keys. A terminal in keypad application mode - which is what
# ncurses puts it in when the editor starts - sends these three bytes for
# `<down>' and `<up>', and the same with a leading ESC for `M-<down>' and
# `M-<up>'. (`ESC [ B' is the *normal* mode spelling, which is not what a
# terminal sends here and which ncurses does not recognise.)
DOWN = b"\x1bOB"
UP = b"\x1bOA"
M_DOWN = b"\x1b" + DOWN
M_UP = b"\x1b" + UP
RET = b"\r"
ESC = b"\x1b"


def resize(fd, pid, rows, cols):
    """Make the pty ROWS x COLS and tell the editor, as a terminal does.

    A real resize reaches the program two ways: the kernel's window size
    changes (which `lines' and `cols' read) and SIGWINCH is delivered
    (which ncurses turns into a KEY_RESIZE event). Both are sent here.
    """
    import fcntl, struct, signal, termios
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    os.kill(pid, signal.SIGWINCH)


def drive(keys, path, settle=1.5, gap=0.3, term=None, background="0000/0000/0000",
          report_exit=False):
    """Run the editor on PATH, send KEYS, and return everything it drew.

    TERM is the terminal type the editor is told it has (default: the
    `xterm' of the 8-colour checks, or $SCHEMACS_TEST_TERM).  BACKGROUND
    is what this pretend terminal answers when asked its background
    colour, as `rgb:RRRR/GGGG/BBBB'; the default is black, which is what
    a dark terminal says.  `term/xterm.el' asks - `\\e[>0c' to learn who
    it is talking to, then `\\e]11;?' and `\\e]10;?' - and waits up to
    two seconds for each answer, so the harness answers as xterm would
    or the editor would spend six seconds starting.  None means answer
    nothing, which is what a pty with no terminal behind it does.

    With REPORT-EXIT true, the return is (SCREEN . EXITED-P): whether
    the editor had already quit on its own when the harness went to kill
    it - which a command like C-x C-c is supposed to make it do.
    """
    pid, fd = pty.fork()
    if pid == 0:
        os.environ["GUILE_WARN_DEPRECATED"] = "no"
        os.environ["TERM"] = term or os.environ.get("SCHEMACS_TEST_TERM", "xterm")
        os.chdir(REPO)
        os.execvp("guile", ["guile", "--no-auto-compile", "--r7rs", "-L", ".",
                            "-s", "main-ncurses.scm", path])
    out = b""
    answers = {
        # Secondary DA: an xterm of a version that reports its colours
        b"\x1b[>0c": b"\x1b[>41;370;0c",
        b"\x1b]11;?\x1b\\": b"\x1b]11;rgb:%s\x1b\\" % background.encode()
                        if background else None,
        b"\x1b]10;?\x1b\\": b"\x1b]10;rgb:ffff/ffff/ffff\x1b\\",
    }
    answered = set()

    def drain(timeout):
        nonlocal out
        while select.select([fd], [], [], timeout)[0]:
            try:
                d = os.read(fd, 65536)
            except OSError:
                break
            if not d:
                break
            out += d
            for query, reply in answers.items():
                if query in out and query not in answered:
                    answered.add(query)
                    if reply is not None:
                        os.write(fd, reply)

    # the settle time is spent watching for the terminal queries, which
    # come as the editor starts
    end = time.time() + settle
    while time.time() < end:
        drain(0.05)

    for k in keys:
        if isinstance(k, tuple):
            # ("resize" rows cols): make the terminal that size, as a
            # window manager does, and let the editor notice
            resize(fd, pid, k[1], k[2])
            time.sleep(gap)
            drain(0.05)
            continue
        os.write(fd, k)
        time.sleep(gap)
        drain(0.05)
    time.sleep(0.6)
    drain(0.2)
    # If the editor quit on its own - a command like C-x C-c, or a file
    # it could not open - the wait below reaps it; otherwise it is still
    # running and gets killed. The distinction is what REPORT-EXIT asks
    # for: a quit command that leaves the editor alive reads as a
    # command that did nothing.
    done, _ = os.waitpid(pid, os.WNOHANG)
    exited = done == pid
    if not exited:
        try:
            os.kill(pid, 9)
        except Exception:
            pass
        os.waitpid(pid, 0)
    text = out.decode("utf-8", "replace")
    return (text, exited) if report_exit else text


def check_minibuffer():
    """C-x C-f, then edit the prompt (C-a, C-k), type a path, RET.

    Fails if a command run with a minibuffer active acts on the frame's
    buffer instead of the prompt - which shows up as typed text leaking
    into the buffer, or as the file not being visited at all.
    """
    target = "/tmp/pty-check-target.txt"
    other = "/tmp/pty-check-other.txt"
    open(target, "w").write("TARGET-ONE\nTARGET-TWO\n")
    open(other, "w").write("other\n")

    screen = drive([C_x + C_f, C_a, C_k, target.encode(), RET, C_x + C_c],
                   other)
    problems = []
    for want in ("TARGET-ONE", "pty-check-target.txt"):
        if want not in screen:
            problems.append("not on screen: %r" % want)
    if open(other).read() != "other\n":
        problems.append("the minibuffer's keys reached the buffer")
    return problems


def check_save():
    """Type, save with C-x C-s, and check the file on disk.

    This is the path that runs the line-break encoder and the final-newline
    rule, neither of which the unit suites exercise through a real save.
    """
    path = "/tmp/pty-check-save.txt"
    open(path, "w").write("hello\n")
    drive([C_u, b"5", b"a", C_x + C_s, C_x + C_c], path)
    got = open(path).read()
    return [] if got == "aaaaahello\n" else ["saved %r, expected 'aaaaahello\\n'" % got]


def check_save_y_n():
    """The "Save file? " prompt answers on the key, with no RET.

    GNU Emacs's `map-y-or-n-p' reads a single key (`read-char-from-
    minibuffer'), so `y' or `n' alone answers "Save file X? " - it used
    to need a RET after the answer.  A bare `y' saves and (nothing else
    being modified) the exit proceeds; a bare `n' goes straight on to
    the "Modified buffers exist; exit anyway? " question.
    """
    path = "/tmp/pty-check-save-yn.txt"
    problems = []

    open(path, "w").write("hello\n")
    screen, exited = drive([b"X", C_x + C_c, b"y"], path,
                           report_exit=True, gap=0.4)
    if not exited or open(path).read() != "Xhello\n":
        problems.append("a bare `y' did not save the buffer and quit "
                        "(exited=%s file=%r)" % (exited, open(path).read()))

    open(path, "w").write("hello\n")
    screen, exited = drive([b"X", C_x + C_c, b"n", b"no" + b"\r"], path,
                           report_exit=True, gap=0.4)
    if exited:
        problems.append("a bare `n' should decline the save and ask "
                        "whether to exit anyway, not quit")
    if "exit anyway" not in screen:
        problems.append("after `n' the exit-anyway question did not "
                        "come up")
    if open(path).read() != "hello\n":
        problems.append("`n' was taken as a save (file %r)"
                        % open(path).read())
    return problems


def check_redisplay():
    """Just open a file and confirm it is drawn.

    The narrowest possible check, and the one that catches a missing
    import in the rendering path: a library that fails to compile at run
    time kills the editor before it draws anything.
    """
    path = "/tmp/pty-check-draw.txt"
    open(path, "w").write("VISIBLE-LINE\n")
    screen = drive([C_x + C_c], path)
    if "VISIBLE-LINE" not in screen:
        return ["the buffer was never drawn (a run-time error before "
                "redisplay?)"]
    return []


def check_newline():
    """Type two lines and RET, then quit without saving; save and re-read.

    RET is the check that `newline' is the editing command and not
    Scheme's output procedure.  When `(define newline ...)' in a library
    is dropped because `(scheme base)' also exports `newline', the keymap
    binds the output procedure: RET then writes a newline to standard
    output, inserts nothing, and clears the echo area as though a command
    had run.  Every unit test stays green through that.
    """
    path = "/tmp/pty-check-newline.txt"
    open(path, "w").write("")
    drive([b"a", RET, b"b", C_x + C_s, C_x + C_c], path)
    got = open(path).read()
    return [] if got == "a\nb\n" else [
        "RET did not insert a line break: file is %r, expected 'a\\nb\\n'" % got]


def check_crlf():
    """Save a CRLF file back as CRLF, over the startup path.

    The line-break convention a file was read with is the *buffer's* - GNU
    Emacs's `buffer-file-coding-system' - and saving encodes the breaks
    back with it.  It was a slot on the frame once, which meant one
    frame-wide answer for every buffer in it: visit a CRLF file and then
    an LF one, and saving the CRLF file rewrote it with LF.

    This drives the path the unit tests cannot: `main-ncurses.scm' visits
    the file named on the command line, which is where the convention is
    recorded now.
    """
    path = "/tmp/pty-check-crlf.txt"
    with open(path, "wb") as port:
        port.write(b"one\r\ntwo\r\n")
    drive([b"X", C_x + C_s, C_x + C_c], path)
    with open(path, "rb") as port:
        got = port.read()
    return [] if got == b"Xone\r\ntwo\r\n" else [
        "saved %r, expected b'Xone\\r\\ntwo\\r\\n' - the file's CRLF "
        "convention was not kept" % got]


def check_region_highlight():
    """The active region is drawn with Emacs's `region' face - visibly.

    Two terminals, two branches of the spec.  An 8-colour xterm takes
    the `(min-colors 8)' branch, white on blue.  A 256-colour xterm that
    reports a dark background takes `(background dark)': `blue3' with no
    foreground - the text keeps the terminal's own foreground, and the
    background is colour 20, the nearest of xterm's 256 to blue3.  That
    second case is the one that came out black on black: with no
    foreground the pair was made with -1, which ncurses refuses until
    `use-default-colors' has been called.
    """
    path = "/tmp/pty-check-region.txt"
    with open(path, "w") as port:
        port.write("visible-region-text\n")
    keys = [C_a, b"\x00", C_f, C_f, C_f, C_f, C_f]
    problems = []
    out = drive(keys, path, term="xterm")
    if "\x1b[37m\x1b[44mvisib" not in out:
        problems.append("8 colours: the region is not white on blue")
    out = drive(keys, path, term="xterm-256color")
    if "\x1b[48;5;20mvisib" not in out:
        problems.append("256 colours, dark background: the region is not on "
                        "blue3 (colour 20)")
    if "\x1b[30m\x1b[40mvisib" in out or "\x1b[38;5;0m" in out:
        problems.append("256 colours: the region text is drawn in black")
    return problems


def check_continuation():
    """A line wider than the window CONTINUES on the row below.

    `truncate-lines' is nil by default, so Emacs wraps: the row ends with
    `\' - its continuation glyph - and the rest of the line is on the
    next screen row, moving the following buffer lines down. Cutting the
    line off instead is the *other* thing, `truncate-lines' being on, and
    its glyph is `$' (`produce_special_glyphs', xdisp.c:33200 and :33287).

    The marker alone cannot tell the two apart - a truncated 100-column
    line and a wrapped one both show 79 `X' and a `\' - so what this
    checks is the row *below*, which is where they differ. That is
    exactly how this was wrong: the marker was right and the rest of the
    line was missing.
    """
    path = "/tmp/pty-check-continuation.txt"
    with open(path, "w") as port:
        port.write("X" * 100 + "\nSECOND\n")
    rows = screen_of(drive([], path)).split("\n")
    problems = []
    if not rows or rows[0][79:80] != "\\":
        problems.append("a wrapped line did not end with \\ in its last "
                        "cell: %r" % (rows[0][70:80] if rows else None))
    if len(rows) < 2 or rows[1][:21] != "X" * 21:
        problems.append("the rest of the wrapped line is not on the row "
                        "below: %r" % (rows[1][:30] if len(rows) > 1 else None))
    if len(rows) < 3 or "SECOND" not in rows[2]:
        problems.append("the next buffer line did not follow the wrapped "
                        "one: %r" % (rows[2][:30] if len(rows) > 2 else None))
    return problems


def check_mode_line_eol():
    """A visited CRLF file reports its DOS convention in the mode line."""
    path = "/tmp/pty-check-mode-line-dos.txt"
    with open(path, "wb") as port:
        port.write(b"one\r\ntwo\r\n")
    screen = screen_of(drive([], path))
    if "(DOS)" not in screen:
        return ["a CRLF buffer's mode line did not show (DOS)"]
    return []


def check_wide_columns():
    """A wide character takes two columns, and the mode line says so.

    A CJK character is one character and two screen columns.  The editor
    draws the text correctly either way - the terminal knows the real
    width - so the visible symptom of counting characters instead of
    columns is a *position* being wrong, and the mode line's column
    indicator (`%c', Emacs's `(current-column)') is the one that is
    readable as text.

    Point is put after the wide character (two C-f), so the screen column
    is 3: `x' is one cell and the wide character is two.  Counting
    characters would say 2.  The same line is checked at the start, where
    both answers are 0, so that a mode line which never reported a column
    at all could not pass.
    """
    path = "/tmp/pty-check-wide.txt"
    with open(path, "w") as port:
        port.write("x中y|Z\n")
    problems = []
    screen = screen_of(drive([], path))
    if "L1 C0" not in screen:
        problems.append("the mode line did not start at column 0: %s"
                        % [row for row in screen.split("\n") if "L1" in row])
    screen = screen_of(drive([C_f, C_f], path))
    if "L1 C3" not in screen:
        problems.append("after a wide character the column is not 3 "
                        "(one cell for x, two for the CJK character): %s"
                        % [row for row in screen.split("\n") if "L1" in row])
    return problems


def check_m_x():
    """M-x reads a command name, completes it, and runs it.

    `execute-extended-command' (M-x) completes the name against the
    command obarray - the list of `defcommand' commands - and runs it
    as a key would.  Here a name with no completion match is typed
    whole and RET runs it (the message is observable), and a prefix
    completes to the command.
    """
    path = "/tmp/pty-check-mx.txt"
    open(path, "w").write("hello\n")
    problems = []
    out = drive([b"\x1b", b"x", b"read-only-mode", b"\r"], path,
                settle=2.5, gap=0.35)
    if "Read-Only mode enabled in current buffer" not in out:
        problems.append("M-x read-only-mode did not run the command "
                        "(no enabled message)")
    out = drive([b"\x1b", b"x", b"read-on", b"\t"], path, settle=2.5, gap=0.35)
    # The escapes are stripped before looking for the completed name: the
    # prompt is drawn in GNU Emacs's `minibuffer-prompt' face, so the
    # terminal stream carries attribute sequences between `M-x ' and the
    # name that was completed into it. Reading the bytes between them
    # finds an escape sequence and no name at all.
    import re as _re
    plain = _re.sub(r"\x1b\[[0-9;?]*[A-Za-z]|\x1b\(B|\x1b.", "", out)
    if "M-x read-only-mode" not in plain:
        problems.append("M-x completion: `read-on' TAB did not complete to "
                        "`read-only-mode'")
    return problems


def check_isearch_highlight():
    """Search and check the matches are drawn with something.

    GNU Emacs highlights what a search found - the `isearch' face on the
    match point is on, `lazy-highlight' on the others - so a screen whose
    attributes are the same during a search as without one means the
    renderer is not being told what to draw.  That is the check on the
    whole chain: the search commands publish `*search-highlight*', the
    display turns the position into a face, `merge-face_vectors' resolves
    it, `realize_tty_face' folds it down and a colour pair is made.

    Asserting *which* attributes is deliberately not done here: on this
    terminal the `isearch' face is cyan on magenta, but that comes from
    Emacs's own spec, the number of colours the terminal reports and the
    nearest-colour approximation, and a test that pinned the escape
    sequence would break when any of those changed rather than when
    something was wrong.  What is asserted is the part that must hold
    whatever the palette: a search draws something no other screen does.
    """
    path = "/tmp/pty-check-isearch.txt"
    open(path, "w").write("alpha beta alpha gamma alpha\n")
    # the *text* row's attributes, not the whole screen's: the echo area
    # carries the search prompt, so a screen-wide set differs for any
    # search at all and would call the prompt a highlight.
    searched = row_attrs(drive([C_s, b"alpha"], path), 0)
    plain = row_attrs(drive([], path), 0)
    if not (searched - plain):
        return ["a search draws the same text attributes as no search at all: "
                "matches are not being drawn (is *search-highlight* set, and "
                "does the face reach the renderer?)"]
    return []


def check_isearch_multiline():
    """A match with a line break in it is highlighted.

    `C-j` is `isearch-printing-char` for a newline, so `C-s alpha C-j beta`
    searches for "alpha\\nbeta" and `search-forward` crosses the line break
    to find it. Emacs makes *one* overlay from the match's start to its
    end, so both halves are highlighted.

    This port could not do that while the renderer searched each drawn row
    for the pattern: a row's text has no line break in it, so a match
    spanning one was never found and nothing was drawn for it - point
    moved, the colour did not. The highlight is an overlay now, made from
    the match the search reported, and the break is inside it.
    """
    path = "/tmp/pty-check-isearch-multiline.txt"
    open(path, "w").write("alpha\nbeta\ngamma\n")
    # row 0 is the "alpha" half of the match; row 1 is "beta". Both must
    # carry a face the plain screen does not.
    searched = drive([C_s, b"alpha", b"\n", b"beta"], path, settle=2.0, gap=0.35)
    plain = drive([], path)
    if not ((row_attrs(searched, 0) - row_attrs(plain, 0))
            and (row_attrs(searched, 1) - row_attrs(plain, 1))):
        return ["a search for a string with a line break in it draws no "
                "match: `alpha\\nbeta' spans two rows and its highlight has "
                "to be one overlay over both"]
    return []


def check_isearch_scroll():
    """Scrolling an isearch keeps the current match's face distinct.

    The renderer anchors each row's buffer position at the line point is
    on; it used to anchor at the window's *top* row, which is the same
    thing only while nothing has scrolled.  After a page, the current
    match's absolute position never fell inside its own row's
    window-relative range, so the match at point lost its `isearch' face
    and came out in the others' `lazy-highlight' instead: the cursor
    still moved (the search itself was fine), the colour stopped.  The
    check applies regardless of the palette, like `isearch-highlight':
    however deep the search has scrolled, some draw of the match text
    must carry a face attribute different from the others'.
    """
    import re as _re
    path = "/tmp/pty-check-isearch-scroll.txt"
    open(path, "w").write("\n".join("line %02d alpha" % i
                                    for i in range(1, 42)) + "\n")
    # A settle of a second is not enough for the editor to have opened the
    # file and be reading keys: the C-s goes to a program that is not
    # listening yet, no search starts at all, and the check then reports
    # the match as unhighlighted when nothing ever searched for it.
    out = drive([C_s, b"alpha"] + [C_s] * 39, path, settle=2.0, gap=0.25)
    tail = out.rsplit("\x1b[2J", 1)[-1]
    # the face attributes active when the search string's text came out:
    # the echo-area prompt "ISearch: alpha" is drawn with no attribute,
    # so the (non-empty) attributes here are the matches' faces only.
    alpha_sgrs = set()
    sgr = set()
    for chunk in _re.split(r"(\x1b\[[0-9;]*[A-Za-z]|\x1b\(B|\r|\n)", tail):
        if not chunk or chunk in ("\r", "\n"):
            continue
        if chunk.startswith("\x1b["):
            mm = _re.match(r"\x1b\[([0-9;]*)([A-Za-z])", chunk)
            if mm.group(2) == "m":
                sgr = set(mm.group(1).split(";"))
            continue
        if "alpha" in chunk and sgr:
            alpha_sgrs.add(tuple(sorted(sgr)))
    if len(alpha_sgrs) < 2:
        return ["after scrolling, every draw of the match text carries the "
                "same attribute (%r) - the current match has lost its "
                "`isearch' face" % (sorted(alpha_sgrs),)]
    return []


def check_isearch_highlight_row():
    """A match is highlighted on its own row, not on the window's first.

    `highlight-matches' is handed a row *within the window* and adds
    `window-top' to it itself, but the callers passed the slice index of
    the row within its own buffer line - so every line's matches were
    drawn on the window's top row.  Two things went wrong at once, and
    the check is on both: the highlight landed on a row whose text is
    something else (`inappropriate places'), and it was written *over*
    that row, so the window's first line stopped reading as the file
    does.  The second line's own match lost its face entirely, since the
    first line had nothing there to mark.
    """
    import re as _re
    path = "/tmp/pty-check-isearch-row.txt"
    open(path, "w").write("xxx apple yyy apple zzz\nsecond apple line here\n")
    out = drive([C_s, b"apple"], path, settle=2.0)
    problems = []
    tail = out.rsplit("\x1b[2J", 1)[-1]
    # The first line must still read as the file has it. The escapes are
    # stripped first, since the matches' faces sit inside the row: drawn
    # over by another line's match the row reads `xxx appappley apple
    # zzz', and this substring is then not there.
    plain = _re.sub(r"\x1b\[[0-9;?]*[A-Za-z]|\x1b\(B|\x1b.", "", tail)
    if "xxx apple yyy apple zzz" not in plain:
        problems.append("the window's first line is not drawn as the file "
                        "has it - a match from another line was written "
                        "over it")
    # The second line's match must carry a face of its own.
    sgr = set()
    second_marked = False
    for chunk in _re.split(r"(\x1b\[[0-9;]*[A-Za-z]|\x1b\(B|\r|\n)", tail):
        if not chunk or chunk in ("\r", "\n"):
            continue
        if chunk.startswith("\x1b["):
            mm = _re.match(r"\x1b\[([0-9;]*)([A-Za-z])", chunk)
            if mm.group(2) == "m":
                sgr = set(x for x in mm.group(1).split(";") if x)
            continue
        if "second" in chunk:
            second_marked = None          # this row's match is still ahead
        elif second_marked is None and "apple" in chunk:
            second_marked = bool(sgr)
    if not second_marked:
        problems.append("the match on the window's second line carries no "
                        "face - it was drawn on the first line instead")
    return problems


def check_isearch_quit():
    """A control key isearch does not use ends the search and runs.

    `C-s C-s C-x C-c' must quit the editor: GNU Emacs's isearch exits on
    a control character it has no use for (`isearch-other-control-char'
    does `isearch-exit', then the key runs as a command).  It used to
    eat the `C-x' - the search ended, the editorial's rule being to drop
    the key - and the following `C-c' came out as an undefined key.
    """
    path = "/tmp/pty-check-isearch-quit.txt"
    open(path, "w").write("alpha alpha\n")
    screen, exited = drive([C_s, C_s, C_x + C_c], path, report_exit=True)
    if not exited:
        return ["after C-s C-s C-x C-c the editor is still running (the "
                "search ate the C-x)"]
    if "undefined key" in screen:
        return ["C-x C-c after isearch reported an undefined key"]
    return []


def screen_of(out, width=80):
    """The newest full repaint, as plain text with the rows on separate lines.

    The renderer forces a complete repaint (`clearok!'), so the text after
    the last erase is the current screen. This is an approximation of a
    terminal rather than an emulator - it reads the cursor-addressing and
    erase sequences the editor actually emits and ignores the rest - which
    is enough for "is this text on the screen", and is honest about being
    no more than that.

    The addressing has to include the *relative* moves (`ESC [ n B` and
    friends), because ncurses emits those whenever it can - a row drawn
    just below the last one is a `ESC [ B`, not an absolute address - and
    a reader that only understood absolute addressing would drift a row and
    lose the mode line.
    """
    import re
    tail = out.rsplit("\x1b[2J", 1)[-1]
    rows, row, col = {}, 0, 0
    for chunk in re.split(r"(\x1b\[[0-9;]*[A-Za-z]|\x1b\(B|\r|\n)", tail):
        if not chunk or chunk in ("\r", "\n"):
            continue
        if chunk.startswith("\x1b"):
            m = re.match(r"\x1b\[([0-9;]*)([A-Za-z])", chunk)
            if not m:
                continue
            nums = [int(x) for x in m.group(1).split(";") if x.isdigit()]
            cmd, n = m.group(2), (nums[0] if nums else 1)
            if cmd in "Hd":
                row = (nums[0] if nums else 1) - 1
                col = (nums[1] if len(nums) > 1 else 1) - 1
            elif cmd == "A":
                row -= n
            elif cmd == "B":
                row += n
            elif cmd == "C":
                col += n
            elif cmd == "D":
                col -= n
            elif cmd == "K":
                # erase to the end of the line
                for c in [c for c in rows.get(row, {}) if c >= col]:
                    del rows[row][c]
            elif cmd == "J":
                rows = {}
            continue
        for ch in chunk:
            rows.setdefault(row, {})[col] = ch
            col += 1
    if not rows:
        return ""
    return "\n".join(
        "".join(rows.get(r, {}).get(c, " ") for c in range(width))
        for r in range(max(rows) + 1))


def row_attrs(out, want_row=0):
    """The attributes in effect on one row of the newest repaint.

    `screen_of' throws the attributes away, and the whole screen's set of
    them is too coarse for "is this match highlighted": the echo area
    carries the search prompt, so *any* search adds an escape somewhere and
    a screen-wide comparison would call that a highlight. This keeps the
    attributes that belong to one row - the text row, for a search - by
    walking the same cursor addressing `screen_of' does.

    What is *in effect* and not what was *emitted*: a terminal keeps its
    drawing state across rows, so a face that covers two rows is set once,
    on the first, and the second inherits it with no escape of its own.
    That is exactly the case a match with a line break in it makes, and a
    reader of escapes-sent would call the second row unhighlighted.
    """
    import re
    tail = out.rsplit("\x1b[2J", 1)[-1]
    active, row, col = frozenset(), 0, 0
    row_active = {}
    for chunk in re.split(r"(\x1b\[[0-9;]*[A-Za-z]|\x1b\(B|\r|\n)", tail):
        if not chunk or chunk in ("\r", "\n"):
            continue
        if chunk.startswith("\x1b"):
            m = re.match(r"\x1b\[([0-9;]*)([A-Za-z])", chunk)
            if not m:
                continue
            nums = [int(x) for x in m.group(1).split(";") if x.isdigit()]
            cmd, n = m.group(2), (nums[0] if nums else 1)
            if cmd in "Hd":
                row = (nums[0] if nums else 1) - 1
                col = (nums[1] if len(nums) > 1 else 1) - 1
            elif cmd == "A":
                row -= n
            elif cmd == "B":
                row += n
            elif cmd == "C":
                col += n
            elif cmd == "D":
                col -= n
            elif cmd == "m":
                # `ESC [ m' is `ESC [ 0 m': everything off
                active = (frozenset() if not nums or 0 in nums
                          else active | {chunk})
            continue
        col += len(chunk)
        row_active[row] = active
    return row_active.get(want_row, frozenset())


def check_completions():
    """`?' in a completing minibuffer opens a *Completions* window.

    GNU Emacs lists the candidates in a `*Completions*' buffer shown in
    another window. Two things are asserted and the second is the one that
    matters: the window appears with the candidates in it, *and* what was
    typed is still in the prompt afterwards - showing a window while the
    minibuffer is being read must not take point out of it, which is why
    this is `display-buffer' and not `pop-to-buffer'.
    """
    directory = "/tmp/pty-check-completions"
    os.makedirs(directory, exist_ok=True)
    for name in ("alpha.txt", "beta.txt"):
        open(os.path.join(directory, name), "w").write("x\n")
    path = os.path.join(directory, "alpha.txt")
    typed = directory + "/"
    screen = screen_of(drive([C_x + C_f, C_a, C_k, typed.encode(), b"?"],
                             path))
    problems = []
    # A second mode line is a second window: that is how the check knows the
    # completions window opened rather than the candidates going somewhere
    # else. (The buffer's name is in that mode line as `*Completions*' -
    # the format's `%12b' is a floor, not a ceiling: a longer name shows
    # in full, as a terminal Emacs 31 confirms.)
    mode_lines = [r for r in screen.split("\n") if "--" in r and " L" in r]
    if len(mode_lines) != 2:
        problems.append("after `?' there are %d windows, expected 2"
                        % len(mode_lines))
    for name in ("alpha.txt", "beta.txt"):
        if name not in screen:
            problems.append("the candidate %s is not listed" % name)
    # The list shows the *names*, as Emacs's does - the directory is in
    # the prompt already. Only the prompt line may carry it.
    rows_with_dir = [r for r in screen.split("\n")
                     if directory in r and "Find file:" not in r]
    if rows_with_dir:
        problems.append("the candidates are listed with their directory: %r"
                        % rows_with_dir[0].strip())
    if ("Find file: " + typed) not in screen:
        problems.append("the prompt no longer has what was typed, so point "
                        "left the minibuffer")
    # ...and choosing one puts the directory back: M-<down> onto the first
    # candidate, then RET, visits it - the file's text is on the screen.
    screen = screen_of(drive([C_x + C_f, C_a, C_k, typed.encode(), b"?",
                              M_DOWN, RET], path))
    if "x" not in screen.split("\n")[0]:
        problems.append("choosing a listed name did not visit the file in "
                        "the prompt's directory")

    # TAB, in the same minibuffer but with the prompt cleared: the text is
    # completed as far as it can be. The candidate is picked for being the
    # only thing starting with "alp", so a *sole* completion is what is
    # being asked for - which is the branch a `?` never reaches.
    screen = screen_of(drive([C_x + C_f, C_a, C_k, b"alp", b"\t"], path))
    if "Find file: alpha.txt" not in screen:
        problems.append("TAB did not complete the name: expected the prompt "
                        "to hold `alpha.txt'")
    return problems


def check_quit_after_completion():
    """A completing `C-x C-f` followed by `C-x C-c` quits without asking.

    Real Emacs asks to save the buffers that are worth saving - the
    modified ones that visit a file (`save-some-buffers' iterating
    `files--buffers-needing-to-be-saved').  The minibuffer's own buffer
    and `*Completions*' are modified and visit nothing, so after `C-x C-f`
    with the completions window up, `C-x C-c` must go straight out - not
    ask whether to save the help buffer, as it did when save-some-buffers
    asked about whatever buffer happened to be current.
    """
    directory = "/tmp/pty-check-quit-completions"
    os.makedirs(directory, exist_ok=True)
    for name in ("alpha.txt", "beta.txt"):
        open(os.path.join(directory, name), "w").write("x\n")
    path = os.path.join(directory, "alpha.txt")
    screen, exited = drive([C_x + C_f, (directory.rstrip("/") + "/").encode(),
                            b"?", C_x + C_c],
                           path, report_exit=True)
    problems = []
    if not exited:
        problems.append("C-x C-c after completing did not quit the editor")
    for bad in ("Save buffer", "Save file", "exit anyway"):
        if bad in screen:
            problems.append("quitting after completing asked about saving "
                            "(%s)" % bad)
    return problems


def check_completion_tab_tab():
    """TAB TAB with nothing typed after the directory brings up the list.

    GNU Emacs: `C-x C-f` TAB on the bare directory says "Complete, but
    not unique" - the directory is already a valid completion - and a
    second TAB says it again *and* opens the completions list.
    `completion--do-completion' knows the key was pressed twice by
    comparing `this-command' and `last-command' in its exact-match
    branch.  Here the first TAB must not open the window, and the second
    must.
    """
    directory = "/tmp/pty-check-completion-tab-tab"
    os.makedirs(directory, exist_ok=True)
    for name in ("alpha.txt", "beta.txt"):
        open(os.path.join(directory, name), "w").write("x\n")
    path = os.path.join(directory, "alpha.txt")

    def mode_lines(screen):
        return [r for r in screen.split("\n") if "--" in r and " L" in r]

    # First TAB: the directory is already a valid completion, so the
    # message appears and no window opens.
    screen = screen_of(drive([C_x + C_f, b"\t"], path))
    if "Complete, but not unique" not in screen:
        problems = ["first TAB did not say Complete, but not unique"]
        return problems
    if len(mode_lines(screen)) != 1:
        problems1 = ["first TAB opened the completions window (%d mode "
                     "lines)" % len(mode_lines(screen))]
    else:
        problems1 = []

    # Second TAB: the same key as the previous command, so the list comes
    # up beside the message.
    screen = screen_of(drive([C_x + C_f, b"\t", b"\t"], path))
    problems = problems1[:]
    if len(mode_lines(screen)) != 2:
        problems.append("second TAB did not open the completions window "
                        "(%d mode lines)" % len(mode_lines(screen)))
    for name in ("alpha.txt", "beta.txt"):
        if name not in screen:
            problems.append("the candidate %s is not listed" % name)
    if "Complete, but not unique" not in screen:
        problems.append("second TAB lost the Complete, but not unique "
                        "message")
    return problems


def check_completion_columns():
    """Ask for the completion list and get it in *columns*.

    GNU Emacs sizes the completions window's layout to the window:
    `completion--insert-strings' fits as many `LENGTH + 2' columns into
    the width as it can (halved against the candidate count so no column
    has fewer than two candidates), and `completion--insert-horizontal'
    writes the candidates into them row by row.  Here eight six-character
    names in an 80-column window make four columns and two rows, so a
    row of the list carries four names where the old one-per-line layout
    carried one.
    """
    directory = "/tmp/pty-check-completion-columns"
    os.makedirs(directory, exist_ok=True)
    names = ["a%d.txt" % i for i in range(1, 9)]
    for name in names:
        open(os.path.join(directory, name), "w").write("x\n")
    path = os.path.join(directory, "a1.txt")
    screen = screen_of(drive([C_x + C_f, C_a, C_k,
                              (directory.rstrip("/") + "/").encode(),
                              b"?"],
                             path))
    problems = []
    # Rows of the list, not the mode lines above them (the file window's
    # mode line carries its own buffer name, which is one of the names).
    counts = [sum(1 for n in names if n in r)
              for r in screen.split("\n")
              if "Find file:" not in r and "--" not in r]
    counts = [c for c in counts if c]
    if not counts:
        problems.append("no candidate rows at all")
    if counts and max(counts) < 2:
        problems.append("no row carries two or more candidates: the list "
                        "is still one column (rows hold %s per row)"
                        % counts)
    if counts and len(counts) >= len(names):
        problems.append("%d rows for %d candidates - every row holds one, "
                        "which is the one-per-line layout"
                        % (len(counts), len(names)))
    return problems


def check_completion_window():
    """The list gets a *fresh* window and that window is sized to fit.

    GNU Emacs's `minibuffer-completion-help' displays *Completions*
    with `display-buffer-below-selected' in place of
    `display-buffer-use-some-window', and `completions--fit-window-to-buffer'
    as its `window-height': the list appears in a new window - never in
    an unrelated one, so a frame that already has two windows grows a
    third and lets it go again when the minibuffer is done - and that
    window is exactly as tall as the list needs (its content plus the
    mode line), not an even share of the frame.
    """
    directory = "/tmp/pty-check-completion-window"
    os.makedirs(directory, exist_ok=True)
    for name in ("a1.txt", "a2.txt"):
        open(os.path.join(directory, name), "w").write("x\n")
    path = os.path.join(directory, "a1.txt")
    typed = directory + "/"
    mode = lambda s: [r for r in s.split("\n") if "--" in r and " L" in r]
    problems = []

    # Fitted height: the list's whole content (two help lines, a blank,
    # the heading, the two candidates) is six text lines, so the
    # completions window is seven rows - not the twelve an even split
    # of a 24-row frame gives it.
    screen = screen_of(drive([C_x + C_f, C_a, C_k, typed.encode(), b"?"], path))
    ml = mode(screen)
    if len(ml) != 2:
        problems.append("no completions window (mode lines: %d)" % len(ml))
    else:
        rows = screen.split("\n")
        gap = rows.index(ml[1]) - rows.index(ml[0]) - 1
        if gap != 6:
            problems.append("completions window is %d text rows, expected 6 "
                            "- it should be fitted to the list, not given "
                            "an even share of the frame" % gap)

    # A fresh window: a frame that already has two windows grows a third
    # for the list rather than taking the second one, and the second one
    # still shows the file.
    screen = screen_of(drive([C_x + b"2", C_x + C_f, C_a, C_k, typed.encode(),
                              b"?"], path))
    ml = mode(screen)
    if len(ml) != 3:
        problems.append("with two windows the list did not get a third of "
                        "its own (mode lines: %d)" % len(ml))
    # two of the three mode lines name the file (the frame's two windows
    # that still show it), and the third names the list
    if sum(1 for r in ml if "a1.txt" in r) != 2:
        problems.append("the list replaced what one of the windows showed "
                        "- the second window should still hold the file")
    if sum(1 for r in ml if "Completions" in r) != 1:
        problems.append("no mode line names the list")

    # C-g takes the list's window away again, leaving the two it started with.
    screen = screen_of(drive([C_x + b"2", C_x + C_f, C_a, C_k, typed.encode(),
                              b"?", C_g], path))
    ml = mode(screen)
    if len(ml) != 2:
        problems.append("C-g left the list's window behind (%d mode lines, "
                        "expected 2)" % len(ml))

    # Full width in a side-by-side frame: with C-x 3 the two windows are
    # left and right, and the list still gets a full-width window of its
    # own at the bottom - the pair of windows above keep their `|'
    # border, but no candidate row carries one.
    screen = screen_of(drive([C_x + b"3", C_x + C_f, C_a, C_k, typed.encode(),
                              b"?"], path))
    rows = screen.split("\n")
    cand = [r for r in rows if ("a1.txt" in r or "a2.txt" in r)
            and "--" not in r and "Find" not in r]
    if not cand:
        problems.append("no list in the side-by-side frame")
    elif any("|" in r for r in cand):
        problems.append("the list is split into one of the halves: a "
                        "candidate row carries the vertical border, so the "
                        "window is not full width at the bottom")
    if not any("|" in r for r in rows if "--" in r and " L" in r):
        problems.append("the side-by-side windows above lost their border")
    return problems


def check_completion_width():
    """The column count tracks the terminal width.

    The layout is the *algorithm*, read from the window it is going into
    on every fill (`completion--insert-strings' measures it) - not a
    fixed result, and not a hard-coded three columns.  The same twelve
    twenty-character names make three columns in an 80-column frame and
    six in one 160 columns wide.
    """
    directory = "/tmp/pty-check-completion-width"
    os.makedirs(directory, exist_ok=True)
    names = [("a" * 18) + ("%02d" % i) for i in range(1, 13)]
    for name in names:
        open(os.path.join(directory, name), "w").write("x\n")
    path = os.path.join(directory, names[0])
    typed = directory + "/"

    def first_row(keys, width):
        screen = screen_of(drive(keys, path, settle=1.5), width=width)
        for r in screen.split("\n"):
            if "--" not in r and ":" not in r and "Find" not in r:
                n = sum(1 for x in names if x in r)
                if n:
                    return n
        return 0

    problems = []
    w80 = first_row([C_x + C_f, C_a, C_k, typed.encode(), b"?"], 80)
    w160 = first_row([("resize", 24, 160), C_x + C_f, C_a, C_k,
                      typed.encode(), b"?"], 160)
    if w80 != 3:
        problems.append("an 80-column terminal shows %d of the twelve "
                        "candidates per row, expected 3" % w80)
    if w160 != 6:
        problems.append("a 160-column terminal shows %d of the twelve "
                        "candidates per row, expected 6 - the column count "
                        "did not grow with the terminal" % w160)
    return problems


def check_completion_resize():
    """Resizing while the list is up leaves the frame in working order.

    GNU Emacs re-tiles the frame's windows to the new size and every
    window keeps the rectangle that re-tile gives it - an internal
    window left with the size it was made with made `C-g' reclaim the
    list's space into the *wrong* window after a resize, shoving the
    window above off the top of the screen (and shrinking the terminal
    past it crashed).  After this fix the list is the bottom-most window
    again after a resize + C-g + resize cycle, and shrinking the
    terminal while the list is up is harmless.
    """
    directory = "/tmp/pty-check-completion-resize"
    os.makedirs(directory, exist_ok=True)
    for i in range(1, 9):
        open(os.path.join(directory, "a%d.txt" % i), "w").write("x\n")
    path = os.path.join(directory, "a1.txt")
    typed = directory + "/"
    mode = lambda s: [r for r in s.split("\n") if "--" in r and " L" in r]
    problems = []

    # Two windows, the list up, the terminal grown, C-g, and the list
    # again: it must be the bottom-most window on a frame whose two
    # file windows fill everything above it.
    screen = screen_of(drive([C_x + b"2", C_x + C_f, C_a, C_k, typed.encode(),
                              b"?", ("resize", 40, 160), C_g,
                              C_x + C_f, C_a, C_k, typed.encode(), b"?"],
                             path, settle=1.5))
    rows = screen.split("\n")
    ml = mode(screen)
    if len(ml) != 3:
        problems.append("after resize + C-g + re-entry there are %d mode "
                        "lines, expected 3 (the C-g did not reclaim the "
                        "space, or the list is gone)" % len(ml))
    else:
        order = [i for i, r in enumerate(rows) if "--" in r and " L" in r]
        if not (order[0] < order[1] < order[2]):
            problems.append("the windows are not stacked top to bottom")
        if "Completions" not in ml[2]:
            problems.append("the list is not the bottom window")
        if order[2] != len(rows) - 2:
            problems.append("the list's mode line is not immediately above "
                            "the prompt - space was not reclaimed on C-g")

    # The crash (reported with exactly these keys): start big, open the
    # list with TAB TAB, and shrink the terminal while it is up.
    screen = screen_of(drive([("resize", 60, 240), C_x + C_f, b"\t", b"\t",
                              ("resize", 22, 90)], path, settle=1.6))
    rows = screen.split("\n")
    ml = mode(screen)
    if len(ml) != 2:
        problems.append("shrinking the terminal under the list lost a "
                        "window (mode lines: %d)" % len(ml))
    else:
        if "Completions" not in ml[1]:
            problems.append("after the shrink the list is not the bottom "
                            "window")
        if rows.index(ml[1]) != len(rows) - 2:
            problems.append("the list's mode line is not above the prompt "
                            "after the shrink")
    return problems


def check_completion_ui():
    """The parts of completion that are about how it looks and what keys do.

    Four things GNU Emacs does that are easy to miss because none of them
    changes what a function returns:

      * a message shown while the minibuffer is being read is enclosed in
        `[...]' with a space in front (`minibuffer-message');
      * it goes away on its own after `minibuffer-message-timeout';
      * C-g closes the completions window as well as the minibuffer, and so
        does leaving the minibuffer any other way (`minibuffer-exit-hook');
      * `M-<down>' moves through the candidates and RET then takes the one
        it moved to.

    Each of these was driven and seen to fail before it was made to pass.
    """
    directory = "/tmp/pty-check-completion-ui"
    os.makedirs(directory, exist_ok=True)
    for name in ("apple.txt", "apricot.txt"):
        open(os.path.join(directory, name), "w").write("FRUIT\n")
    path = os.path.join(directory, "apple.txt")
    problems = []
    find = [C_x + C_f, C_a, C_k]

    # A message is bracketed, and it is still there a moment later - while
    # the minibuffer is being read, which is when it is a
    # `minibuffer-message' rather than a plain echo-area message.
    screen = screen_of(drive(find + [b"zz", b"\t"], path, settle=1.5))
    if "Find file: zz [No match]" not in screen:
        problems.append("the no-match message is not ` [No match]' after the "
                        "prompt, so it is not going through "
                        "`minibuffer-message'")

    # ...and gone once `minibuffer-message-timeout' (two seconds) has
    # passed with nothing typed. The gap after the last key is what waits.
    screen = screen_of(drive(find + [b"zz", b"\t"], path, gap=3.0))
    if "[No match]" in screen:
        problems.append("the message is still there three seconds later, so "
                        "it does not time out")

    # The completions window is open before C-g is pressed: without this
    # the two checks below would pass on a window that never opened.
    screen = screen_of(drive(find + [b"ap", b"\t"], path))
    mode_lines = [r for r in screen.split("\n") if "--" in r and " L" in r]
    if len(mode_lines) != 2:
        problems.append("TAB did not open a completions window at all: %d "
                        "windows, expected 2" % len(mode_lines))

    # C-g leaves the minibuffer *and* takes the completions window with it.
    screen = screen_of(drive(find + [b"ap", b"\t", C_g], path))
    mode_lines = [r for r in screen.split("\n") if "--" in r and " L" in r]
    if len(mode_lines) != 1:
        problems.append("after C-g there are %d windows, expected 1: the "
                        "completions window outlived the minibuffer"
                        % len(mode_lines))
    if "Find file:" in screen:
        problems.append("C-g left the minibuffer on the screen")

    # ...and so does leaving with RET, which is the same hook. RET on its
    # own leaves with *what was typed* - `ap' - because point starts on the
    # heading line rather than on a candidate; it is M-<down> that moves it
    # onto one. (So this RET makes a new file named `ap', which is what Emacs
    # does too.)
    screen = screen_of(drive(find + [b"ap", b"\t", RET], path))
    mode_lines = [r for r in screen.split("\n") if "--" in r and " L" in r]
    if len(mode_lines) != 1:
        problems.append("after RET there are %d windows, expected 1: the "
                        "completions window outlived the minibuffer"
                        % len(mode_lines))
    if "Find file:" in screen:
        problems.append("RET left the minibuffer on the screen")

    # M-<down> moves point onto a candidate - the first one, from the
    # heading line point starts on - and RET then takes it. A second
    # M-<down> takes the second candidate, and M-<up> comes back.
    def visited_a_file(keys):
        screen = screen_of(drive(find + keys, path))
        if "FRUIT" not in screen:
            return None
        lines = [r for r in screen.split("\n") if "--" in r and " L" in r]
        return lines[0].strip() if lines else None

    first = visited_a_file([b"ap", b"\t", M_DOWN, RET])
    second = visited_a_file([b"ap", b"\t", M_DOWN, M_DOWN, RET])
    back = visited_a_file([b"ap", b"\t", M_DOWN, M_DOWN, M_UP, RET])
    if first is None or second is None or back is None:
        problems.append("M-<down> then RET did not visit a candidate")
    elif first == second:
        problems.append("the second M-<down> did not move the selection: it "
                        "took the same candidate as the first")
    elif first != back:
        problems.append("M-<up> did not move the selection back")

    # A second TAB on a name that is already the only completion says
    # "Sole completion" - `try-completion' answers `t' there, and `t' is
    # the sole-completion case. It used to say "Complete, but not unique",
    # which is the *other* case: nothing completed, and what is there is a
    # valid completion among others.
    solo = "/tmp/pty-check-completion-ui/only"
    open(solo + ".txt", "w").write("SOLO\n")
    screen = screen_of(drive(find + [b"only", b"\t"], path))
    if "Find file: only.txt" not in screen:
        problems.append("TAB did not complete to the only match")
    screen = screen_of(drive(find + [b"only", b"\t", b"\t"], path))
    if "[Sole completion]" not in screen:
        problems.append("a second TAB on the only completion does not say "
                        "` Sole completion': a name that is already the one "
                        "completion is the sole-completion case")

    # Two TABs show the candidates; and the list carries the two lines that
    # say how to use it, which `completion-setup-function' writes at the top.
    screen = screen_of(drive(find + [b"ap", b"\t", b"\t"], path))
    if "Type M-<down> or M-<up> to move point between completions." not in screen:
        problems.append("the completions buffer has no help line saying how "
                        "to move between the candidates")
    if "2 possible completions:" not in screen:
        problems.append("the completions buffer has no heading line counting "
                        "the candidates")

    # SPC inserts a space in a file name rather than completing a word,
    # which is what `minibuffer-local-filename-completion-map' is for.
    spaced = os.path.join(directory, "two words.txt")
    open(spaced, "w").write("SPACED\n")
    screen = screen_of(drive(find + [spaced.encode(), RET], path))
    if "SPACED" not in screen:
        problems.append("a file name with a space in it cannot be typed: "
                        "SPC completed a word instead of inserting a space")
    return problems


def check_default_directory():
    """`C-x C-f' in a buffer visiting a file whose name was bare.

    The prompt holds the buffer's `default-directory', and a buffer's
    `default-directory' is the directory of the file it visits. A file
    named on the command line without a directory - `emacs build.scm' -
    used to give an *empty* directory, because the directory part of a
    bare name is the empty string, so the prompt read "Find file: " with
    nothing after it. GNU Emacs expands the name first thing in
    `find-file-noselect', and so does this now.
    """
    problems = []
    # a bare name, relative to the editor's directory: REPO/build.scm
    screen = screen_of(drive([C_x + C_f], "build.scm"))
    if "Find file: " not in screen:
        problems.append("no `Find file: ' prompt at all")
    else:
        shown = screen.split("Find file: ", 1)[1].split("\n")[0].strip()
        if not shown:
            problems.append("the prompt has no directory in it: a buffer "
                            "visiting a bare file name answered with an "
                            "empty `default-directory'")
        elif not shown.endswith("/"):
            problems.append("the prompt's directory is %r, which is not a "
                            "directory" % shown)

    # ...and the same for a file named with a directory in front of it. The
    # file it visits is a *small* fixture and not this script: the check is
    # about the prompt, and a large buffer takes longer to draw than the
    # harness waits (the renderer was quadratic in the buffer's length
    # before `buffer-text' and `region_cache' landed, and is not now, but
    # the fixture keeps this check independent of that)
    # and not about how fast a redraw is. Measured: this script, 3.3s to the
    # prompt; a small file, 0.3s.
    d = "/tmp/pty-check-dd"
    os.makedirs(d, exist_ok=True)
    open(os.path.join(d, "f.txt"), "w").write("hello\n")
    screen = screen_of(drive([C_x + C_f], os.path.join(d, "f.txt")))
    shown = screen.split("Find file: ", 1)[1].split("\n")[0].strip() if "Find file: " in screen else ""
    if not shown.endswith("pty-check-dd/"):
        problems.append("a file named with a directory in front of it "
                        "prompts with %r, expected its own directory" % shown)
    return problems


def check_what_cursor():
    """C-x = prints where point is, and the character it is on.

    Emacs's `what-cursor-position' answers in the echo area: the
    character, its code in decimal, octal and hex, the one-based point,
    the buffer size, the percentage through, and the column.
    """
    path = "/tmp/pty-check-wcp.txt"
    open(path, "w").write("hello world\n")
    problems = []
    # point at end of buffer: C-a, then twelve C-f's past every
    # character of "hello world\n" - the (EOB) message, whose point is
    # one past the last character, as Emacs's formula makes it
    out = drive([C_x + C_f, path.encode(), RET, C_a] + [C_f] * 12 +
                [C_x + b"="], path)
    if "point=13 of 12 (EOB) column=0" not in out:
        problems.append("C-x = at end of buffer did not report the EOB "
                        "message as Emacs's formula gives it")
    out = drive([C_x + C_f, path.encode(), RET, C_a, C_f, C_f, C_x + b"="],
                path)
    if "Char: l (108, #o154, #x6c) point=3 of 12 (17%) column=2" not in out:
        problems.append("C-x = on the second l did not report "
                        "`Char: l (108, #o154, #x6c) point=3 of 12 (17%) "
                        "column=2'")
    return problems


def check_goto_line():
    """M-g g reads a line number and point goes to its start.

    A numeric prefix argument IS the line (`C-u 3 M-g g'), and without
    one the line is read from the minibuffer, which offers the line
    point is on as the default - so bare RET goes to the line point is
    already on, and typing 3 goes to the start of the third line.
    """
    path = "/tmp/pty-check-goto.txt"
    open(path, "w").write("alpha\nbravo\ncharlie\n")
    problems = []
    C_u = b"\x15"
    # the prompt: M-g g, type 3, RET - point lands on the third line,
    # which the mode line's L3 says
    out = drive([C_x + C_f, path.encode(), RET,
                 b"\x1b", b"g", b"g", b"3", RET], path)
    screen = screen_of(out)
    mode = [r for r in screen.split("\n") if "-- L" in r]
    if not mode or "L3" not in mode[-1]:
        problems.append("M-g g 3 RET did not put point on the third line "
                        "(mode line: %r)" % (mode[-1][:40] if mode else None,))
    if "Mark set" not in out:
        problems.append("M-g g did not leave the mark where point was")
    # the prefix argument: C-u 2 M-g g - the line IS the argument
    out = drive([C_x + C_f, path.encode(), RET, C_u, b"2",
                 b"\x1b", b"g", b"g"], path)
    screen = screen_of(out)
    mode = [r for r in screen.split("\n") if "-- L" in r]
    if not mode or "L2" not in mode[-1]:
        problems.append("C-u 2 M-g g did not put point on the second line "
                        "(mode line: %r)" % (mode[-1][:40] if mode else None,))
    return problems


def check_write_file():
    """C-x C-w writes the buffer under a new name.

    The prompt is `Write file: ', the answer names the file, the buffer
    visits it from then on (the mode line says so), and the file is on
    disk with the buffer's text.
    """
    path = "/tmp/pty-check-wf-src.txt"
    open(path, "w").write("written by write-file\n")
    target = "/tmp/pty-check-wf-dst.txt"
    C_w = b"\x17"
    problems = []
    try:
        os.unlink(target)
    except OSError:
        pass
    # C-a C-k kills the directory the prompt starts with, the way the
    # other prompting checks do before they type an absolute path
    out = drive([C_x + C_f, path.encode(), RET,
                 C_x + C_w, C_a, C_k, target.encode(), RET], path)
    if "Wrote /tmp/pty-check-wf-dst.txt" not in out:
        problems.append("C-x C-w did not say `Wrote ...' for the new file")
    if not os.path.exists(target):
        problems.append("C-x C-w did not create the file it was given")
    else:
        with open(target) as port:
            if port.read() != "written by write-file\n":
                problems.append("the file C-x C-w wrote does not hold the "
                                "buffer's text")
    screen = screen_of(out)
    if "pty-check-wf-dst.txt" not in screen:
        problems.append("the mode line does not name the file the buffer "
                        "was written to")
    return problems


def check_recenter():
    """C-l puts the line point is on in the middle of the window.

    `recenter' sets the window's start to the line half a window above
    point's, which is what the redraw shows: on a 23-row window, the
    line point is on is row 11 (zero-based) after C-l.
    """
    lines = "".join("line %02d\n" % n for n in range(1, 41))
    path = "/tmp/pty-check-recenter.txt"
    C_l = b"\x0c"
    open(path, "w").write(lines)
    problems = []
    # to the last line, then C-l: point's line is centred
    out = drive([C_x + C_f, path.encode(), RET,
                 b"\x1b", b">", C_f, C_l], path)
    screen = screen_of(out)
    rows = screen.split("\n")
    # find the row that point is on - the cursor row - and check it is
    # around the middle: the mode line is the last row, the text rows
    # are 1..22, so the centre is row 11 or 12
    pointed = [n for n, r in enumerate(rows) if "line 40" in r]
    if not pointed:
        problems.append("after M-> C-l the line point is on is not on the "
                        "screen at all")
    elif not (8 <= pointed[0] <= 14):
        problems.append("after M-> C-l the line point is on is row %d of "
                        "the screen, expected around the middle (11)"
                        % pointed[0])
    return problems


def check_osc52():
    """The cut reaches the terminal as OSC 52, which is the clipboard.

    An xterm that reported version 370 - which this harness answers the
    Secondary Device Attributes query with - is one that Emacs 31 turns
    `xterm--set-selection' on for, so `kill-new' -> `gui-select-text'
    ends at the tty: `\\e]52;c;<base64>\\a' goes out and the terminal
    sets its own clipboard. What is *not* sent is a read query - the
    `xterm--get-selection' side is opt-in, because a terminal that does
    not answer it would make every `C-y' wait out the two-second
    timeout.
    """
    path = "/tmp/pty-check-osc52.txt"
    open(path, "w").write("hello world\n")
    problems = []
    C_SPC = b"\x00"
    C_w = b"\x17"
    out = drive([C_x + C_f, path.encode(), RET, C_a, C_SPC, C_f, C_f, C_w],
                path)
    want = b"\x1b]52;c;" + base64.b64encode(b"he") + b"\x07"
    if want not in out.encode("utf-8", "replace"):
        problems.append("C-w did not send the region as OSC 52 "
                        "(no \\e]52;c;aGU=\\a in the output)")
    if b"\x1b]52;c;?" in out.encode("utf-8", "replace"):
        problems.append("the editor queried the terminal for the selection "
                        "(\\e]52;c;?) - the read side is meant to be opt-in")
    return problems


def check_kill_ring():
    """The region commands and the kill ring, as a screen shows them.

    `C-SPC` sets the mark, motion makes a region, `C-w` cuts it and `C-y`
    puts it back; `M-w` copies instead, so the text stays; and `M-y` after
    a yank replaces what was yanked with the kill before it. The ring
    itself is unit-tested - what is here is that the keys reach it.
    """
    path = "/tmp/pty-check-kill.txt"
    open(path, "w").write("hello world\n")
    problems = []
    find = [C_x + C_f, C_a, C_k]
    C_SPC = b"\x00"
    C_w = b"\x17"
    C_y = b"\x19"
    M_w = b"\x1bw"
    M_y = b"\x1by"
    C_e = b"\x05"

    # C-SPC, two characters of motion, C-w: "he" is cut and C-y puts it
    # back where point is - which is the beginning, since killing the
    # region leaves point at its start.
    screen = screen_of(drive(find + [path.encode(), RET, C_SPC, C_f, C_f,
                                     C_w, C_y], path))
    if "hello world" not in screen:
        problems.append("C-SPC then motion then C-w then C-y did not leave "
                        "the line as it was")

    # M-w copies: the text stays, and the copy can be pasted later.
    screen = screen_of(drive(find + [path.encode(), RET, C_SPC, C_f, C_f,
                                     M_w, C_e, C_y], path))
    if "hello worldhe" not in screen:
        problems.append("M-w did not copy the region to the kill ring")

    # C-k kills the line and C-y brings it back.
    screen = screen_of(drive(find + [path.encode(), RET, C_k, C_y], path))
    if "hello world" not in screen:
        problems.append("C-k then C-y did not restore the line")

    # M-y after anything that is not a yank says so, in Emacs's words -
    # the older `yank-pop' behaviour, since Emacs 31's reads the ring in
    # the minibuffer.
    screen = screen_of(drive(find + [path.encode(), RET, C_k, M_y], path))
    if "Previous command was not a yank" not in screen:
        problems.append("M-y after a kill did not say the previous command "
                        "was not a yank")

    # The ring is a ring: C-y then a run of M-y goes round it, and the
    # older version here stopped after the first M-y with "Previous
    # command was not a yank" - because `yank-pop' had not said `yank'
    # was the command behind it.
    # M-y after a yank keeps going round the ring - `yank-pop' leaves
    # `yank' as the command behind it, so the next M-y still follows a
    # yank. Which entry a rotation lands on is arithmetic and is
    # unit-tested; what is driven here is the two-key sequence itself,
    # because a long key run is flaky through the pty in a way the
    # command loop is not.
    # Two M-y's, not one: the find-file prompt prefill is part of the
    # ring now - the C-k in the prompt killed the default directory -
    # and the first M-y correctly rotates to it ("/tmp/"), so reaching
    # the line kill is a second rotation, which is Emacs's ring doing
    # what it does.
    screen = screen_of(drive(find + [path.encode(), RET, C_k, C_y,
                                     M_y, M_y], path))
    if "Previous command was not a yank" in screen:
        problems.append("M-y was not seen as following a yank")
    if "hello world" not in screen:
        problems.append("M-y did not bring the text back")
    return problems


def check_split():
    """C-x 3 makes two windows side by side; C-x 0 puts one back.

    The window commands are geometry, and geometry is exactly what a unit
    test can check and a terminal can still get wrong - the mode line of a
    two-window frame is two mode lines on one row, and the vertical border
    between them belongs to the window on the left.
    """
    # a short name: the mode line pads the buffer name to 12 columns. A
    # longer one runs past the field (no truncation - the window edge is
    # what cuts it), which is why this counts a name that fits
    path = "/tmp/split.txt"
    open(path, "w").write("hello\n")
    name = "split"

    screen = screen_of(drive([C_x + b"3"], path))
    mode = [r for r in screen.split("\n") if name in r]
    problems = []
    if not mode:
        return ["the mode line is not on the screen at all"]
    if mode[-1].count(name) != 2:
        problems.append("after C-x 3 the mode-line row names the buffer %d "
                        "times, expected 2" % mode[-1].count(name))
    border = [r for r in screen.split("\n") if "|" in r]
    if len(border) < 10:
        problems.append("after C-x 3 there are %d rows with a vertical "
                        "border, expected the window's rows" % len(border))

    screen = screen_of(drive([C_x + b"3", C_x + b"0"], path))
    mode = [r for r in screen.split("\n") if name in r]
    if mode and mode[-1].count(name) != 1:
        problems.append("after C-x 0 the mode-line row names the buffer %d "
                        "times, expected 1" % mode[-1].count(name))
    return problems


def check_scroll():
    """Open a file longer than the screen and go to its end.

    The renderer scrolls a window by setting where its display starts
    (`set!window-top-line`), so this is the check on that call - and it is
    the one that would have found it missing from the display library's
    imports. Everything else about the renderer works on a file that fits
    on the screen, which is what every other check here uses; the editor
    scrolled by reporting an unbound variable in the echo area and leaving
    the buffer where it was.
    """
    path = "/tmp/scroll.txt"
    open(path, "w").write("".join("line %d\n" % i for i in range(1, 61)))
    screen = screen_of(drive([ESC, b">"], path))       # M-> : end-of-buffer
    if "line 60" not in screen:
        return ["the last line was not scrolled into view"]
    if "line 1\n" in screen or screen.strip().startswith("line 1"):
        return ["the view did not move: line 1 is still the first row"]
    return []


def check_resize():
    """Split the frame, then make the terminal wider, narrower and taller.

    The windows have to follow the frame: GNU Emacs re-tiles them from
    `change_frame_size' every time the frame's size changes. Without that
    a window keeps the rectangle it was made with, so the vertical border
    of a `C-x 3' split stays where it was and a shrunk terminal draws the
    mode lines off the bottom of the screen.

    The border column is counted from zero, as the screen is: an 80-column
    frame split in two puts the border in column 39, the left window's
    last column - the frame's vertical border belongs to the window on its
    left, which is why the left window is 40 columns of which one is the
    border.
    """
    path = "/tmp/resize.txt"
    open(path, "w").write("hello\n")
    problems = []

    def border_column(rows, cols):
        screen = screen_of(drive([C_x + b"3", ("resize", rows, cols)], path))
        columns = [r.index("|") for r in screen.split("\n") if "|" in r]
        return max(columns) if columns else -1

    for rows, cols, want in ((24, 100, 49), (24, 60, 29), (24, 80, 39)):
        got = border_column(rows, cols)
        if got != want:
            problems.append("after resizing to %d columns the border is in "
                            "column %d, expected %d" % (cols, got, want))

    # and the rows follow too: the mode line sits on the row above the echo
    # area, whatever the height is
    for rows in (40, 12):
        screen = screen_of(drive([C_x + b"3", ("resize", rows, 80)], path))
        on = [i for i, r in enumerate(screen.split("\n")) if "resize.txt" in r]
        want = rows - 2
        if not on:
            problems.append("at %d rows there is no mode line on the screen"
                            % rows)
        elif max(on) != want:
            problems.append("at %d rows the mode line is on row %d, expected "
                            "%d" % (rows, max(on), want))
    return problems


def check_suspend():
    """C-z must hand the terminal back, stop, and take it again.

    GNU Emacs's `suspend-frame' (C-z on a terminal) does three things:
    puts the terminal back the way the shell left it, raises SIGTSTP, and
    re-enters the terminal when the job is resumed. The terminal is in
    `raw' mode here, so the kernel does not stop the process from the key
    itself - the editor has to, which is what Emacs does too.

    What this checks is the part that can be seen from outside: ncurses
    leaving the alternate screen and entering it again, with the buffer
    drawn after it. That is the failure that matters - a suspend that does
    not restore the terminal leaves the user's shell unusable, and one
    that does not re-enter it leaves the editor drawing into a screen it
    no longer owns.

    The *stop itself* cannot be seen from this harness, and that is a real
    POSIX rule rather than a gap in the test: `pty.fork' makes the child a
    session leader, its process group has no member whose parent is in the
    same session, and a stop signal sent to an orphaned process group is
    discarded. Run from a login shell in the foreground the group is not
    orphaned and the editor stops, exactly as Emacs does.
    """
    path = "/tmp/suspend.txt"
    open(path, "w").write("SUSPENDED-TEXT\n")
    out = drive([b"x", b"\x1a"], path)      # a key, then C-z
    leave = "\x1b[?1049l"                    # ncurses leaving its screen
    enter = "\x1b[?1049h"                    # and entering it again
    if leave not in out:
        return ["C-z did not hand the terminal back: ncurses never left "
                "its screen"]
    after = out[out.rindex(leave):]
    if enter not in after:
        return ["the terminal was handed back and never taken again"]
    if "SUSPENDED-TEXT" not in after[after.rindex(enter):]:
        return ["the screen was not redrawn after resuming"]
    return []


def check_buffer_menu():
    """C-x C-b shows the buffer list below, RET picks a buffer, and q leaves.

    `list-buffers' displays the list without selecting it, so the file
    keeps its window and point; `C-x o' goes to the list, and `q'
    (`quit-window') takes the list's window off the frame again. The list
    itself is the seven columns of `buff-menu.el' - the C column marking
    the buffer the list was made from, R and M for read-only and modified,
    then the name, the size, the mode and the file.

    The keys are the list's own, from its buffer-local keymap, and RET is
    the one worth driving: it arrives as the byte 13 a terminal sends, and
    it acts on the buffer on the line point is on. That makes it the check
    for two things at once - that the buffer's keymap is the one the lookup
    finds, and that the line point is on is the line the user is looking
    at. Point has to start on the first buffer's line, not on the titles',
    which is a line of the buffer's text here rather than a header line.
    """
    path = "/tmp/pty-check-menu.txt"
    other = "/tmp/pty-check-other.txt"
    open(path, "w").write("MENU-TEXT\n")
    open(other, "w").write("OTHER-TEXT\n")
    problems = []

    screen = screen_of(drive([C_x + b"\x02"], path))     # C-x C-b
    if "C R M Buffer" not in screen:
        problems.append("the list's column titles are not on the screen")
    if ".  pty-check-menu.txt" not in screen:
        # the `.` is the C column: the buffer the list was made from
        problems.append("no row for the visited file, marked `.` in the C "
                        "column")
    if "MENU-TEXT" not in screen:
        problems.append("the file's own window is gone: `list-buffers' "
                        "must not replace it")

    # C-x o into the list, then q to take its window off the frame
    screen = screen_of(drive([C_x + b"\x02", C_x + b"o", b"q"], path))
    mode_lines = [r for r in screen.split("\n") if "--" in r and "L" in r]
    if len(mode_lines) != 1:
        problems.append("after q there are %d windows, expected 1"
                        % len(mode_lines))
    if "MENU-TEXT" not in screen:
        problems.append("after q the file's text is not on the screen")

    # Visit a second file, so the list has two rows. C-x o goes into the
    # list, and RET acts on the line point starts on - the first row, the
    # buffer the list was made from, which is pty-check-other.txt. Both
    # windows then show it and the list is off the frame.
    into_list = [C_x + C_f, C_a, C_k, other.encode(), RET, C_x + b"\x02",
                 C_x + b"o"]
    screen = screen_of(drive(into_list + [RET], path))
    if "C R M Buffer" in screen:
        problems.append("RET left the list on the frame instead of showing "
                        "the buffer on the line")
    if screen.count("OTHER-TEXT") != 2:
        problems.append("RET on the first row: expected both windows to show "
                        "the buffer the list was made from, saw %d"
                        % screen.count("OTHER-TEXT"))

    # The same again with `n' first, so the line is not the one point
    # started on: down to the second row, then RET shows the other file.
    screen = screen_of(drive(into_list + [b"n", RET], path))
    if "C R M Buffer" in screen:
        problems.append("RET after n left the list on the frame")
    if "MENU-TEXT" not in screen:
        problems.append("RET after n did not show the second row's buffer")
    return problems


def check_hscroll():
    """A truncated line is reachable: the window hscrolls to keep point.

    With `truncate-lines' on, the part of a long line beyond the window
    is otherwise unreachable. Emacs's answer is `auto-hscroll-mode'
    (t by default) and `w->hscroll', which `hscroll_window_tree'
    (xdisp.c:16625) adjusts whenever point lands in the `hscroll-margin'
    (5) at either edge, putting point at the window's horizontal centre
    when `hscroll-step' is 0 - which was measured on `emacs -nw': point
    at column 239 of an 80-column window gave `window-hscroll' 199 and
    the cursor in column 40. The row drawn is `$' in its first cell (the
    left truncation glyph overwrites the character at the hscroll
    column), then the visible characters, then `$' in the last cell when
    the line runs past the view. Moving point to a short line scrolls
    back to 0, and an interactive `scroll-left' (C-x <) pins the amount
    (`window.c:7113' sets `w->min_hscroll').

    A same-size resize ends every run: an hscroll redraw is incremental,
    and this screen reader would otherwise read the new writes on top of
    the rows the old hscroll drew.
    """
    path = "/tmp/pty-check-hscroll.txt"
    with open(path, "w") as port:
        port.write("0123456789" * 25 + "\nsecond line\n")
    C_e = b"\x05"
    C_n = b"\x0e"
    M_x = b"\x1b" + b"x"
    redraw = ("resize", 24, 80)
    problems = []
    screen = screen_of(drive([M_x, b"toggle-truncate-lines", b"\r",
                              C_e, C_n, redraw], path, settle=2.5, gap=0.35))
    rows = screen.split("\n")
    if not rows or rows[0][0] != "0":
        problems.append("with hscroll reset by the short line below, "
                        "row 0 did not begin at column 0: %r"
                        % (rows[0][:10] if rows else None))
    if len(rows) > 0 and rows[0][79:80] != "$":
        problems.append("a truncated line did not end with $: %r"
                        % (rows[0][74:80] if rows else None))
    if len(rows) < 2 or "second line" not in rows[1]:
        problems.append("the short line below was not shown after the "
                        "hscroll reset: %r" % (rows[1][:20] if len(rows) > 1
                                               else None))

    # C-e alone: point at the end of the 250-column line. Auto hscroll
    # centres it: hscroll 210, `$' overwrites character 210, characters
    # 211..249 fill columns 1..39 and the row is blank past column 40 -
    # no right `$', because the line ends inside the view.
    screen = screen_of(drive([M_x, b"toggle-truncate-lines", b"\r",
                              C_e, redraw], path, settle=2.5, gap=0.35))
    rows = screen.split("\n")
    if not rows or rows[0][0] != "$":
        problems.append("the hscrolled row did not begin with the left "
                        "truncation glyph: %r"
                        % (rows[0][:4] if rows else None))
    if len(rows) > 0 and rows[0][1:3] != "12":
        problems.append("the row after the left glyph was not characters "
                        "211.. (got %r, wanted '12')" % rows[0][1:3])
    if len(rows) > 0 and rows[0][38:40] != "89":
        problems.append("the row's last character was not 249 (got %r, "
                        "wanted '89')" % rows[0][38:40])
    if len(rows) > 0 and rows[0][40:79] != " " * 39:
        problems.append("the hscrolled row did not run out of characters "
                        "at column 40: %r" % rows[0][40:50])

    # C-x <: scroll-left with no prefix scrolls width-2 = 78 columns and
    # pins that as the minimum; moving down to the short line then leaves
    # the window hscrolled at 78 instead of resetting it.
    screen = screen_of(drive([M_x, b"toggle-truncate-lines", b"\r",
                              b"\x18<", C_n, redraw], path, settle=2.5, gap=0.35))
    rows = screen.split("\n")
    if not rows or rows[0][0] != "$":
        problems.append("after C-x < the row did not begin with the left "
                        "truncation glyph: %r"
                        % (rows[0][:4] if rows else None))
    if len(rows) > 0 and rows[0][1:3] != "90":
        problems.append("after C-x < the visible text did not start at "
                        "character 79 (got %r, wanted '90')"
                        % rows[0][1:3])
    if len(rows) > 0 and rows[0][79:80] != "$":
        problems.append("after C-x < the truncated line did not end with "
                        "$: %r" % rows[0][74:80])
    if len(rows) > 1 and rows[1][:2] != "$ ":
        problems.append("after C-x < the short line was not scrolled out "
                        "of view (row = %r)" % rows[1][:12])
    return problems


def check_query_replace():
    """M-% asks, and y/n/! answer it, in Emacs's words.

    `perform-replace' shows `Query replacing X with Y: (help for help)'
    per match, `y' replaces the match, `n' skips, `!' replaces the rest
    without asking, and the end says `Replaced N occurrence(s)'. The
    replacement is on screen after each key - the buffer is not saved
    here, the text check is the screen's.
    """
    path = "/tmp/pty-check-qr.txt"
    open(path, "w").write("apple apple apple\n")
    problems = []
    # M-% = ESC %; read FROM and TO, then answer y, n, y
    out = drive([C_x + C_f, C_a, C_k, path.encode(), RET,
                 ESC, b"%", b"apple", RET, b"pear", RET,
                 b"y", b"n", b"y"], path, gap=0.35)
    if "Replaced 2 occurrences" not in out:
        problems.append("y n y did not end with `Replaced 2 occurrences'")
    if "pear" not in out:
        problems.append("the replaced text is not on the screen")
    # `!' replaces the rest without asking
    out = drive([C_x + C_f, C_a, C_k, path.encode(), RET,
                 ESC, b"%", b"apple", RET, b"pear", RET,
                 b"n", b"!"], path, gap=0.35)
    if "Replaced 2 occurrences" not in out:
        problems.append("`n' then `!' did not end with `Replaced 2 occurrences'")
    # q exits early with the replacements it made
    out = drive([C_x + C_f, C_a, C_k, path.encode(), RET,
                 ESC, b"%", b"apple", RET, b"pear", RET,
                 b"y", b"q"], path, gap=0.35)
    if "Replaced 1 occurrence" not in out:
        problems.append("`y' then `q' did not end with `Replaced 1 occurrence'")
    return problems


def check_query_replace_quit():
    """C-g during the query leaves the buffer alone and says Quit.

    The dynamic-wind cleanup clears the highlight; the command loop's
    guard reports the quit. Nothing is replaced.
    """
    path = "/tmp/pty-check-qrq.txt"
    open(path, "w").write("apple apple\n")
    problems = []
    out = drive([C_x + C_f, C_a, C_k, path.encode(), RET,
                 ESC, b"%", b"apple", RET, b"pear", RET,
                 C_g], path, gap=0.35)
    if "Quit" not in out:
        problems.append("C-g during query-replace did not report Quit")
    # no y was pressed, so nothing was replaced: no "Replaced N" message
    if "Replaced" in out:
        problems.append("C-g during query-replace ran a replacement")
    return problems


def check_query_replace_prompt():
    """M-% prompts `Query replace: ' in the prompt face, and remembers the pair.

    Three things GNU Emacs does that this did not. `format-prompt'
    closes a prompt with ": " whether or not it has a default - it
    returned the prompt untouched when it had none, so M-% prompted
    `Query replace' with the typed text hard against it. The prompt is
    drawn in the `minibuffer-prompt' face, which is what gives it its
    colour; it was drawn as one plain string with the typed text. And a
    second M-% names the last replacement pair as its default,
    `Query replace (default apple -> pear): ' - the pair, not just the
    FROM half, and with the arrow `query-replace-from-to-separator'
    spells, rather than the literal `%s' the default clause used to come
    out as.
    """
    import re as _re
    path = "/tmp/pty-check-qr-prompt.txt"
    open(path, "w").write("apple apple\n")
    problems = []

    def repaint(out):
        """The last full repaint, escapes and all."""
        return out.rsplit("\x1b[2J", 1)[-1]

    def plain(out):
        return _re.sub(r"\x1b\[[0-9;?]*[A-Za-z]|\x1b.", "", repaint(out))

    out = drive([ESC, b"%"], path, settle=2.0)
    if "Query replace: " not in plain(out):
        problems.append("M-% did not prompt `Query replace: ' - the colon "
                        "and space a prompt is closed with are missing")

    # The prompt must carry a face of its own. The escapes are walked
    # rather than stripped so that the attributes active where the prompt
    # text came out can be read, as `isearch-scroll' does.
    sgr = set()
    prompt_marked = False
    for chunk in _re.split(r"(\x1b\[[0-9;]*[A-Za-z]|\x1b\(B|\r|\n)", repaint(out)):
        if not chunk or chunk in ("\r", "\n"):
            continue
        if chunk.startswith("\x1b["):
            mm = _re.match(r"\x1b\[([0-9;]*)([A-Za-z])", chunk)
            if mm.group(2) == "m":
                sgr = set(x for x in mm.group(1).split(";") if x)
            continue
        if "Query replace" in chunk and sgr:
            prompt_marked = True
    if not prompt_marked:
        problems.append("the prompt is drawn with no face - in Emacs it "
                        "carries `minibuffer-prompt'")

    # `q' leaves the pair in the history and the buffer alone, so the
    # second M-% is the first prompt again, with a default to name.
    out = drive([ESC, b"%", b"apple", RET, b"pear", RET, b"q",
                 ESC, b"%"], path, settle=2.0)
    if "Query replace (default apple → pear): " not in plain(out):
        problems.append("a repeat M-% did not prompt with the last "
                        "replacement pair as its default")
    return problems


def check_query_replace_pair_default():
    """RET on the pair default replaces exactly as typing the two strings does.

    The FROM prompt's history holds the replacement *pairs*, spelled
    `FROM -> TO'; `query-replace--split-string' reads the chosen one back
    into its two halves. Without that the whole `apple -> pear' would
    have been taken as the FROM string, which searches for nothing.
    """
    path = "/tmp/pty-check-qr-pair.txt"
    content = "apple apple apple\n"
    problems = []
    # a first run quit before it replaces anything: the pair is recorded,
    # the buffer still reads as the file does
    first = [ESC, b"%", b"apple", RET, b"pear", RET, b"q", C_a]

    def run(label, keys):
        open(path, "w").write(content)
        return drive(keys, path, settle=2.0, gap=0.4)

    typed = run("typed", first + [ESC, b"%", b"apple", RET, b"pear", RET, b"!"])
    if "Replaced 3 occurrences" not in typed:
        problems.append("typing the pair replaced the wrong number of matches "
                        "(%r)" % (typed[-60:],))
        return problems

    for label, keys in (("RET on the default", [ESC, b"%", RET, b"!"]),
                        ("M-p then RET", [ESC, b"%", b"\x1bp", RET, b"!"])):
        out = run(label, first + keys)
        if "Replaced 3 occurrences" not in out:
            problems.append("%s did not replace all three matches - the pair "
                            "was not split back into FROM and TO" % label)
    return problems


def check_replace_string():
    """M-x replace-string replaces everything with no questions."""
    path = "/tmp/pty-check-rs.txt"
    open(path, "w").write("apple apple apple\n")
    problems = []
    out = drive([C_x + C_f, C_a, C_k, path.encode(), RET,
                 ESC, b"x", b"replace-string", RET,
                 b"apple", RET, b"pear", RET], path, gap=0.35)
    if "Replaced 3 occurrences" not in out:
        problems.append("M-x replace-string did not say `Replaced 3 occurrences'")
    return problems


def check_quoted_insert():
    """C-q reads the next key as a character.

    C-q C-g inserts a ^G without quitting; the octal digits C-q 1 0 1
    give code 65, `A'; a RET terminator is discarded; C-u 3 C-q a gives
    three of them.
    """
    path = "/tmp/pty-check-qi.txt"
    open(path, "w").write("")
    problems = []
    out = drive([C_q, C_g], path)
    if "^G" not in out:
        problems.append("C-q C-g did not insert ^G (screen %r)" % out[-200:])
    # 101 octal is 65, `A'; the RET that terminates the digits is
    # discarded
    out = drive([C_q, b"1", b"0", b"1", RET], path)
    if "A" not in out:
        problems.append("C-q 1 0 1 RET did not insert A")
    # a non-digit terminator is used itself as input: the code 010 = 8
    # is inserted and the `x' runs as a command
    out = drive([C_q, b"1", b"0", b"x"], path)
    if "^Hx" not in out:
        problems.append("C-q 1 0 x did not insert ^H and run the x")
    out = drive([C_u, b"3", C_q, b"a"], path)
    if "aaa" not in out:
        problems.append("C-u 3 C-q a did not insert aaa")
    return problems


def check_insert_file():
    """C-x i inserts a file's contents after point, mark set."""
    path = "/tmp/pty-check-ins-src.txt"
    open(path, "w").write("inserted line\n")
    problems = []
    out = drive([b"before ", C_x, b"i", C_a, C_k, path.encode(), RET],
                "/tmp/pty-check-ins.txt", gap=0.35)
    if "before inserted line" not in out:
        problems.append("C-x i did not insert the file after `before '")
    if "Mark set" not in out:
        problems.append("C-x i did not say `Mark set' after the insert")
    return problems


def check_find_file_read_only():
    """C-x C-r visits read-only, and editing it says so."""
    path = "/tmp/pty-check-rfro.txt"
    open(path, "w").write("readonly content\n")
    problems = []
    out = drive([C_x + C_r, C_a, C_k, path.encode(), RET, b"X"], path, gap=0.35)
    if "Buffer is read-only" not in out:
        problems.append("editing a C-x C-r buffer did not say `Buffer is read-only'")
    return problems


def check_find_alternate_file():
    """C-x C-v kills the old buffer and visits the new file."""
    a = "/tmp/pty-check-faf-a.txt"
    b = "/tmp/pty-check-faf-b.txt"
    open(a, "w").write("file a\n")
    open(b, "w").write("file b\n")
    problems = []
    out = drive([C_x + C_f, C_a, C_k, a.encode(), RET,
                 C_x, C_v, C_a, C_k, b.encode(), RET], a, gap=0.35)
    if "file b" not in out:
        problems.append("C-x C-v did not show the new file's text")
    if "pty-check-faf-b.txt" not in out:
        problems.append("C-x C-v did not visit the new file (mode line)")
    return problems


def check_revert_buffer():
    """M-x revert-buffer rereads the file, confirming edits first."""
    path = "/tmp/pty-check-rev.txt"
    open(path, "w").write("original\n")
    problems = []
    out = drive([C_x + C_f, C_a, C_k, path.encode(), RET,
                 b"EDITED ", ESC, b"x", b"revert-buffer", RET,
                 b"y"], path, gap=0.35)
    if "Discard edits and reread from" not in out:
        problems.append("revert of a modified buffer did not ask "
                        "`Discard edits and reread from ...? '")
    # after the y, the screen shows the file's text again
    i = out.find("Discard edits")
    if i >= 0 and "original" not in out[i:]:
        problems.append("revert did not reread the file after the y")
    return problems


def check_not_modified():
    """M-~ clears the modified flag, so exit asks nothing."""
    path = "/tmp/pty-check-nm.txt"
    open(path, "w").write("hello\n")
    problems = []
    # edit, M-~, quit: no modified question, editor exits
    screen, exited = drive([b"X", M_TILDE, C_x + C_c], path,
                           report_exit=True, gap=0.4)
    if "Modification-flag cleared" not in screen:
        problems.append("M-~ did not say `Modification-flag cleared'")
    if not exited:
        problems.append("M-~ then C-x C-c still asked about modified buffers")
    # with a prefix it sets the flag instead
    out = drive([C_u, M_TILDE], path, gap=0.35)
    if "Modification-flag set" not in out:
        problems.append("M-~ with a prefix did not say `Modification-flag set'")
    return problems


def check_find_file_substitution():
    """`//' in a name typed at `C-x C-f' goes back to the root.

    `read-file-name-default' runs the typed name through
    `substitute-in-file-name' before returning it (minibuffer.el:4192),
    and that is where a name is re-rooted: "If `//' appears, everything
    up to and including the first of those `/' is discarded"
    (fileio.c:2060). So `/tmp//tmp/x' names `/tmp/x'.

    This port left that call out entirely, so a typed `//' reached
    `expand-file-name' instead, which is the *other* rule - it collapses
    repeated slashes and keeps only a leading pair - and the name meant
    `/tmp/tmp/x'. The two functions disagree about `//' on purpose, which
    is why the substitution has to happen where Emacs puts it.
    """
    d = "/tmp/pty-check-slash"
    import os as _os
    _os.makedirs(d, exist_ok=True)
    path = _os.path.join(d, "x.txt")
    open(path, "w").write("SLASH-CONTENT\n")
    problems = []
    # `/tmp//tmp/pty-check-slash/x.txt' is `/tmp/pty-check-slash/x.txt'
    typed = "/tmp//" + d.lstrip("/") + "/x.txt"
    out = drive([C_x + C_f, C_a, C_k, typed.encode(), RET], "/tmp/pty-check-mx.txt",
                settle=2.0, gap=0.35)
    if "SLASH-CONTENT" not in out:
        problems.append("`C-x C-f %s' did not visit %s - a `//' in a typed "
                        "name must be discarded up to, not doubled"
                        % (typed, path))
    return problems


def check_pwd():
    """M-x pwd shows the default directory; with a prefix it inserts it.

    files.el's `pwd' is a straight pair of statements -
    `(message "Directory %s" default-directory)' and `(insert
    default-directory)' - and two departures hid in it. The tree's
    `default-directory' is a zero-argument *procedure*, so the variable
    read has to be a call (without one the message reads "Directory
    #<procedure default-directory ()>"); and the C's parameter is named
    INSERT, which shadows editfns.c's `insert' procedure, so the
    inserting arm applied the prefix as a function. Both are checked
    here, and both showed only in the drawn message.
    """
    d = "/tmp/pty-check-pwd"
    import os as _os
    _os.makedirs(d, exist_ok=True)
    path = _os.path.join(d, "f.txt")
    open(path, "w").write("hello\n")
    problems = []
    out = drive([b"\x1b", b"x", b"pwd", b"\r"], path, settle=2.0, gap=0.35)
    if "Directory " + d + "/" not in out:
        problems.append("M-x pwd did not show the default directory - it "
                        "should say `Directory %s/' for the buffer's" % d)
    if "#<procedure" in out:
        problems.append("M-x pwd printed a procedure where the directory "
                        "goes: `default-directory' is a procedure in this "
                        "tree and has to be called")
    # and with a prefix the directory goes into the buffer instead - no
    # message, so what is looked for is the text at point, with the
    # file's own first line right after it
    out = drive([C_u, b"\x1b", b"x", b"pwd", b"\r"], path, settle=2.0, gap=0.35)
    if "Wrong type to apply" in out:
        problems.append("C-u M-x pwd applied the prefix as a function - "
                        "the parameter named `insert' shadows the "
                        "procedure")
    if d + "/hello" not in out:
        problems.append("C-u M-x pwd did not insert the default directory "
                        "at point")
    return problems


def check_set_fill_column():
    """C-u 20 C-x f sets fill-column, saying what it was."""
    path = "/tmp/pty-check-sfc.txt"
    open(path, "w").write("hello\n")
    problems = []
    out = drive([C_u, b"2", b"0", C_x, b"f"], path, gap=0.35)
    if "Fill column set to 20 (was 70)" not in out:
        problems.append("C-u 20 C-x f did not say "
                        "`Fill column set to 20 (was 70)'")
    return problems


def check_dired():
    """C-x d opens a Dired buffer on a directory."""
    import os as _os
    d = "/tmp/pty-check-dired"
    _os.makedirs(d, exist_ok=True)
    with open(_os.path.join(d, "hello.txt"), "w") as out:
        out.write("hi\n")
    with open(_os.path.join(d, "second.txt"), "w") as out:
        out.write("ho\n")
    problems = []
    import re as _re

    def plain(text):
        """TEXT with the terminal's escape sequences taken out.

        The listing carries faces now that Dired fontifies through
        font-lock - the header gets `dired-header', a name gets
        `dired-directory', a permission character gets `dired-perm-write'
        - and a terminal draws each face run with escapes around it, so
        a literal like "/tmp/x:" or "D " is not in the byte stream. The
        checks are about what is drawn, not about how, so they read the
        stripped text.
        """
        return _re.sub(r"\x1b\[[0-9;?]*[A-Za-z]|\x1b\(B|\x1b.", "", text)

    out = plain(drive([C_x + b"d", C_a, C_k, (d + "/").encode(), RET],
                      _os.path.join(d, "hello.txt"), gap=0.35))
    if "Dired" not in out:
        problems.append("C-x d did not enter Dired (the mode line says so)")
    if "hello.txt" not in out:
        problems.append("C-x d did not list the directory's file")
    # the header line is the directory as a directory name, which is what
    # `dired-insert-directory' takes it from
    if d + ":" not in out:
        problems.append("the listing has no header line naming the directory")

    # And the free space follows that colon, as Emacs 31 draws it: the
    # `total N' line the listing wrote is deleted and `dired--insert-disk-
    # space' puts "(SUCH available)" on the colon - as a `display' TEXT
    # PROPERTY, which the redisplay substitutes for the character it
    # stands on. Both halves are checked here because the *substitution*
    # is the part that only drawing can show: the property can be on the
    # buffer, the free space can be right, and the header still read
    # "/tmp/x:" if the renderer ignored `display'.
    if "total" in out:
        problems.append("the listing still shows the `total N' line, which "
                        "Emacs 31's `dired-free-space' deletes")
    if not _re.search(_re.escape(d) + r": \([^)]* available\)", out):
        problems.append("the header does not show the free disk space - "
                        "`dired--insert-disk-space' puts it on the colon as "
                        "a `display' property, and the redisplay must draw it")

    # And the editor started *on* a directory - `emacs /some/dir' - direds
    # it too: `find-file-noselect' sends a directory through
    # `find-directory-functions', whose value names `dired-noselect'.
    # Before that branch was ported this said
    # `; find-file: error loading <dir>'.
    out = plain(drive([], d, gap=0.4))
    if "Dired" not in out:
        problems.append("the editor started on a directory did not enter "
                        "Dired")
    if "hello.txt" not in out:
        problems.append("the editor started on a directory did not list it")

    # And the marking keys work. `m' hands `dired-mark' the raw prefix,
    # which is nil when none was typed - and the C's body converts it with
    # `(prefix-numeric-value arg)' before the walk needs a number. Without
    # that conversion `m', `d' and `u' failed with "Wrong type argument in
    # position 2: #f", which read as "the keys do nothing".
    #
    # The editor is started *on the directory* rather than driven through
    # `C-x d', so no prompt is involved: typing into the directory prompt
    # is timing-sensitive enough that `m' and `d' sometimes landed in it.
    # The mark characters carry faces now that Dired fontifies through
    # font-lock (`dired-re-mark' gets `dired-mark-face'), so a terminal
    # draws them with escape sequences around them and the literal
    # strings "* " and "D " are not in the byte stream. Stripped before
    # the two tests, which are about the marks being made, not about how
    # they are drawn - `dired-delete' below is what exercises the drawing
    # and the deletion.
    out = plain(drive([b"m", b"d"], d, gap=0.35))
    if "* " not in out:
        problems.append("`m' in Dired did not mark the file at point")
    if "D " not in out:
        problems.append("`d' in Dired did not flag the next file")
    if "Wrong type argument" in out:
        problems.append("a Dired marking key still fails on the prefix: "
                        "Wrong type argument in position 2: #f")
    if "read-only" in out:
        problems.append("a Dired marking key was refused as read-only")
    return problems



def check_dired_delete():
    """`d' then `x' deletes the flagged file, by key."""
    import os as _os
    d = "/tmp/pty-check-dired-delete"
    _os.makedirs(d, exist_ok=True)
    for name in ("gone.txt",):
        with open(_os.path.join(d, name), "w") as out:
            out.write("x\n")
    for name in ("keep.txt",):
        with open(_os.path.join(d, name), "w") as out:
            out.write("y\n")
    problems = []
    # Start on the directory, so no `C-x d' prompt is involved (`m' and
    # `d' have landed in that prompt before). `d' flags, `x' runs
    # `dired-do-flagged-delete', and with one file in the list the
    # confirmation is `yes-or-no-p''s - whose answer is the whole word.
    # Point starts on `gone.txt' (the listing is sorted, and `..' comes
    # before it).
    out = drive([b"d", b"x", b"yes", RET], d, gap=0.4)
    if "read-only" in out:
        problems.append("`x' was refused as read-only - it was unbound and "
                        "self-inserted into the read-only listing")
    if "end of buffer" in out.lower():
        problems.append("`x' ran off the end of the buffer")
    if _os.path.exists(_os.path.join(d, "gone.txt")):
        problems.append("`d' then `x' did not delete the flagged file")
    if not _os.path.exists(_os.path.join(d, "keep.txt")):
        problems.append("`x' deleted a file that was not flagged")
    return problems


def check_cd():
    """`M-x cd' makes the directory the buffer's `default-directory'.

    `cd' (files.el:920) resolves its argument through `locate-file' over
    `cd-path' - the CDPATH list - and hands the answer to `cd-absolute',
    which puts it in directory syntax, checks it is really a directory
    and makes it the buffer's `default-directory'. `cd' is bound to no
    key in GNU Emacs - `where-is-internal' answers nil - so M-x is the
    only way in, which is what this drives.

    The observable is the next `C-x C-f' prompt, which holds
    `default-directory'. The prompt arrives prefilled with the current
    directory, so `C-a C-k' clears it before the new path is typed.
    """
    path = "/tmp/pty-check-cd.txt"
    open(path, "w").write("hello\n")
    problems = []

    screen = screen_of(drive([b"\x1b", b"x", b"cd", b"\r",
                              C_a, C_k, b"/tmp", b"\r", C_x + C_f],
                             path, settle=2.0, gap=0.4))
    if "Find file: " not in screen:
        problems.append("no `Find file: ' prompt after M-x cd")
    else:
        shown = screen.split("Find file: ", 1)[1].split("\n")[0].strip()
        if not shown.startswith("/tmp/"):
            problems.append("after M-x cd RET /tmp the prompt offers %r, "
                            "not something under /tmp/" % shown)

    # a directory that is not there is a message, and `default-directory'
    # is left alone - worth checking because `/etc/hostname' is a *file*,
    # on which Emacs does not say "is not a directory" either: the
    # `dir-ok' predicate rejects it in `locate-file' first.
    out = drive([b"\x1b", b"x", b"cd", b"\r", C_a, C_k,
                 b"/etc/hostname", b"\r"], path, settle=2.0, gap=0.4)
    if "No such directory: /etc/hostname" not in out:
        problems.append("M-x cd to a file did not say "
                        "`No such directory: /etc/hostname'")

    return problems


CHECKS = {
    "buffer-menu": check_buffer_menu,
    "query-replace": check_query_replace,
    "query-replace-prompt": check_query_replace_prompt,
    "query-replace-pair-default": check_query_replace_pair_default,
    "query-replace-quit": check_query_replace_quit,
    "replace-string": check_replace_string,
    "quoted-insert": check_quoted_insert,
    "insert-file": check_insert_file,
    "dired": check_dired,
    "dired-delete": check_dired_delete,
    "find-file-read-only": check_find_file_read_only,
    "find-alternate-file": check_find_alternate_file,
    "revert-buffer": check_revert_buffer,
    "not-modified": check_not_modified,
    "pwd": check_pwd,
    "find-file-substitution": check_find_file_substitution,
    "set-fill-column": check_set_fill_column,
    "suspend": check_suspend,
    "resize": check_resize,
    "minibuffer": check_minibuffer,
    "scroll": check_scroll,
    "save": check_save,
    "save-y-n": check_save_y_n,
    "redisplay": check_redisplay,
    "newline": check_newline,
    "crlf": check_crlf,
    "completions": check_completions,
    "completion-ui": check_completion_ui,
    "completion-tab-tab": check_completion_tab_tab,
    "completion-columns": check_completion_columns,
    "completion-window": check_completion_window,
    "completion-width": check_completion_width,
    "completion-resize": check_completion_resize,
    "quit-completions": check_quit_after_completion,
    "default-directory": check_default_directory,
    "m-x": check_m_x,
    "cd": check_cd,
    "isearch-highlight": check_isearch_highlight,
    "isearch-multiline": check_isearch_multiline,
    "isearch-scroll": check_isearch_scroll,
    "isearch-highlight-row": check_isearch_highlight_row,
    "isearch-quit": check_isearch_quit,
    "region-highlight": check_region_highlight,
    "continuation": check_continuation,
    "mode-line-eol": check_mode_line_eol,
    "wide-columns": check_wide_columns,
    "kill-ring": check_kill_ring,
    "osc52": check_osc52,
    "what-cursor": check_what_cursor,
    "goto-line": check_goto_line,
    "write-file": check_write_file,
    "recenter": check_recenter,
    "split": check_split,
    "hscroll": check_hscroll,
}


def main():
    names = sys.argv[1:] or list(CHECKS)
    failed = []
    for name in names:
        if name not in CHECKS:
            print("no such check: %s (have: %s)"
                  % (name, ", ".join(CHECKS)))
            return 2
        problems = CHECKS[name]()
        if problems:
            failed.append(name)
            print("FAIL %s" % name)
            for p in problems:
                print("     %s" % p)
        else:
            print("ok   %s" % name)
    print("%d/%d checks passed" % (len(names) - len(failed), len(names)))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
