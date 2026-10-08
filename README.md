# Project Schemacs

#### A clone of Emacs and Emacs Lisp written in R7RS Scheme

### Project State

It works!!! It's complete enough that you could daily use it as an editor. 
And it's 100% written in scheme.

Here's what works already:
* Both terminal and Gtk pixel based implementations
* Buffers, and buffer manipulation commands
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

## How to build

As of right now, this project only runs on Guile Scheme, although
certain libraries (`lens.sld`, `pretty."Design is fine, but
implementation is everything."sld`, `keymap.sld`) can build and run on
other Schemes. The only GUI available right now is for
[Guile-GI](https://github.com/spk121/guile-gi), but the Editor is
designed specifically to be able to run on other Scheme platforms with
other GUI toolkits. All platform specific calls are parameterized.

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
implementation.  Ironically, Ramin was aiming for elisp compatibility
which requires uber compatibility, but I abandoned that code base
partly because I felt it actually departed too much from real
emacs. One of the few things different is that Schemacs internally
represents a UTF-32 array which is much easier to deal with and saves
tens of thousands of lines of cruft compared to emacs, which attempts
to have fully variable sized code sizes. The interface is fully hidden
in the text-buffer interface, and later I will optimise it to chunk so
that it uses the minimal memory as possible. If you have just one
emoji in a large file, only one chunk will be utf-32. For now it just
plain makes the whole thing a lot easier to deal with as a fixed sized
array. This is 2026 where memory is important but not *that*
important. There may be other departures, but they are very
small. Small enough that AI conversion of your packages should be
smooth... *very* smooth.


### Running it

There is one script in the top level:

* se - the Scheme Editor, or if you like the Scheme Emacs. It reads a
  command line of its own (`schemacs/main.scm`, through SRFI 37's
  `args-fold`): the terminal editor is the default, `-w`/`--window` starts
  the Gtk one, `--chdir=DIR` (or `--chdir DIR`) changes directory before
  starting, and `-h` prints the usage.

  `-q`/`--no-init-file` skips the init file. `--server[=PORT]` opens the
  development back door (see AGENTS.md), and `--repl[=PORT]` connects to a
  *running* editor's back door as a REPL and starts no editor of its own -
  `emacsclient` the other way round. `-r`/`--remote[=PORT] FILE...` is
  `emacsclient` itself: it hands the file names to a running editor's
  `find-file`, so they open in that editor, and starts no editor here
  (with no file it prints the usage line and stops). An optional argument
  is attached: `--server=37146`, not `--server 37146`.

  Starting with no file arguments shows the **startup screen**, the way
  GNU Emacs does: the text of a `splash.txt` found on the load path - the
  tree ships one at `schemacs/splash.txt`, and a `splash.txt` of your own
  in any load-path directory wins over it. It is a read-only buffer and
  `q` leaves it. With file arguments the frame is split and the splash is
  the *lower* window, again as in Emacs. An init file can turn it off with
  Emacs's own spelling:

      (set! inhibit-startup-screen #t)

Right now I'm using Wayland, I presume the graphics will work on X11
but haven't tried it.

It looks for an init file in:
* $XDG_CONFIG_HOME/schemacs/init.scm
* $HOME/.config/schemacs/init.scm
* $HOME/.schemacs

### Scheme Requirements

- [Guile 3](https://www.gnu.org/software/guile)

- [Guile-GI](https://github.com/spk121/guile-gi) must be built and
  installed in a directory path that is listed in the `%load-path`.

### C Requirements for Guile-GI

- `libglib`
- `libgio`
- `libgdk`
- `libgtk3`

[Guile 3](https://www.gnu.org/software/guile) usually installs from
source using `autotools` on any Linux or BSD operating system provided
the above developer dependency packages are installed. Installing with
`autotools` installs all Guile modules in the site-local package
directory. If you install it this way, the modules are always
available to your Guile runtime without needing to set the Guile
`%load-path`.

### (Optional) use Guix

The `manifest_guile-gi.scm` file is provided to install development
dependencies into your local Guix installation. Use it in one of two
ways.

 1. The first way is to use the `guix shell` command, which keeps
    package dependencies locally and temporarily (until you run the
    Guix garbage collector). The full command is this:

    ```sh
      guix shell -m ./manifest_guile-gi.scm -- guile --r7rs ;
    ```

 2. The second way is to installing packages in a local profile
    directory.  Python programmers may find this workflow more
    familiar, as it is similar to using a Python `venv` or "virtual
    environment", except the package directory is `./.guix-profile`
    rather than `.venv`.

    ```sh
      guix package -p ./.guix-profile -m ./manifest_guile-gi.scm -i ;
      guix shell -p ./.guix-profile -- guile --r7rs -L "${PWD}" ;
    ```

    And then, when you see the Guile REPL prompt `scheme@(guile-user)>`
    you can [run the Scheme programs](#how-to-run).

    Furthermore, the `guix shell` command can use the profile
    directory, and the package dependencies installed into the profile
    directory will survive Guix garbage collections.

### Launch the Guile REPL using `./guile.sh`

The `guile.sh` script sets environment variables and command line
parameters for the Guile runtime, it is usually easier to simply
execute this script to start the REPL.

Emacs users can set the directory-local variable `geiser-guile-binary`
to `"./guile.sh"`. The `.dir-locals.el` file in this repository does
this for you if you choose to use it.

#### (optional) Launch `guile.sh` in a Guix Shell

If you are using Guix Shell according to the steps in the section ["(Optional) Use Guix"](#optional-use-guix), you can run the `guile.sh` script like so:

```sh
guix shell -p ./.guix-profile -- sh ./guile.sh
```

## How to run

Once you have a Guile Scheme REPL running and you can see the
`scheme@(guile-user)>` prompt, and you are sure the Guile-GI
dependencies available in the `%load-path`, simply load the main
program into the REPL:

```scheme
(load "./main-gui.scm")
```

This will rebuild and launch the executable. If you are using the
`./guile.sh` script to start the REPL, note that the
`--fresh-auto-compile` flag is set, and so recompilation will occur
every time `main-gui.scm` is loaded. If you are not hacking the
Schemacs source code, feel free to delete this flag from the
`guile.sh` script file so that `load` only builds the application
once, and launches the application more quickly.

### Double-check the Guile `%load-path`

If you evaluate `,pp %load-path` in the `scheme@(guile-user)>` REPL,
the load path should look something like this:

```
scheme@(guile-user)> ,pp %load-path
$1 = ("/home/user/work-src/schemacs"
 "/usr/share/guile/3.0"
 "/usr/share/guile/site/3.0"
 "/usr/share/guile/site"
 "/usr/share/guile")
```

### Double-check the Guile `%load-path` in a Guix Shell

If you evaluate `,pp %load-path` in the `scheme@(guile-user)>` REPL
that was launched within a Guix Shell, the load path should look
similar to this, although likely with different hash codes in the
`/gnu/store`:

```
scheme@(guile-user)> ,pp %load-path
$1 = ("/home/user/work-src/schemacs"
 "/gnu/store/ylbycmajc0sf1pndfnsfql76cr1097iq-profile/share/guile/site/3.0"
 "/gnu/store/jqrkacxgsaf7b19xqzc2x4d77v27dbc6-guile-3.0.8/share/guile/3.0"
 "/gnu/store/jqrkacxgsaf7b19xqzc2x4d77v27dbc6-guile-3.0.8/share/guile/site/3.0"
 "/gnu/store/jqrkacxgsaf7b19xqzc2x4d77v27dbc6-guile-3.0.8/share/guile/site"
 "/gnu/store/jqrkacxgsaf7b19xqzc2x4d77v27dbc6-guile-3.0.8/share/guile")
```

## How to hack

Start a Scheme REPL as described above, but instead of running the
main program or the `./elisp-tests.scm` program, instead run the test
suite:

```scheme
(load "./run-tests.scm")
```

Unlike the `./elisp-tests.scm` program, the `./run-tests.scm` ensures
the exported symbols in each library all behave as expected. Before
you change anything, make sure you keep a log of which tests have
passed and which have failed, if any.

Whenever you make a change to the source code of a Scheme library, be
sure to run the tests for that library. The tests in `./run-tests.scm`
require your Scheme implementation to provide
[SRFI-64](https://srfi.schemers.org/srfi-64/srfi-64.html), without
this language extension (sorry, MIT Scheme users) you will have to run
each test case by hand by copy-pasting each test form into your REPL.

Keep in mind that this project is still experimental, it is possible
some of the tests may not pass. As long as you create a pull request
with equal or fewer passing tests, your request is more likely to be
pulled into the main branch.

That said, `./schemacs/lens.scm` and `./schemacs/keymap.scm` should always
pass all tests, as these libraries are most essential to the rest of
the application.

