# Project Schemacs

#### A clone of Emacs and Emacs Lisp written in Scheme

### Project State

It works!!! It's complete enough that you could daily use it as an editor. 
And it's 100% written in scheme.

Here's what works already:
* Both terminal and Gtk pixel based implementations
* Buffers, buffer switching (C-x b) and buffer manipulation commands
* Marks, kill ring, regions, copy, yank
* Windows, window splitting, window sizing
* The minibuffer, completions, exactly like emacs.
* Minibuffer history
* M-x and interactive commands
* Mode line. 
* Undo list.
* Faces and color highlighting
* Font-lock
* Overlays
* isearch, query-replace, query-replace-regexp 
* Completions, query-replace have color highlighting like real emacs
* eval-expression, eval-region
* Multiple character set detection and conversion
* Handling of illegal characters
* Multiple Frames
* Buffer list
* Dired
* Modes, minor modes, special mode handling
* Clipboard integration
* Mouse support
* And many more...

How does it feel? Zippy! They say they fixed Emacs' performance, 
but it isn't as zippy as this!

## A quick word from our lack of sponsors...

This project has been moderately expensive to implement in its use of
AI, and I'm running out of money to do it. If you want to see it move
forward, money, AI tokens or human assistence would help it move
forward much faster. Having said that, look at whats been achieved by
one guy in a short time.

## Developer Discussion

Github forum is turned on above, you should feel free to discuss the
project there.

## Development philosophy

Schemacs is designed to be as close as possible to real emacs in 
the way it works, not just at the user level but at the code level.
There is very little that departs from the algorithms of emacs.

## History of scheme and emacs

Since 1999, many in the Scheme community have dreamed of an Emacs
freed from elisp and built on a more solid foundation of Scheme. Off
and on the [guile-emacs](https://guile-emacs.org/) project started,
stopped and failed. What went wrong? The plan was to integrate guile,
a scheme implementation, with Emacs as phase 1. Slowly turn the emacs
C code into foreign function calls as phase 2. Then presumably
eliminate the C code entirely as phase 3. The project basically failed
in phase 1.

What went wrong? Emacs is not a lisp interpreter with an editor
attached. The C/elisp core is deeply integrated with the basics of the
editor at every level. That means that guile-emacs was constantly
breaking, and constantly needing to be patched, and never got to the
point where it could just replace emacs. Right now the code has been
abandoned since 2015 (apart from a brief flurry of activity a few
years ago), and it doesn't build against emacs, nor would it be easy
to get it to.

In 2023 Ramin started the Gypsum project of an all-scheme emacs
releasing it on
[Codeberg](https://codeberg.org/ramin_hal9001/schemacs) and presenting
it at the EmacsConf 2024, later renaming it to Schemacs. As of late
2026 it is not yet an editor, you can't open files, there is no window
handling, no marks, no kill ring, no undo, no mode line, no faces, no
modes, no minibuffer and none of the commands you would recognise as
emacs.

I started this project by taking Ramin's work in progress and trying
to implement the missing bits. After a while I came to the conclusion
there was nothing there that I really wanted or needed and started
from scratch, from the bottom up, and used AI to
duplicate emacs functionality exactly. One thing that's
surprising is how well AI can replace the mess of emacs C code into
a scheme file that does the same thing. 


## Ramin's Schemacs Project Goals

Ramins' project seems fairly clear that he's "not in a hurry" and
doesn't want AI help, which is what this project is. At first I
thought, using his base a starting point with its elisp work was the
way to go. However at his current rate of progress, I don't see
anything coming out of it for a decade. Meanwhile I can port elisp
code to scheme in hours, and ignore the whole thought of elisp
compatibility. 

Myself I am in a hurry...

## Future directions

* "Design is fine, but implementation is everything." - Bill Joy
* "Talk is cheap. Show me the code." — Linus Torvalds (2000)
* "We believe in: rough consensus and running code." - David Clark (1992)
* "Prototypes over process." - Joi Ito, Former director of MIT Media Lab
* "Real artists ship." - Steve Jobs (1983)
* "Status is strictly a function of what you build, not what you claim you can build." — Eric S. Raymond
* "An imperfect solution delivered today is far better than a perfect solution delivered tomorrow." - General George S. Patton

Guile-scheme and Ramin's schemacs has done a lot of great work on
elisp compatibility.  I welcome such work, I encourage such work.

But it has failed since 1999. It is not the future. It seemed logical
in 2024. It seemed like a good idea in 2015. This is 2026 not 1999. AI
can port a large complex elisp project to scheme in less than an hour,
and write all the test cases for you. The code it generates will be
function for function, variable for variable, loop for loop identical
to the original elisp. It will not be tripped up by elispisms like '()
vs nil, nil vs #f, funcall, quoting rules, dynamic binding etc, it
will write its own test harnesses, and it will root out any
errors. After it does it, you typically go through another half hour
of human testing, then it's usually done, finished and wrapped up. The
community has the ability to port all the interesting melpa / elpa
packages to scheme in months, and leave Emacs legacy implementation
behind. I'm not under the delusion that this will all be as stable
as a multi decades code base. But it can get there. Fast.

Those are my delusions of grandeur. People have had Scheme / Emacs
delusions for decades. I'm just another guy with delusions. In
reality, the emacs community is conservative, and slow to
move. However this time it's different. You don't need the whole
community anymore, you just need a small team of motivated people, and
AI tokens. If Schemacs can gain a following, and Emacs releases a new
feature, we can port it in hours, not years. We don't need to be
beholden to the old ways. Software isn't the scarce resource it once
was.

## Why guile? Why not...Chez or...

Mostly because there seems to be more packages and more developer
support around guile, and that helps when you're trying to port a
large complex package.

Also guile is better than it used to be. I've seen figures that it's
about 4x as slow as C++, which is pretty good all things considered.
Chez is 2x, so there's that, but at least it's not 40x like Python :-)
But guile has had a lot of work done making it easier to integrate with 
C libraries.. not that Chez is hard.. it's not really, but guile is
much easier. Also more work has been done to integrate it with elisp...
if that ever comes to anything.

## Departures from real emacs

For the most part, schemacs is extremely similar to real emacs in its
implementation. One of the few things different is that Schemacs internally
represents a UTF-32 array which is much easier to deal with and saves
tens of thousands of lines of cruft compared to emacs, which attempts
to have fully variable sized code sizes. The interface is fully hidden
in the text-buffer interface, and later I will optimise it to chunk so
that it uses the minimal memory as possible. If you have just one
emoji in a large file, only one chunk will be utf-32. For now it just
plain makes the whole thing a lot easier to deal with as a fixed sized
array. This is 2026 where memory is important but not *that*
important. There may be other departures, but they are very
small. Small enough that AI conversion of elisp packages should be
*very* smooth.

### Prerequisites

## C Requirements

- `libglib`
- `libgio`
- `libgdk`
- `libgtk3`
- `ncurses`

## Guile Requirements

- [Guile 3](https://www.gnu.org/software/guile)

- [Guile-GI](https://github.com/spk121/guile-gi) must be built and
  installed in a directory path that is listed in the `%load-path`.

- [Guile-Cairo](https://www.nongnu.org/guile-cairo/) must be built
  and installed in a directory path that is listed in the `%load-path`
  (Note, last I checked the Arch AUR guile-cairo is too old.)
  
- [Guile-Ncurses](https://www.gnu.org/software/guile-ncurses/) must be built and
  installed in a directory path that is listed in the `%load-path`.


## How to install

`make install-local` to install in your local directory.
`make install` to install globally.

### Running it

  `bin/se` - the Scheme Editor, or if you like the Scheme Emacs. 

  `-w`/`--window` starts the Gtk UI. Default is the terminal UI.
  
  `--chdir=DIR` changes directory before starting
  
  `-h` prints the usage.

  `-q`/`--no-init-file` skips the init file. 
  
  `--server[=PORT]` runs server mode. Editor starts normally, but can now use --repl
  
  `--repl[=PORT]` connects to a *running* editor with a REPL and 
  starts no editor of its own
  
  `-r`/`--remote[=PORT] FILE...` is `emacsclient` itself it hands the 
  file names to a running editor's `find-file`, so they open in 
  that editor, and starts no editor.

  Starting with no file arguments shows the **startup screen**, a file
  splash.txt on your load-path. q to quit it.
  
  Can be disabled in your init.scm
```
      (import (schemacs editor startup))
      (set! inhibit-startup-screen #t)
```

It looks for an init file in:
* $XDG_CONFIG_HOME/schemacs/init.scm
* $HOME/.config/schemacs/init.scm
* $HOME/.schemacs

### (Optional) use Guix

The `manifest_guile-gi.scm` file is provided to install development
dependencies into your local Guix installation. Use it in one of two
ways.

 1. The first way is to use the `guix shell` command, which keeps
    package dependencies locally and temporarily (until you run the
    Guix garbage collector). The full command is this:

    ```sh
      guix shell -m ./manifest_guile-gi.scm -- guile
    ```

 2. The second way is to installing packages in a local profile
    directory.  Python programmers may find this workflow more
    familiar, as it is similar to using a Python `venv` or "virtual
    environment", except the package directory is `./.guix-profile`
    rather than `.venv`.

    ```sh
      guix package -p ./.guix-profile -m ./manifest_guile-gi.scm -i ;
      guix shell -p ./.guix-profile -- guile -L "${PWD}" ;
    ```

    And then, when you see the Guile REPL prompt `scheme@(guile-user)>`
    you can [run the Scheme programs](#how-to-run).

    Furthermore, the `guix shell` command can use the profile
    directory, and the package dependencies installed into the profile
    directory will survive Guix garbage collections.


