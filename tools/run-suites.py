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

**Suites run in parallel by default** (`-j 4`): each is its own `guile`
process, and the run is safe because nothing is shared that is written -
`--no-auto-compile` means no compiled file is written to the shared
`XDG_CACHE_HOME`, the suites' fixed `/tmp` paths are each used by one
suite only (checked), and every suite builds its own frames and
displays. Output is still printed in the list's order, so two runs'
logs diff. `-j 1` is the old serial run; a machine short of memory can
ask for fewer workers. The pty battery is NOT part of this - it is
timing-sensitive and runs alone.

    tools/run-suites.py                 # the engine and frontend suites
    tools/run-suites.py <file>...       # named suites
    tools/run-suites.py -j 8 ...        # more or fewer workers

Exit status is 1 if a suite failed to run or reported a failure.
"""
import os
import re
import subprocess
import tempfile
import sys
from concurrent.futures import ThreadPoolExecutor

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SUITES = [
    'test/apps/tty-editor-test.scm',
    'test/abbrev-test.scm',
    'test/auth-source-test.scm',
    'test/auth-source-netrc-test.scm',
    'test/buffer-test.scm',
    'test/buffer-text-test.scm',
    'test/calendar/time-date-test.scm',
    'test/casefiddle-test.scm',
    'test/casetab-test.scm',
    'test/category-test.scm',
    'test/character-test.scm',
    'test/charset-test.scm',
    'test/chartab-test.scm',
    'test/cmds-test.scm',
    'test/coding-test.scm',
    'test/comint-test.scm',
    'test/command-test.scm',
    'test/core/cl-indent-test.scm',
    'test/core/cl-seq-test.scm',
    'test/core/derived-test.scm',
    'test/core/ring-test.scm',
    'test/core/easy-mmode-test.scm',
    'test/core/easymenu-test.scm',
    'test/core/lisp-mode-test.scm',
    'test/core/lisp-test.scm',
    'test/core/map-ynp-test.scm',
    'test/paren-test.scm',
    'test/core/pcase-test.scm',
    'test/core/rx-test.scm',
    'test/core/seq-test.scm',
    'test/core/syntax-macros-test.scm',
    'test/core/text-property-search-test.scm',
    'test/core/timer-test.scm',
    'test/cus-edit-test.scm',
    'test/custom-test.scm',
    'test/diffseq-test.scm',
    'test/dired-mode-test.scm',
    'test/dired-test.scm',
    'test/editfns-test.scm',
    'test/elec-pair-test.scm',
    'test/electric-test.scm',
    'test/engine-test.scm',
    'test/env-test.scm',
    'test/external/omarchy/omarchy-test.scm',
    'test/face-remap-test.scm',
    'test/faces-test.scm',
    'test/fileio-test.scm',
    'test/files-test.scm',
    'test/find-cmd-test.scm',
    'test/process-test.scm',
    'test/external/dash-test.scm',
    'test/external/s-test.scm',
    'test/external/groovy-modes/groovy-mode-test.scm',
    'test/external/groovy-modes/inf-groovy-test.scm',
    'test/external/groovy-modes/groovy-electric-test.scm',
    'test/external/groovy-modes/grails-mode-test.scm',
    'test/filevercmp-test.scm',
    'test/fns-test.scm',
    'test/font-lock-test.scm',
    'test/help-test.scm',
    'test/imenu-test.scm',
    'test/indentc-test.scm',
    'test/international/mule-cmds-test.scm',
    'test/international/mule-diag-test.scm',
    'test/international/mule-util-test.scm',
    'test/intervals-test.scm',
    'test/itree-test.scm',
    'test/jit-lock-test.scm',
    'test/keymap-test.scm',
    'test/loadup-test.scm',
    'test/ls-lisp-test.scm',
    'test/marker-test.scm',
    'test/menu-bar-menus-test.scm',
    'test/menu-bar-test.scm',
    'test/menu-test.scm',
    'test/minibuf-test.scm',
    'test/minibuffer-test.scm',
    'test/mode-line-test.scm',
    'test/mouse-test.scm',
    'test/narrow-test.scm',
    'test/newcomment-test.scm',
    'test/novice-test.scm',
    'test/occur-test.scm',
    'test/progmodes/cc-align-test.scm',
    'test/progmodes/cc-cmds-test.scm',
    'test/progmodes/cc-defs-test.scm',
    'test/progmodes/cc-engine-test.scm',
    'test/progmodes/cc-fonts-test.scm',
    'test/progmodes/cc-langs-test.scm',
    'test/progmodes/cc-menus-test.scm',
    'test/progmodes/cc-mode-test.scm',
    'test/progmodes/cc-styles-test.scm',
    'test/progmodes/cc-vars-test.scm',
    'test/progmodes/cmacexp-test.scm',
    'test/progmodes/compile-test.scm',
    'test/progmodes/prog-mode-test.scm',
    'test/progmodes/scheme-test.scm',
    'test/progmodes/subword-test.scm',
    'test/region-cache-test.scm',
    'test/repl-client-test.scm',
    'test/replace-test.scm',
    'test/scroll-bar-test.scm',
    'test/search-test.scm',
    'test/select-test.scm',
    'test/simple-test.scm',
    'test/startup-test.scm',
    'test/subr-test.scm',
    'test/syntax-test.scm',
    'test/tab-bar-test.scm',
    'test/tab-line-test.scm',
    'test/textmodes/fill-test.scm',
    'test/textprop-test.scm',
    'test/timefns-test.scm',
    'test/tool-bar-test.scm',
    'test/tooltip-test.scm',
    'test/ui/gtk/pgtk-test.scm',
    'test/ui/gtk/pgtk-win-test.scm',
    'test/ui/tty/tinfo-test.scm',
    'test/ui/tty/xterm-test.scm',
    'test/window-config-test.scm',
    'test/window-state-test.scm',
    'test/window-test.scm',
    'test/xfaces-test.scm',
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

# **An empty CACHE directory, so a suite never runs the developer's
# compiled files and never deletes them either.** A stale `.go` is a real
# hazard to a suite (`--no-auto-compile` loads it even when a record
# changed), and the old answer was to delete this tree's entries out of
# `~/.cache/guile/ccache` - which also left the *developer's next editor*
# with no compiled files at all, and an editor running from source is
# five to thirty times slower. Measured: a C-s keystroke on a 240 KB file
# is 25 ms compiled and 430 ms interpreted, and which one you get
# depended on whether a test had been run. Pointing `XDG_CACHE_HOME` at a
# fresh directory gives the suite the same guarantee - nothing cached to
# be stale - and leaves the developer's cache alone.
TEST_CACHE_HOME = tempfile.mkdtemp(prefix='schemacs-test-cache-')


# WHERE A SHARED LIBRARY LIVES. `(schemacs repl)' imports
# `(scheme-utils repl server)', and Guile does NOT search the user's own site
# directory -- measured, the default %load-path has nothing under $HOME. The
# launcher (`bin/se') adds it for running and the Makefile adds it for
# building; without this line a suite that reaches the back door fails to load
# with "no code for module", which reads as a broken suite rather than a
# missing load path.
#
# Only when it is there, and overridable, so a machine that installs the
# library system-wide (where Guile looks by itself) needs nothing here.
SHARED_SITE = os.path.join(
    os.environ.get('XDG_DATA_HOME', os.path.join(os.path.expanduser('~'), '.local', 'share')),
    'guile', 'site', '3.0')
LOAD_PATH_ARGS = ['-L', REPO] + (['-L', SHARED_SITE] if os.path.isdir(SHARED_SITE) else [])


def run(path):
    proc = subprocess.run(
        ['guile', '--no-auto-compile'] + LOAD_PATH_ARGS + ['-s', path],
        capture_output=True, text=True, cwd=REPO, timeout=900,
        env=dict(os.environ, GUILE_WARN_DEPRECATED='no',
                 # No developer's init file: `startup.sld' loads
                 # `$XDG_CONFIG_HOME/schemacs/init.scm', and one that
                 # changes the editor changes what a suite sees. The
                 # author's opens the REPL back door.
                 XDG_CONFIG_HOME=TEST_CONFIG_HOME,
                 # ...and no compiled files, of this tree's or anyone
                 # else's: see `TEST_CACHE_HOME`.
                 XDG_CACHE_HOME=TEST_CACHE_HOME))
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
    # failing tests in it for as long as anyone looked.
    #
    # **And "finished" has to mean every group finished.** srfi 64 prints
    # "Test suite finished" at the end of *each* group, so the old test -
    # whether that line appears at all - stayed true when the first group
    # ended and the second one crashed. Measured on this tree:
    # `faces-tests.scm' crashed in its *second* group for months and was
    # counted green every run. What a complete run leaves is a `Leaving
    # test group' for every `Entering test group' - the counts below.
    entered = out.count('Entering test group')
    left = out.count('Leaving test group')
    finished = ('*** Test suite finished' in out
                and entered == left)
    return passes, failures, finished, out


def report(p, result):
    """Print one suite's line, and answer 1 when it did not pass."""
    try:
        passes, failures, finished, out = result
    except subprocess.TimeoutExpired:
        print('%-44s TIMED OUT' % os.path.basename(p))
        return 1
    name = os.path.basename(p)
    if passes == 0:
        # not a pass: the suite never ran
        print('%-44s DID NOT RUN' % name)
        for line in out.strip().split('\n')[-6:]:
            print('      %s' % line)
        return 1
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
        return 1
    else:
        print('%-44s %d passed' % (name, passes))
        return 0


def parse_jobs(argv):
    """`-j N`, `--jobs N`, `--jobs=N`, `-jN`; the rest are suite paths."""
    jobs = int(os.environ.get('SUITES_JOBS', '4'))
    paths = []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in ('-j', '--jobs') and i + 1 < len(argv):
            jobs = int(argv[i + 1])
            i += 2
        elif a.startswith('--jobs='):
            jobs = int(a.split('=', 1)[1])
            i += 1
        elif a.startswith('-j') and len(a) > 2:
            jobs = int(a[2:])
            i += 1
        else:
            if not a.startswith('-'):
                paths.append(a)
            i += 1
    return max(1, jobs), paths


def main():
    jobs, paths = parse_jobs(sys.argv[1:])
    paths = paths or SUITES
    bad = 0
    if jobs == 1:
        for p in paths:
            bad += report(p, run(p))
        return 1 if bad else 0
    # Output stays in the list's order: every suite is submitted at
    # once, and the answers are collected in `paths` order - so a slow
    # straggler delays the lines after it but the log of a run reads
    # the same as a serial run's.
    with ThreadPoolExecutor(max_workers=jobs) as pool:
        futures = [pool.submit(run, p) for p in paths]
        for p, future in zip(paths, futures):
            bad += report(p, future.result())
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
