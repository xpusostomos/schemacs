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
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SUITES = [
    'schemacs/editor/character-tests.scm',
    'schemacs/editor/buffer-tests.scm',
    'schemacs/editor/engine-tests.scm',
    'schemacs/editor/derived-tests.scm',
    'schemacs/editor/dired-tests.scm',
    'schemacs/editor/dired-mode-tests.scm',
    'schemacs/editor/font-lock-tests.scm',
    'schemacs/editor/editfns-tests.scm',
    'schemacs/editor/env-tests.scm',
    'schemacs/editor/fileio-tests.scm',
    'schemacs/editor/fns-tests.scm',
    'schemacs/editor/textprop-tests.scm',
    'schemacs/editor/ls-lisp-tests.scm',
    'schemacs/editor/timefns-tests.scm',
    'schemacs/editor/search-tests.scm',
    'schemacs/editor/replace-tests.scm',
    'schemacs/editor/faces-tests.scm',
    'schemacs/editor/pgtk-tests.scm',
    'schemacs/editor/timer-tests.scm',
    'schemacs/editor/select-tests.scm',
    'schemacs/editor/startup-tests.scm',
    'schemacs/apps/ncurses-editor-tests.scm',
]


def run(path):
    proc = subprocess.run(
        ['guile', '--no-auto-compile', '--r7rs', '-L', REPO, '-s', path],
        capture_output=True, text=True, cwd=REPO, timeout=900,
        env=dict(os.environ, GUILE_WARN_DEPRECATED='no'))
    out = proc.stdout + proc.stderr
    passes = sum(int(n) for n in re.findall(
        r'\*\*\* # of expected passes\s*:\s*(\d+)', out))
    failures = sum(int(n) for n in re.findall(
        r'\*\*\* # of unexpected failures\s*:\s*(\d+)', out))
    return passes, failures, out


def main():
    paths = [a for a in sys.argv[1:] if not a.startswith('-')] or SUITES
    bad = 0
    for p in paths:
        try:
            passes, failures, out = run(p)
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
        elif failures:
            print('%-44s %d passed, %d FAILED' % (name, passes, failures))
            for line in out.split('\n'):
                if 'source-line' in line or 'actual-value' in line:
                    print('      %s' % line.strip())
            bad += 1
        else:
            print('%-44s %d passed' % (name, passes))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
