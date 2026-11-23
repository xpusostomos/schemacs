(define-library (schemacs external omarchy omarchy)
  ;; A port of omarchy.el - Emacs integration for Omarchy Linux - by
  ;; Ovidiu Stoica (https://github.com/ovistoica/omarchy.el), kept under
  ;; `schemacs/external/' because it is not part of Emacs proper.
  ;;
  ;; It keeps this editor's theme and default face in step with Omarchy
  ;; through the `omarchy-*' command-line tools, offers pickers over the
  ;; system's theme and font lists, and wraps common Omarchy toggles.
  ;;
  ;; **The departures from the Elisp, all forced by this tree's shape:**
  ;;
  ;;   * `call-process` here goes through `/bin/sh -c` (see
  ;;     `callproc.sld`), so the command line is shell-quoted. The
  ;;     Objective is the same; the mechanism differs from the C's
  ;;     `execvp`;
  ;;   * the shell hook `omarchy-install-hooks` writes calls the shared
  ;;     `repl` client - `repl -e "(omarchy-apply-theme NAME)"` - where
  ;;     the Elisp writes `emacsclient -e`. There is no `server.el` in
  ;;     this tree; the equivalent is the back door, and the server
  ;;     check becomes a check for the `repl` client;
  ;;   * `daemonp` is always nil here (`startup.sld`), so `omarchy-init`
  ;;     always takes the immediate-sync branch and the
  ;;     `server-after-make-frame-hook` deferral is not exercised;
  ;;   * theme variables this tree has no binding for are recorded on
  ;;     the theme's stack and not applied (`theme.sld` says so); the
  ;;     one a theme sets is `frame-background-mode`, registered in
  ;;     `faces.sld`;
  ;;   * the bundled themes are transcribed from Modus's expansion
  ;;     (`tools/convert-omarchy-themes.py`), not generated here.

  (import (scheme base)
          (scheme write)
          (only (guile) format getenv)
          (only (schemacs custom) define-custom)
          (only (schemacs command) define-command)
          (only (schemacs minibuffer) completing-read read-string)
          (only (schemacs subr)
                with-temp-buffer split-string replace-regexp-in-string
                string-replace shell-quote-argument string-trim intern
                error-message-string)
          ;; `downcase` is casefiddle.c's; `display-graphic-p` and
          ;; `system-type` are the frame and process facts `omarchy-init`
          ;; branches on.
          (only (schemacs casefiddle) downcase)
          (only (schemacs frame)
                display-graphic-p selected-frame frame-list
                with-selected-frame)
          (only (schemacs simple) string-empty-p)
          (only (schemacs core seq) seq-remove seq-find)
          (only (schemacs callproc) call-process)
          (only (schemacs files)
                executable-find make-directory with-temp-file)
          (only (schemacs fileio)
                expand-file-name file-name-directory-part set-file-modes)
          (only (schemacs font) font-family-list)
          (only (schemacs faces) set-face-attribute face-attribute)
          (only (schemacs startup) daemonp system-type)
          (only (schemacs core warnings) display-warning)
          (only (schemacs buffer)
                buffer-file-name current-buffer default-directory
                set!buffer-default-directory with-current-buffer)
          (only (schemacs editfns) insert message buffer-string)
          (only (schemacs theme)
                load-theme disable-theme *custom-enabled-themes*)
          ;; Imported for its *effect*: it puts this package's themes/
          ;; directory on `custom-theme-load-path`, which Emacs gets from
          ;; `omarchy-themes.el`'s autoloaded `when load-file-name` block.
          (schemacs external omarchy omarchy-themes))

  (export
   *omarchy-default-theme* *omarchy-default-font* *omarchy-theme-map*
   *omarchy-font-height* *omarchy-fallback-font-height*
   *omarchy-hooks-directory* *omarchy-hook-dropin-name*
   omarchy-available-p omarchy-current-theme omarchy-current-font
   omarchy-list-themes omarchy-list-fonts
   omarchy-set-theme omarchy-set-font
   omarchy-apply-theme omarchy-apply-font
   omarchy-theme-pick omarchy-font-pick
   omarchy-toggle-nightlight omarchy-toggle-bar omarchy-screenshot
   omarchy-lock-screen omarchy-terminal-at-cwd
   omarchy-install-hooks omarchy-init)

  (begin

    ;;--------------------------------------------------------------
    ;; Customization - `omarchy.el`'s `defcustom`s. A defcustom is a
    ;; special variable, so per the tree's convention it is a parameter
    ;; and its name carries the asterisks; the default values are the
    ;; Elisp's.
    ;;--------------------------------------------------------------

    (define-custom *omarchy-default-theme* #f
      "Fallback Emacs theme symbol when Omarchy is unavailable or lookup fails.
Set this to a theme that is guaranteed to be loadable in your config."
      :type '(choice (const :tag "None" nil) symbol)
      :group 'environment)

    (define-custom *omarchy-default-font* "Iosevka Nerd Font Mono"
      "Fallback font family name when Omarchy reports no current font."
      :type 'string
      :group 'environment)

    (define-custom *omarchy-font-height* #f
      "Height of the `default' face applied together with the Omarchy font.
An integer in units of 1/10 point (120 means 12pt).  When nil, changing
the font family leaves the size already in effect untouched."
      :type '(choice (const :tag "Keep current height" nil) integer)
      :group 'environment)

    (define-custom *omarchy-fallback-font-height* 110
      "Height (in 1/10 pt) used when the current `default' face height is unusable.
Only consulted when `omarchy-font-height' is nil and the height in effect is
below `omarchy--min-sane-font-height'.  11pt matches the size Omarchy's own
terminal configs use."
      :type 'integer
      :group 'environment)

    (define-custom *omarchy-theme-map*
      '(("Catppuccin" . catppuccin-mocha)
        ("Catppuccin Latte" . catppuccin-latte)
        ("Ethereal" . ethereal)
        ("Everforest" . everforest)
        ("Flexoki Light" . flexoki-light)
        ("Gruvbox" . gruvbox)
        ("Hackerman" . hackerman)
        ("Jade Horse" . jade-horse)
        ("Kanagawa" . kanagawa)
        ("Last Horizon" . last-horizon)
        ("Lumon" . lumon)
        ("Lupine" . lupine)
        ("Matte Black" . matte-black)
        ("Miasma" . miasma)
        ("Nord" . nord)
        ("Osaka Jade" . osaka-jade)
        ("Retro 82" . retro-82)
        ("Ristretto" . ristretto)
        ("Rose Pine" . rose-pine)
        ("Solitude" . solitude)
        ("Starship" . starship)
        ("Tokyo Night" . tokyo-night)
        ("Vantablack" . vantablack)
        ("White" . white))
      "Map an Omarchy theme name to an Emacs theme symbol or a thunk.
Keys are the exact display names reported by `omarchy-theme-list'.
Values are either a theme symbol loaded via `load-theme`, or a thunk
called for its side effects (useful when a theme needs setup such as
a flavor variable before loading).

All bundled themes in the default value are provided by this package
and derived from Modus via `modus-themes-theme`, so they ship with
full Magit/Org/Eglot/tree-sitter coverage out of the box.

`Jade Horse` and `Starship` are not in omarchy.el at all; those two are
generated from Omarchy's own `colors.toml` by
`tools/convert-omarchy-colors.scm`, which is a generic derivation
rather than a hand-tuned scheme (see the file header there). A theme
Omarchy adds can be given the same treatment and one line added here."
      :type '(alist :key-type string :value-type sexp)
      :group 'environment)

    (define-custom *omarchy-hooks-directory*
      (expand-file-name "omarchy/hooks"
                        (or (getenv "XDG_CONFIG_HOME")
                            (expand-file-name "~/.config")))
      "Directory where Omarchy looks for `theme-set` and `font-set` hooks."
      :type 'directory
      :group 'environment)

    (define-custom *omarchy-hook-dropin-name* "60-schemacs"
      "Filename for the drop-in scripts written by `omarchy-install-hooks`.
Installed into the `theme-set.d` and `font-set.d` directories beneath
`omarchy-hooks-directory`.  Omarchy runs drop-ins in shell glob order,
so the numeric prefix decides when Emacs is notified relative to other
drop-ins.  Names ending in `.sample` are ignored by Omarchy.

**The name is `60-schemacs` and not `omarchy.el`'s `50-emacs`**, which
is the departure this file makes and the reason for it: that name is
already written by the upstream Elisp's own `omarchy-install-hooks`,
which forwards to `emacsclient`.  Installing under it would replace a
real Emacs's theme hook with one that reaches this editor instead, and
then a theme change would update one and not the other.  A separate
name lets the two live side by side."
      :type 'string
      :group 'environment)

    ;;--------------------------------------------------------------
    ;; Predicates - `omarchy.el`'s `omarchy--available` and its cache,
    ;; `defvar`s there and plain variables here for the same reason:
    ;; they are `setq`ed and never `let`-bound.
    ;;--------------------------------------------------------------

    (define omarchy--available #f)
    (define omarchy--available-cached #f)

    (define (omarchy-available-p)
      "Return non-nil if Omarchy CLIs are available on this system."
      (unless omarchy--available-cached
        (set! omarchy--available
              (and (eq? system-type 'gnu/linux)
                   (executable-find "omarchy-theme-current")
                   #t))
        (set! omarchy--available-cached #t))
      omarchy--available)

    ;;--------------------------------------------------------------
    ;; Shell helpers
    ;;--------------------------------------------------------------

    (define (omarchy--run program . args)
      "Run PROGRAM with ARGS synchronously and return trimmed stdout, or nil.
Returns nil if PROGRAM is not on PATH."
      (when (executable-find program)
        (with-temp-buffer
          (let ((exit (apply call-process program #f #t #f args)))
            (when (eq? exit 0)
              (let ((out (string-trim (buffer-string))))
                (unless (string-empty-p out) out)))))))

    (define (%join-strings strings separator)
      (let loop ((rest strings) (out ""))
        (if (null? rest)
            out
            (loop (cdr rest)
                  (if (string=? out "")
                      (car rest)
                      (string-append out separator (car rest)))))))

    (define (omarchy--run-async program . args)
      "Run PROGRAM with ARGS fully detached from Emacs.
A `setsid`-wrapped shell is used so that child processes the script
backgrounds (e.g. the Omarchy shell) survive after the script exits."
      (if (executable-find program)
          (let ((cmd (%join-strings
                      (map (lambda (a) (shell-quote-argument a))
                           (cons program args))
                      " ")))
            (call-process "setsid" #f 0 #f "sh" "-c"
                          (string-append cmd
                                         " </dev/null >/dev/null 2>&1 &")))
          (message "omarchy: %s not found on PATH" program)))

    ;;--------------------------------------------------------------
    ;; State queries
    ;;--------------------------------------------------------------

    (define (omarchy-current-theme)
      "Return the theme name currently selected in Omarchy, or nil."
      (omarchy--run "omarchy-theme-current"))

    (define (omarchy-current-font)
      "Return the font family currently selected in Omarchy, or nil."
      (omarchy--run "omarchy-font-current"))

    (define (omarchy--split-lines s)
      "Split S on newlines, dropping empty entries."
      (when s
        (seq-remove string-empty-p (split-string s "\n"))))

    (define (omarchy-list-themes)
      "Return the list of Omarchy theme names."
      (omarchy--split-lines (omarchy--run "omarchy-theme-list")))

    (define (omarchy-list-fonts)
      "Return the list of Omarchy font family names."
      (omarchy--split-lines (omarchy--run "omarchy-font-list")))

    ;;--------------------------------------------------------------
    ;; System-modifying
    ;;--------------------------------------------------------------

    (define-command (omarchy-set-theme name)
      "Ask Omarchy to switch the system theme to NAME.
Omarchy broadcasts the change to its own hooks; if the theme-set hook
calls back into Emacs via emacsclient, `omarchy-apply-theme` will run
once.  Do not call `omarchy-apply-theme` from here."
      (interactive (list (completing-read "Omarchy theme: "
                                          (omarchy-list-themes) #f #t)))
      (omarchy--run-async "omarchy-theme-set" name))

    (define-command (omarchy-set-font name)
      "Ask Omarchy to switch the system font to NAME."
      (interactive (list (completing-read "Omarchy font: "
                                          (omarchy-list-fonts) #f #t)))
      (omarchy--run-async "omarchy-font-set" name))

    ;;--------------------------------------------------------------
    ;; Font helpers - `omarchy.el`'s, added upstream with the daemon
    ;; font-size fix: "never take the default face height from a
    ;; non-graphical frame" (a selected frame under `emacs --daemon' can
    ;; be the hidden terminal frame, whose `:height' is 1).
    ;;--------------------------------------------------------------

    (define omarchy--min-sane-font-height 20)
    ;; ^ `(defconst omarchy--min-sane-font-height 20)': smallest
    ;; `default' face `:height' (in 1/10 pt) treated as usable.  Anything
    ;; below 2pt is unreadable and almost certainly a customization spec
    ;; copied off a non-graphical frame.  A constant, so a plain define.

    (define omarchy--warned-unusable-height #f)
    ;; ^ `(defvar omarchy--warned-unusable-height nil)': non-nil once
    ;; `omarchy--warn-unusable-height' has fired this session.  It is
    ;; `setq'ed and never `let'-bound, which is a plain variable here.

    (define omarchy--pending-font #f)
    ;; ^ `(defvar omarchy--pending-font nil)': `(FONT . HEIGHT)' waiting
    ;; for a graphical frame to be applied to.  Set by
    ;; `omarchy-apply-font' when no graphical frame exists and consumed
    ;; by `omarchy--apply-pending-font'.  A plain variable, for the same
    ;; reason.

    (define (omarchy--graphic-frame)
      "Return a graphical frame, preferring the selected one, or nil."
      ;; `*window-system*' is one value for the process - an editor runs
      ;; one front end - so every frame agrees, and the search can only
      ;; repeat the first test's answer.  The Elisp's two branches are
      ;; kept anyway.
      (if (display-graphic-p)
          (selected-frame)
          (seq-find display-graphic-p (frame-list))))

    (define (omarchy--sane-height-p height)
      "Return non-nil if HEIGHT is a usable `default' face `:height'."
      (and (integer? height) (>= height omarchy--min-sane-font-height)))

    (define (omarchy--warn-unusable-height height)
      "Warn once per session that the `default' face height HEIGHT is unusable."
      (unless omarchy--warned-unusable-height
        (set! omarchy--warned-unusable-height #t)
        (display-warning
         'omarchy
         (format #f
                 "The `default' face height is ~s, which is unusable; using ~a instead.
This usually means `set-frame-font' was called with a FRAMES argument
before any graphical frame existed (for example from init.el under
`emacs --daemon'), which records a customization copied from the hidden
terminal frame.  Set the font with `set-face-attribute' or
`default-frame-alist' instead, or customize `omarchy-font-height' or
`omarchy-fallback-font-height'."
                 height (*omarchy-fallback-font-height*))
         ':warning)))

    (define (omarchy--resolve-font-height frame . optional)
      "Return the `default' face height to apply on FRAME.
HEIGHT wins when non-nil, then `omarchy-font-height', then the height
currently in effect on FRAME when it is usable.  Otherwise warn and
return `omarchy-fallback-font-height'.  Always returns an integer."
      (let ((height (and (pair? optional) (car optional))))
        (or height
            (*omarchy-font-height*)
            (let ((current (face-attribute 'default ':height frame)))
              (if (omarchy--sane-height-p current)
                  current
                  (begin
                    (omarchy--warn-unusable-height current)
                    (*omarchy-fallback-font-height*)))))))

    (define (omarchy--apply-pending-font)
      "Apply `omarchy--pending-font' once a graphical frame is available.
Meant for `server-after-make-frame-hook'; removes itself after running."
      ;; Emacs registers this on `server-after-make-frame-hook' and
      ;; removes it when it runs.  This tree has no daemon and no such
      ;; hook (and no `add-hook' - a hook here is a parameter holding a
      ;; list), so nothing calls it; `omarchy-apply-font''s deferral
      ;; branch records the value and stops there.
      (when (and omarchy--pending-font (display-graphic-p))
        (let ((pending omarchy--pending-font))
          (set! omarchy--pending-font #f)
          (omarchy-apply-font (car pending) (cdr pending)))))

    (define (omarchy--repair-default-height)
      "Restore a usable `default' face height if a theme load clobbered it.
`load-theme' re-applies the `default' face's customization spec, which
may carry an unusable height (see `omarchy--warn-unusable-height')."
      (let ((frame (omarchy--graphic-frame)))
        (when (and frame
                   (not (omarchy--sane-height-p
                         (face-attribute 'default ':height frame))))
          (set-face-attribute 'default #f
                              ':height (omarchy--resolve-font-height frame)))))

    ;;--------------------------------------------------------------
    ;; Apply to Emacs only (entry points for the shell hooks)
    ;;--------------------------------------------------------------

    (define (omarchy--raw-load-theme theme)
      "Disable all enabled themes, then load THEME with `no-confirm`."
      (for-each disable-theme (*custom-enabled-themes*))
      (load-theme theme #t))

    (define (omarchy--lookup-theme name)
      "Look up NAME in `omarchy-theme-map`, case-insensitively and
with `-` <-> ` ` equivalence.  Return the mapping value, or nil."
      (let ((norm (lambda (s)
                    (downcase
                     (replace-regexp-in-string "[-_ ]+" " " s)))))
        (let ((cell (seq-find (lambda (cell)
                                (string=? (norm (car cell)) (norm name)))
                              (*omarchy-theme-map*))))
          (and cell (cdr cell)))))

    (define-command (omarchy-apply-theme theme-spec)
      "Apply THEME-SPEC to Emacs.
THEME-SPEC may be a string (looked up in `omarchy-theme-map`; if absent,
treated as a bare theme name and `intern`ed), a symbol (loaded
directly), or a function (called for side effects).  Afterwards restore
a usable `default' face height, since loading a theme can re-apply an
unusable one (see `omarchy--repair-default-height`)."
      (interactive (list (read-string "Theme: ")))
      (let ((handler (if (string? theme-spec)
                         (or (omarchy--lookup-theme theme-spec)
                             (intern theme-spec))
                         theme-spec)))
        (guard (err (else
                     (message "omarchy: failed to load theme %s: %s"
                              theme-spec
                              (error-message-string err))
                     (when (*omarchy-default-theme*)
                       (omarchy--raw-load-theme (*omarchy-default-theme*)))))
          (cond
           ((procedure? handler) (handler)
            (message "Theme set to %s" theme-spec))
           ((symbol? handler) (omarchy--raw-load-theme handler)
            (message "Theme set to %s" handler))))
        ;; The Elisp's `omarchy--repair-default-height' runs after the
        ;; `condition-case', so a failed load repairs too.
        (omarchy--repair-default-height)))

    (define-command (omarchy-apply-font font . optional)
      "Set the Emacs default face family to FONT at HEIGHT.
HEIGHT defaults to `omarchy-font-height'; when both are nil the height
already in effect on a graphical frame is preserved, so changing the
family never changes the size.  The size is never taken from a
non-graphical frame (such as the daemon's hidden terminal frame): when
no graphical frame exists the change is deferred until the first client
frame attaches.  No-op when FONT is not in `font-family-list`."
      (interactive (list (read-string "Font: ")))
      (let ((height (and (pair? optional) (car optional)))
            (frame (omarchy--graphic-frame)))
        (cond
         ((not frame)
          (set! omarchy--pending-font (cons font height))
          ;; The Elisp adds `omarchy--apply-pending-font' to
          ;; `server-after-make-frame-hook' here.  This tree has no
          ;; daemon and no such hook, so there is nothing to add it to;
          ;; the value is recorded and the branch stops.  Named, not
          ;; papered over.
          #f)
         ((not (and font (member font (font-family-list frame)))) #f)
         (else
          ;; `set-face-attribute' acts on the *selected* frame, so the
          ;; graphical one is selected for the call - the Elisp's
          ;; `with-selected-frame'.
          (with-selected-frame frame
            (set-face-attribute 'default #f
                                ':font font
                                ':height (omarchy--resolve-font-height
                                          frame height)))
          (message "Font set to %s" font)))))

    ;;--------------------------------------------------------------
    ;; Interactive pickers
    ;;--------------------------------------------------------------

    (define-command (omarchy-theme-pick)
      "Pick a theme from the Omarchy list and apply it system-wide.
On non-Omarchy systems, apply directly to Emacs via
`omarchy-apply-theme` on the picked name."
      (interactive)
      (if (omarchy-available-p)
          (omarchy-set-theme
           (completing-read "Omarchy theme: " (omarchy-list-themes) #f #t))
          (omarchy-apply-theme
           (completing-read "Theme: "
                            (map car (*omarchy-theme-map*)) #f #t))))

    (define-command (omarchy-font-pick)
      "Pick a font from the Omarchy list and apply it system-wide.
On non-Omarchy systems, apply directly to Emacs."
      (interactive)
      (if (omarchy-available-p)
          (omarchy-set-font
           (completing-read "Omarchy font: " (omarchy-list-fonts) #f #t))
          (omarchy-apply-font (read-string "Font: "
                                           (*omarchy-default-font*)))))

    ;;--------------------------------------------------------------
    ;; Quick toggles / commands
    ;;--------------------------------------------------------------

    (define-command (omarchy-toggle-nightlight)
      "Toggle the Omarchy night-light filter."
      (interactive)
      (omarchy--run-async "omarchy-toggle-nightlight"))

    (define-command (omarchy-toggle-bar)
      "Toggle visibility of the Omarchy shell bar.
Does not kill the shell itself."
      (interactive)
      (omarchy--run-async "omarchy-toggle-bar"))

    (define-command (omarchy-screenshot)
      "Invoke the Omarchy screenshot command."
      (interactive)
      (omarchy--run-async "omarchy-capture-screenshot"))

    (define-command (omarchy-lock-screen)
      "Lock the screen via Omarchy."
      (interactive)
      (omarchy--run-async "omarchy-system-lock"))

    (define-command (omarchy-terminal-at-cwd)
      "Open a terminal in the current buffer's directory via Omarchy."
      (interactive)
      ;; `(let ((default-directory ...)) ...)` in the Elisp. This tree's
      ;; `default-directory` is buffer-local storage read by a function,
      ;; not a parameter, so the dynamic binding is written out - and
      ;; the *old* value is the one restored.
      (let* ((buffer (current-buffer))
             (old (default-directory))
             (dir (or (and (buffer-file-name)
                           (file-name-directory-part (buffer-file-name)))
                      old)))
        (dynamic-wind
          (lambda () (set!buffer-default-directory buffer dir))
          (lambda () (omarchy--run-async "omarchy-cmd-terminal-cwd"))
          (lambda () (set!buffer-default-directory buffer old)))))

    ;;--------------------------------------------------------------
    ;; Shell hook installation
    ;;--------------------------------------------------------------

    (define omarchy--hook-script-template
      "#!/usr/bin/env bash
# %s
# Managed by schemacs' omarchy port - safe to edit, but
# `M-x omarchy-install-hooks' will overwrite this file.  Omarchy
# invokes the script with the new %s as $1; forward that to the
# editor's back door.
#
# WHICH EDITORS.  $SCHEMACS_INSTANCE when the session exports one,
# otherwise every live schemacs back door.  This is a deliberate
# departure from `omarchy.el', which uses plain `emacsclient' and so
# reaches the one Emacs that owns the server socket: this tree allows
# several editors at once, the first answering to `schemacs' and the
# rest to `schemacs-<pid>', and an Omarchy theme belongs to the whole
# desktop.  Delivering to all of them is also what makes a restart not
# matter - an older editor still holding the unsuffixed name is not
# mistaken for the one the user is looking at.
#
# `repl -l' lists what ANSWERS, one line per endpoint, so the filter
# below selects this program's instances whatever they are called.
#
# **NO TILDE CHARACTER MAY APPEAR IN THIS TEXT.** The template is a
# Guile `format' string: a tilde is a directive, and one that is not
# (awk's match operator, in the first version) makes the formatter
# abort with no message at all. The command that writes these files
# died silently until this comment existed.

CALLED=\"$1\"

if command -v repl >/dev/null 2>&1; then
    if [ -n \"$SCHEMACS_INSTANCE\" ]; then
        NAMES=$SCHEMACS_INSTANCE
    else
        NAMES=$(repl -l 2>/dev/null | grep '/schemacs/' | cut -d' ' -f1)
    fi

    for NAME in $NAMES; do
        repl -e \"(%s \\\"$CALLED\\\")\" \"$NAME\" >/dev/null 2>&1
    done
fi
")

    (define (omarchy--hook-script-text description arg-name fn)
      ;; `(format omarchy--hook-script-template description arg-name fn)`
      ;; in the Elisp - Guile's `format` with the template's `%s`
      ;; spellings translated to `~a`, its "next argument" directive.
      ;;--------------------------------------------------------------
      (format #f (string-replace "%s" "~a" omarchy--hook-script-template)
              description arg-name fn))

    (define (omarchy--write-hook hook-name description arg-name fn)
      "Write a drop-in for HOOK-NAME that calls FN via the back door.
The script is created as `omarchy-hook-dropin-name` inside the
HOOK-NAME.d directory beneath `omarchy-hooks-directory`.  Omarchy runs
every non-`.sample` file in that directory, so installing here leaves
any user-managed HOOK-NAME file untouched.

DESCRIPTION is the first comment line; ARG-NAME labels the argument.
Creates the directory if needed and makes the script executable.
Returns the full path written."
      (let* ((dropin-dir (expand-file-name (string-append hook-name ".d")
                                           (*omarchy-hooks-directory*)))
             (path (expand-file-name (*omarchy-hook-dropin-name*) dropin-dir)))
        (make-directory dropin-dir #t)
        (with-temp-file path
          (insert (omarchy--hook-script-text description arg-name fn)))
        (set-file-modes path #o755)
        path))

    (define-command (omarchy-install-hooks)
      "Install shell hook scripts that forward Omarchy theme/font changes to Emacs.
Writes two executable drop-ins under `omarchy-hooks-directory`, each
named `omarchy-hook-dropin-name`:

  theme-set.d/  calls `omarchy-apply-theme` with the new theme name.
  font-set.d/   calls `omarchy-apply-font`  with the new font name.

Omarchy runs every non-`.sample` file in these directories in addition
to any plain `theme-set`/`font-set` script, so your own hooks are left
alone.  Overwrites only our own drop-ins.  Returns the paths written.

Emits a warning if the back door client `repl` is not on PATH - the
scripts depend on reaching a live editor.  Start the editor with
`--server` (or `SCHEMACS_REPL=1`) so that it has a door."
      (interactive)
      ;; `(bound-and-true-p server-process)` in the Elisp: what has to be
      ;; running here is the `repl` client, and whether *this* editor has
      ;; its door open is `SCHEMACS_REPL`'s business at start time, not
      ;; something a running editor can be asked.
      (unless (executable-find "repl")
        (display-warning
         'omarchy
         "the `repl` client is not on PATH - the installed hooks need it.
Start the editor with --server (or SCHEMACS_REPL=1) so it has a back
door, and install the shared scheme-utils `repl` client."
         ':warning))
      (let ((theme-hook (omarchy--write-hook
                         "theme-set"
                         "Omarchy theme-set hook for Emacs integration"
                         "theme name" "omarchy-apply-theme"))
            (font-hook (omarchy--write-hook
                        "font-set"
                        "Omarchy font-set hook for Emacs integration"
                        "font family" "omarchy-apply-font")))
        (message "omarchy: installed hooks in %s" (*omarchy-hooks-directory*))
        (list theme-hook font-hook)))

    ;;--------------------------------------------------------------
    ;; Entry point
    ;;--------------------------------------------------------------

    (define (omarchy--sync-from-system)
      "Apply the current Omarchy font and theme to Emacs.
Safe to call only once a display connection exists (otherwise
`omarchy-apply-font` will silently skip)."
      (let ((font (omarchy-current-font)))
        (when font (omarchy-apply-font font)))
      (let ((theme (omarchy-current-theme)))
        (when theme (omarchy-apply-theme theme))))

    (define (omarchy--daemon-first-frame-sync)
      "Run `omarchy--sync-from-system` once a graphical frame attaches.
Kept for the Elisp's shape; `daemonp` is always nil here, so
`omarchy-init` never installs it."
      (when (display-graphic-p)
        (omarchy--sync-from-system)))

    (define-command (omarchy-init)
      "Initialize Omarchy integration.
On non-Omarchy systems apply `omarchy-default-theme` and return.
In daemon mode defer the sync until the first graphical frame attaches.
Otherwise sync immediately."
      (interactive)
      (cond
       ((not (omarchy-available-p))
        (when (*omarchy-default-theme*)
          (omarchy--raw-load-theme (*omarchy-default-theme*))))
       ((and (daemonp) (not (display-graphic-p)))
        ;; No `server-after-make-frame-hook` here; `daemonp` is nil, so
        ;; this branch is unreachable and is kept for the Elisp's shape.
        #f)
       (else
        (omarchy--sync-from-system))))))
