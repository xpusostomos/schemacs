#!/usr/bin/env python3
"""Run the test suites and say whether each one actually ran.

Counting `FAIL` lines is not enough to know a suite passed: a suite that
dies while loading prints no test output at all, so it counts zero failures
and looks green. That happened - the frontend's import of a name the
keyboard library no longer exported killed both suites at load, and the
sweep that only counted `FAIL` reported "0 failures" for both.

A suite counts as having run when it reports at least one expected pass.
SRFI-64 prints `*** # of expected passes : N` for every group, so a suite
with no passes either failed to load or has no tests - both worth knowing.

    tools/run-suites.py            # the engine and frontend suites
    tools/run-suites.py <file>...  # named suites

Exit status is 1 if a suite failed to run or reported a failure.
"""
import os
import re
import subprocess
import tempfile
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SUITES = [
    'schemacs/editor/character-tests.scm',
    'schemacs/editor/buffer-tests.scm',
    'schemacs/editor/buffer-text-tests.scm',
    'schemacs/editor/region-cache-tests.scm',
    'schemacs/editor/engine-tests.scm',
    'schemacs/editor/derived-tests.scm',
    'schemacs/editor/dired-tests.scm',
    'schemacs/editor/dired-mode-tests.scm',
    'schemacs/editor/font-lock-tests.scm',
    'schemacs/editor/editfns-tests.scm',
    'schemacs/editor/env-tests.scm',
    'schemacs/editor/fileio-tests.scm',
    'schemacs/editor/files-tests.scm',
    'schemacs/editor/indentc-tests.scm',
    'schemacs/editor/coding-tests.scm',
    'schemacs/editor/charset-tests.scm',
    'schemacs/editor/mule-cmds-tests.scm',
    'schemacs/editor/cmds-tests.scm',
    'schemacs/editor/mouse-tests.scm',
    'schemacs/repl-client-tests.scm',
    'schemacs/editor/loadup-tests.scm',
    'schemacs/editor/fns-tests.scm',
    'schemacs/editor/subr-tests.scm',
    'schemacs/editor/textprop-tests.scm',
    'schemacs/editor/ls-lisp-tests.scm',
    'schemacs/editor/timefns-tests.scm',
    'schemacs/editor/search-tests.scm',
    'schemacs/editor/replace-tests.scm',
    'schemacs/editor/faces-tests.scm',
    'schemacs/ui/gtk/pgtk-tests.scm',
    'schemacs/editor/timer-tests.scm',
    'schemacs/editor/select-tests.scm',
    # The terminal's own OSC 52 selection, which came out of
    # `select-tests.scm' when the platform libraries moved under
    # `schemacs/ui/': an editor test that asserts the terminal's
    # behaviour belongs beside `xterm.sld'.
    #
    # **These lines were `;;' until 2026-10-09** - Scheme comments pasted
    # into a Python list, which is a SyntaxError at line 59. So this
    # runner was dead from the "finish reorg" commit onward and *no*
    # suite ran, whatever the handoff notes said. It failed at parse time
    # with exit 1, which reads like a failing suite; the one thing this
    # file must never be is the reason nobody noticed.
    'schemacs/ui/ncurses/xterm-tests.scm',
    'schemacs/editor/startup-tests.scm',
    'schemacs/apps/ncurses-editor-tests.scm',
    # The two suites of the top-level libraries. **They are here for the
    # first time**: both imported `(schemacs test)`, the eighteen-line
    # SRFI-64 re-export shim the reorg deleted, so both died at load and
    # neither was in this list - 187 tests that had not run since. They
    # take `(srfi 64)` directly now, as every other suite in the tree
    # already did.
    'schemacs/keymap-tests.scm',
    'schemacs/lens-tests.scm',
]


# **No cairo path here any more.** `pgtk.scm' needs
# `cairo-context->pointer' and `cairo-pointer->context', which only a
# guile-cairo newer than 1.11.2 has - and this put the tree's staged copy
# of one on the path. That staging is gone (2026-10-10): guile-cairo is
# installed where Guile looks for libraries, so the GTK suite finds it the
# way everything else does. A machine without such an install loses that
# one suite, which is what `make`'s own note about it says.

# An empty config directory, so a suite never loads the developer's init
# file. See the note in `run'.
TEST_CONFIG_HOME = tempfile.mkdtemp(prefix='schemacs-test-config-')


def run(path):
    proc = subprocess.run(
        ['guile', '--no-auto-compile', '-L', REPO, '-s', path],
        capture_output=True, text=True, cwd=REPO, timeout=900,
        env=dict(os.environ, GUILE_WARN_DEPRECATED='no',
                 # No developer's init file: `startup.sld' loads
                 # `$XDG_CONFIG_HOME/schemacs/init.scm', and one that
                 # changes the editor changes what a suite sees. The
                 # author's opens the REPL back door.
                 XDG_CONFIG_HOME=TEST_CONFIG_HOME))
    out = proc.stdout + proc.stderr
    passes = sum(int(n) for n in re.findall(
        r'\*\*\* # of expected passes\s*:\s*(\d+)', out))
    failures = sum(int(n) for n in re.findall(
        r'\*\*\* # of unexpected failures\s*:\s*(\d+)', out))
    # **A suite that aborts is not a suite that passed.** `srfi 64' prints
    # its failure count in the summary at `test-end', so a run that dies
    # inside a test - an error escaping srfi-64's own handler - prints
    # *passes* and no failure count at all, and counting only the summary
    # line reports it green. `faces-tests.scm' did exactly that with four
    # failing tests in it for as long as anyone looked. The summary's last
    # line is the tell.
    finished = '*** Test suite finished' in out
    return passes, failures, finished, out


def main():
    paths = [a for a in sys.argv[1:] if not a.startswith('-')] or SUITES
    bad = 0
    for p in paths:
        try:
            passes, failures, finished, out = run(p)
        except subprocess.TimeoutExpired:
            print('%-44s TIMED OUT' % os.path.basename(p))
            bad += 1
            continue
        name = os.path.basename(p)
        if passes == 0:
            # not a pass: the suite never ran
            print('%-44s DID NOT RUN' % name)
            for line in out.strip().split('\n')[-6:]:
                print('      %s' % line)
            bad += 1
        elif failures or not finished:
            if finished:
                print('%-44s %d passed, %d FAILED' % (name, passes, failures))
            else:
                print('%-44s %d passed, then ABORTED' % (name, passes))
                for line in out.strip().split('\n')[-4:]:
                    print('      %s' % line)
            for line in out.split('\n'):
                if 'source-line' in line or 'actual-value' in line:
                    print('      %s' % line.strip())
            bad += 1
        else:
            print('%-44s %d passed' % (name, passes))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
