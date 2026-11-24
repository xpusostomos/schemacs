(define-library (schemacs paren)
  ;; This library mirrors GNU Emacs's `lisp/paren.el' - `show-paren-mode',
  ;; the idle-timer highlight of the matching paren - **and the paren
  ;; blinking block of `simple.el'** (`blink-matching-open' and its
  ;; caller). The blink block is a placement departure: Emacs keeps it in
  ;; `simple.el', but it needs `forward-sexp' (lisp.el), `font-lock-ensure'
  ;; (font-lock.el), `minibuffer-message' (minibuffer.el),
  ;; `pos-visible-in-window-p' (xdisp.c) and the show-paren variables -
  ;; every one of them above `simple.scm' in this tree's import graph.
  ;; `paren.scm' is above all of them, so the block lives here and
  ;; `electric-pair--insert''s `(let ((blink-matching-paren nil)))' binds a
  ;; variable some code finally reads.
  ;;
  ;; **`blink-matching-paren' itself stays in `simple.scm'**, where
  ;; `simple.el' declares it (elec-pair binds it below this library); the
  ;; four other blink options are here with the block that reads them, as
  ;; the same file would have them.
  ;;
  ;; **Not carried, each with what it needs**:
  ;;
  ;;  * `show-paren-context-when-offscreen' set to `child-frame' - child
  ;;    frames (`parent-frame', `redirect-frame-focus', `set-frame-size',
  ;;    `set-frame-position', `make-frame-visible') are not ported. The
  ;;    function signals a clear error instead of building a normal frame.
  ;;  * ... set to `overlay' - the overlay and its face are built, but
  ;;    this renderer does not draw an overlay's `display' string; the
  ;;    value is accepted and named in DEPARTURES.md.
  ;;  * `show-paren--context-child-frame-buffer', `-parameters' and
  ;;    `-redirect-focus' - all child-frame machinery.
  ;;  * `visible-bell'`s screen flash: the backends ring rather than
  ;;    flash (`dispnew.scm`).
  ;;
  ;; **The two overlays are made lazily** where Emacs makes them at load:
  ;; a library here can be loaded before any buffer exists, and
  ;; `make-overlay' needs one. The names and the faces are Emacs's.

  (import
    (scheme base)
    (scheme char)
    (only (guile) catch throw logand)
    (only (srfi srfi-1) last-pair)
    (only (schemacs core timer) cancel-timer run-with-idle-timer)
    (only (schemacs core easy-mmode) define-minor-mode)
    (only (schemacs core derived) buffer-match-p)
    (only (schemacs custom)
          define-custom custom-initialize-default)
    (only (schemacs command)
          define-command current-prefix-arg uarg->integer
          *last-command-event*)
    (only (schemacs data) default-value set-default)
    (only (schemacs buffer)
          current-buffer buffer-local-value set-buffer-local-value!
          local-variable-p kill-local-variable
          make-overlay delete-overlay move-overlay overlay-put overlay-get)
    (only (schemacs editfns)
          point point-min point-max goto-char bobp bolp eolp
          char-after char-before buffer-substring propertize
          line-beginning-position line-end-position
          save-excursion save-restriction narrow-to-region
          message)
    (only (schemacs minibuffer)
          minibufferp minibuffer-message minibuffer-prompt-end)
    (only (schemacs syntax)
          syntax-ppss syntax-propertize syntax-after syntax-class
          char-syntax parse-partial-sexp scan-sexps ppss-comment-depth
          syntax-ppss-context skip-chars-forward skip-chars-backward
          skip-syntax-backward *parse-sexp-ignore-comments*)
    (only (schemacs core lisp) forward-sexp)
    (only (schemacs font-lock) font-lock-ensure)
    (only (schemacs textprop) add-face-text-property)
    (only (schemacs faces) face-attribute)
    (only (schemacs frame)
          selected-window window-start delete-frame *post-command-hook*)
    (only (schemacs dispnew)
          beep noninteractive executing-kbd-macro)
    (only (schemacs subr)
          add-hook remove-hook replace-regexp-in-string)
    (only (schemacs simple)
          *blink-matching-paren* back-to-indentation default-font-height)
    (only (schemacs keyboard) sit-for)
    (only (schemacs fns) mapconcat nth)
    (only (schemacs xdisp)
          pos-visible-in-window-p *message-log-max*)
    (only (schemacs cmds)
          end-of-line forward-char *post-self-insert-hook*))

  (export
   ;; paren.el
   *show-paren-style* *show-paren-delay* *show-paren-priority*
   *show-paren-ring-bell-on-mismatch*
   *show-paren-when-point-inside-paren*
   *show-paren-when-point-in-periphery*
   *show-paren-highlight-openparen* *show-paren-context-when-offscreen*
   *show-paren-not-in-comments-or-strings* *show-paren-predicate*
   show-paren--overlay show-paren--overlay-1 show-paren--idle-timer
   show-paren--delete-overlays show-paren--unescaped-p
   show-paren--categorize-paren show-paren--locate-near-paren
   show-paren--snap show-paren--default show-paren-data-function
   set!show-paren-data-function
   show-paren--context-child-frame
   show-paren--delete-context-child-frame
   show-paren--show-context-in-child-frame
   show-paren--delete-context-overlay show-paren--show-context-in-overlay
   show-paren--last-pos show-paren--enabled-p show-paren-function
   show-paren-mode show-paren-mode-hook show-paren-mode-value
   show-paren-local-mode show-paren-local-mode-hook
   ;; simple.el's blink block
   *blink-matching-paren-on-screen* *blink-matching-paren-distance*
   *blink-matching-delay* *blink-matching-paren-dont-ignore-comments*
   *blink-matching-paren-highlight-offscreen*
   blink-matching-check-function blink-matching-check-mismatch
   blink-paren-open-paren-line-string blink-matching--overlay
   blink-matching-open *blink-paren-function*
   blink-paren-post-self-insert-function)

  (begin

    ;;----------------------------------------------------------------
    ;; The blink block of `simple.el' (`simple.el:9517-9780')
    ;;----------------------------------------------------------------

    (define-custom *blink-matching-paren-on-screen* #t
      "Non-nil means show matching open-paren when it is on screen.
If nil, don't show it (but the open-paren can still be shown
in the echo area when it is off screen).

This variable has no effect if `blink-matching-paren' is nil.
\\(In that case, the open-paren is never shown.)
It is also ignored if `show-paren-mode' is enabled."
      :type 'boolean
      :group 'paren-blinking)

    (define-custom *blink-matching-paren-distance* (* 100 1024)
      "If non-nil, maximum distance to search backwards for matching open-paren.
If nil, search stops at the beginning of the accessible portion of the buffer."
      :version "23.2"
      :type '(choice (const nil) integer)
      :group 'paren-blinking)

    (define-custom *blink-matching-delay* 1
      "Time in seconds to delay after showing a matching paren."
      :type 'number
      :group 'paren-blinking)

    (define-custom *blink-matching-paren-dont-ignore-comments* #f
      "If nil, `blink-matching-paren' ignores comments.
More precisely, when looking for the matching parenthesis,
it skips the contents of comments that end before point."
      :type 'boolean
      :group 'paren-blinking)

    (define-custom *blink-matching-paren-highlight-offscreen* #f
      "If non-nil, highlight matched off-screen open paren in the echo area.
This highlighting uses the `blink-matching-paren-offscreen' face."
      :type 'boolean
      :version "30.1"
      :group 'paren-blinking)

    (define (blink-matching-check-mismatch start end)
      "Return whether or not START...END are matching parens.
END is the current point and START is the blink position.
START might be nil if no matching starter was found.
Returns non-nil if we find there is a mismatch."
      (let* ((end-syntax (syntax-after (- end 1)))
             (matching-paren (and (pair? end-syntax)
                                  (eqv? (syntax-class end-syntax) 5)
                                  (cdr end-syntax))))
        ;; For self-matched chars like " and $, we can't know when
        ;; they're mismatched or unmatched, so we can do it only for
        ;; parens.
        (if matching-paren
            (not (and start
                      (or (let ((c (char-after start)))
                            (and c (eqv? (char->integer c) matching-paren)))
                          ;; The cdr might hold a new paren-class info
                          ;; rather than a matching-char info, in which
                          ;; case the two CDRs should match.
                          (let ((s (syntax-after start)))
                            (and (pair? s)
                                 (eqv? matching-paren (cdr s)))))))
            #f)))

    (define blink-matching-check-function #f)
    ;; ^ GNU Emacs's `blink-matching-check-function' (`simple.el:9612'),
    ;; a defvar holding the function. A Scheme binding cannot hold a
    ;; *symbol* that resolves to a procedure (there is no function
    ;; obarray), so it holds the procedure itself.
    (set! blink-matching-check-function blink-matching-check-mismatch)

    (define blink-matching--overlay #f)
    ;; ^ GNU Emacs's `blink-matching--overlay' (`simple.el:9619'). Emacs
    ;; creates it at load; this tree loads libraries before there need be
    ;; a current buffer, so it is made on first use
    ;; (`%blink-matching--ensure-overlay').

    (define (%blink-matching--ensure-overlay)
      (unless blink-matching--overlay
        (let ((ol (make-overlay (point) (point) #f #t)))
          (overlay-put ol 'face 'show-paren-match)
          (delete-overlay ol)
          (set! blink-matching--overlay ol)))
      blink-matching--overlay)

    (define-command (blink-matching-open)
      "Momentarily highlight the beginning of the sexp before point."
      (interactive)
      (when (and (not (bobp))
                 (*blink-matching-paren*))
        ;; Don't log messages about paren matching.
        (parameterize ((*message-log-max* #f))
          (let* ((oldpos (point))
                 (blinkpos
                  (save-excursion
                    (save-restriction
                      (syntax-propertize (point))
                      (if (*blink-matching-paren-distance*)
                          (narrow-to-region
                           (max (minibuffer-prompt-end) ;(point-min) unless minibuf.
                                (- (point) (*blink-matching-paren-distance*)))
                           oldpos))
                      (parameterize
                          ((*parse-sexp-ignore-comments*
                            (and (*parse-sexp-ignore-comments*)
                                 (not (*blink-matching-paren-dont-ignore-comments*)))))
                        (guard (e (else #f))
                          (forward-sexp -1)
                          ;; backward-sexp skips backward over prefix
                          ;; chars, so move back to the matching paren.
                          (let loop ()
                            (when (and (< (point) (- oldpos 1))
                                       (let ((code (syntax-after (point))))
                                         (or (eqv? (syntax-class code) 6)
                                             (eqv? (logand 1048576 (car code))
                                                   1048576))))
                              (forward-char 1)
                              (loop)))
                          (point))))))
                 (mismatch (blink-matching-check-function blinkpos oldpos)))
            (cond
             (mismatch
              (if blinkpos
                  (if (minibufferp)
                      (minibuffer-message "Mismatched parentheses")
                      (message "Mismatched parentheses"))
                  (if (minibufferp)
                      (minibuffer-message "No matching parenthesis found")
                      (message "No matching parenthesis found"))))
             ((not blinkpos) #f)
             ((or (eq? (*blink-matching-paren*) 'jump-offscreen)
                  (pos-visible-in-window-p blinkpos))
              ;; Matching open within window, temporarily move to or
              ;; highlight char after blinkpos but only if
              ;; `blink-matching-paren-on-screen' is non-nil.
              (and (*blink-matching-paren-on-screen*)
                   (not (show-paren-mode-value))
                   (if (memq (*blink-matching-paren*) '(jump jump-offscreen))
                       (save-excursion
                         (goto-char blinkpos)
                         (sit-for (*blink-matching-delay*)))
                       (dynamic-wind
                        (lambda () #f)
                        (lambda ()
                          (move-overlay (%blink-matching--ensure-overlay)
                                        blinkpos (+ blinkpos 1)
                                        (current-buffer))
                          (sit-for (*blink-matching-delay*)))
                        (lambda ()
                          (delete-overlay blink-matching--overlay))))))
             ((not (*show-paren-context-when-offscreen*))
              (minibuffer-message
               "~a~a"
               (propertize "Matches " 'face 'shadow)
               (blink-paren-open-paren-line-string blinkpos)))
             (else #f))))))

    (define (blink-paren-open-paren-line-string pos . rest)
      "Return the line string that contains the openparen at POS.
LEN is the length of the multi-character paren, by default 1.
Remove the line string's properties but give the openparen a distinct
face if `blink-matching-paren-highlight-offscreen' is non-nil."
      (let ((len (or (and (pair? rest) (car rest)) 1)))
        (save-excursion
          (goto-char pos)
          ;; Capture the regions in terms of (beg . end) conses whose
          ;; buffer-substrings we want to show as a context string.
          ;; Ensure they are font-locked (bug#59527).
          (let ((regions #f) (openparen-idx #f))
            (cond
             ;; Show what precedes the open in its line, if anything.
             ((save-excursion (skip-chars-backward " \t") (not (bolp)))
              (let ((bol (line-beginning-position)))
                (set! regions (list (cons bol (+ pos len))))
                (set! openparen-idx (- pos bol))))
             ;; Show what follows the open in its line, if anything.
             ((save-excursion
                (forward-char len)
                (skip-chars-forward " \t")
                (not (eolp)))
              (set! regions (list (cons pos (line-end-position))))
              (set! openparen-idx 0))
             ;; Otherwise show the previous nonblank line, if there is one.
             ((save-excursion (skip-chars-backward "\n \t") (not (bobp)))
              (let ((beg (begin (skip-chars-backward "\n \t")
                                (let ((bol (line-beginning-position)))
                                  (set! openparen-idx (- bol))
                                  bol)))
                    (end (begin (end-of-line)
                                (skip-chars-backward " \t")
                                (let ((eol (point)))
                                  (set! openparen-idx
                                        (+ openparen-idx eol 3)) ; (length "...")
                                  eol))))
                (set! regions (list (cons beg end)
                                    (cons pos (+ pos len))))))
             ;; There is nothing to show except the char itself.
             (else
              (set! regions (list (cons pos (+ pos len))))
              (set! openparen-idx 0)))
            ;; Ensure we've font-locked the context region.
            (font-lock-ensure (car (car regions))
                              (cdr (last-pair regions)))
            (let ((line-string
                   (mapconcat
                    (lambda (region)
                      (buffer-substring (car region) (cdr region)))
                    regions
                    "...")))
              (when (*blink-matching-paren-highlight-offscreen*)
                (add-face-text-property openparen-idx (+ openparen-idx len)
                                        'blink-matching-paren-offscreen
                                        #f line-string))
              line-string)))))

    (define *blink-paren-function* (make-parameter #f))
    ;; ^ GNU Emacs's `blink-paren-function' (`simple.el:9755'): the
    ;; function called when a close paren is inserted. **A parameter**,
    ;; because `cc-cmds.el` `let`-binds it around an insert it wants to
    ;; handle itself (the tree's convention: a dynamically bound
    ;; variable is a parameter, and its name carries the stars). It holds
    ;; the procedure rather than the symbol Emacs resolves through the
    ;; obarray; the default is set after the definition it names.
    (*blink-paren-function* blink-matching-open)

    (define (blink-paren-post-self-insert-function)
      (when (and (let ((c (char-before)))
                   (and c (eqv? (char->integer c) (*last-command-event*))))
                 (memq (char-syntax (*last-command-event*)) (list #\) #\$))
                 (*blink-paren-function*)
                 (not executing-kbd-macro)
                 (not noninteractive)
                 ;; Verify an even number of quoting characters precede
                 ;; the close. FIXME: also check if this parenthesis
                 ;; closes a comment as can happen in Pascal and SML.
                 (odd? (- (point)
                          (save-excursion
                            (forward-char -1)
                            (skip-syntax-backward "/\\")
                            (point)))))
        ((*blink-paren-function*))))

    ;; **The hook `simple.el' installs when it loads** (`:9777'): the
    ;; function appended, with a `priority' of 100 (the `put' at `:9775')
    ;; because it can `sit-for' and so runs after the other
    ;; post-self-insert entries.
    (add-hook *post-self-insert-hook*
              blink-paren-post-self-insert-function
              100)

    ;;----------------------------------------------------------------
    ;; show-paren (`lisp/paren.el')
    ;;----------------------------------------------------------------

    (define-custom *show-paren-style* 'parenthesis
      "Style used when showing a matching paren.
Valid styles are `parenthesis' (meaning show the matching paren),
`expression' (meaning show the entire expression enclosed by the paren) and
`mixed' (meaning show the matching paren if it is visible, and the expression
otherwise)."
      :type '(choice (const parenthesis) (const expression) (const mixed))
      :group 'paren-showing)

    (define-custom *show-paren-delay* 0.125
      "Time in seconds to delay before showing a matching paren.
If you change this without using customize while `show-paren-mode' is
active, you must toggle the mode off and on again for this to take effect."
      :type '(number :tag "seconds")
      :initialize custom-initialize-default
      :set (lambda (symbol value)
             (if (not (show-paren-mode-value))
                 (*show-paren-delay* value)
                 (begin
                   (show-paren-mode -1)
                   (*show-paren-delay* value)
                   (show-paren-mode 1))))
      :group 'paren-showing)

    (define-custom *show-paren-priority* 1000
      "Priority of paren highlighting overlays."
      :type 'integer
      :version "21.1"
      :group 'paren-showing)

    (define-custom *show-paren-ring-bell-on-mismatch* #f
      "If non-nil, beep if mismatched paren is detected."
      :type 'boolean
      :version "20.3"
      :group 'paren-showing)

    (define-custom *show-paren-when-point-inside-paren* #f
      "If non-nil, show parens when point is just inside one.
This will only be done when point isn't also just outside a paren."
      :type 'boolean
      :version "25.1"
      :group 'paren-showing)

    (define-custom *show-paren-when-point-in-periphery* #f
      "If non-nil, show parens when point is in the line's periphery.
The periphery is at the beginning or end of a line or in any
whitespace there."
      :type 'boolean
      :version "25.1"
      :group 'paren-showing)

    (define-custom *show-paren-highlight-openparen* #t
      "Non-nil turns on openparen highlighting when matching forward.
When nil, and point stands just before an open paren, the paren
is not highlighted, the cursor being regarded as adequate to mark
its position."
      :type 'boolean
      :group 'paren-showing)

    (define-custom *show-paren-context-when-offscreen* #f
      "If non-nil, show context around the opening paren if it is offscreen.
The context is usually the line that contains the openparen,
except if the openparen is on its own line, in which case the
context includes the previous nonblank line.

By default, the context is shown in the echo area.

If set to the symbol `overlay', the context is shown in an
overlay at the top-left of the window.

If set to the symbol `child-frame', the context is shown in a
child frame at the top-left of the window.  You might want to
customize the `child-frame-border' face (especially the
background color) to give the child frame a distinguished border.
On non-graphical frames, the context is shown in the echo area.

Note that `blink-matching-paren-highlight-offscreen' can have an
influence on the fontification of the opening offscreen paren."
      :type '(choice (const :tag "Off" nil)
                     (const :tag "In echo area" t)
                     (const :tag "In overlay" overlay)
                     (const :tag "In child-frame" child-frame))
      :version "29.1"
      :group 'paren-showing)

    (define-custom *show-paren-not-in-comments-or-strings* #f
      "If non-nil, do not highlight the parens inside comments and strings.
If set to `all', never highlight parens inside comments and strings.
If set to `on-mismatch', do not highlight mismatched parens inside
comments and strings.
If set to nil (the default), always highlight parens wherever they are."
      :type '(choice
              (const :tag "Never highlight parens in comments and strings" all)
              (const
               :tag "Don't highlight mismatched parens in comments and strings"
               on-mismatch)
              (const :tag "Always highlight parens" nil))
      :version "31.1"
      :group 'paren-showing)

    (define show-paren--idle-timer #f)
    ;; ^ GNU Emacs's `show-paren--idle-timer' (`paren.el:110').

    (define show-paren--overlay #f)
    (define show-paren--overlay-1 #f)
    ;; ^ GNU Emacs's two overlay defvars (`paren.el:111' and `:114').
    ;; Emacs creates them at load; this tree may load before a buffer
    ;; exists, so `%show-paren--ensure-overlays' makes them on first use.
    ;; The names are the C's; the descriptions are in the defvars' doc
    ;; strings there.

    (define (%show-paren--ensure-overlays)
      (unless show-paren--overlay
        (let ((ol (make-overlay (point) (point) #f #t)))
          (delete-overlay ol)
          (set! show-paren--overlay ol)))
      (unless show-paren--overlay-1
        (let ((ol (make-overlay (point) (point) #f #t)))
          (delete-overlay ol)
          (set! show-paren--overlay-1 ol)))
      #t)

    (define-custom *show-paren-predicate*
      '(not (derived-mode . special-mode))
      "Whether to use `show-paren-mode' in a buffer.
The default is to enable the mode in all buffers that don't
derive from `special-mode', which means that it's on (by default)
in all editing buffers.
The predicate is passed as argument to `buffer-match-p', which see."
      :type 'buffer-predicate
      :version "29.1"
      :group 'paren-showing)

    (define (show-paren-mode-value)
      ;; The value of `show-paren-mode' in the current buffer. Emacs
      ;; reads the variable, which a buffer-local binding wins over the
      ;; global default; this tree's global mode keeps its state in
      ;; `default-value' and `show-paren-local-mode' writes the
      ;; buffer-local slot, so this is that read.
      ;;--------------------------------------------------------------
      (let ((buffer (current-buffer)))
        (if (and buffer (local-variable-p 'show-paren-mode buffer))
            (buffer-local-value buffer 'show-paren-mode #f)
            (default-value 'show-paren-mode #f))))

    (define (show-paren--delete-overlays)
      (when show-paren--overlay (delete-overlay show-paren--overlay))
      (when show-paren--overlay-1 (delete-overlay show-paren--overlay-1))
      #f)

    (define (show-paren--unescaped-p pos)
      "Determine whether the paren after POS is unescaped."
      (save-excursion
        (goto-char pos)
        (= (logand (skip-syntax-backward "/\\") 1) 0)))

    (define (show-paren--categorize-paren pos)
      "Determine whether the character after POS has paren syntax,
and if so, return a cons (DIR . OUTSIDE), where DIR is 1 for an
open paren, -1 for a close paren, and OUTSIDE is the buffer
position of the outside of the paren.  If the character isn't a
paren, or it is an escaped paren, return nil."
      (cond
       ((and (eqv? (syntax-class (syntax-after pos)) 4)
             (show-paren--unescaped-p pos))
        (cons 1 pos))
       ((and (eqv? (syntax-class (syntax-after pos)) 5)
             (show-paren--unescaped-p pos))
        (cons -1 (+ pos 1)))
       (else #f)))

    (define (show-paren--locate-near-paren)
      "Locate an unescaped paren \"near\" point to show.
If one is found, return the cons (DIR . OUTSIDE), where DIR is 1
for an open paren, -1 for a close paren, and OUTSIDE is the buffer
position of the outside of the paren.  Otherwise return nil."
      (let* ((ind-pos (save-excursion (back-to-indentation) (point)))
             (eol-pos
              (save-excursion
                (end-of-line) (skip-chars-backward " \t" ind-pos) (point)))
             (before (show-paren--categorize-paren (- (point) 1)))
             (after (show-paren--categorize-paren (point))))
        (cond
         ;; Point is immediately outside a paren.
         ((and (pair? before) (eqv? (car before) -1)) before)
         ((and (pair? after) (eqv? (car after) 1)) after)
         ;; Point is immediately inside a paren.
         ((and (*show-paren-when-point-inside-paren*) before) before)
         ((and (*show-paren-when-point-inside-paren*) after) after)
         ;; Point is in the whitespace before the code.
         ((and (*show-paren-when-point-in-periphery*)
               (<= (point) ind-pos))
          (or (show-paren--categorize-paren ind-pos)
              (show-paren--categorize-paren (- eol-pos 1))))
         ;; Point is in the whitespace after the code.
         ((and (*show-paren-when-point-in-periphery*)
               (>= (point) eol-pos))
          (show-paren--categorize-paren (- eol-pos 1)))
         (else #f))))

    ;; GNU Emacs's `show-paren-data-function' (`paren.el:245') is a
    ;; `defvar' that modes `setq-local' (treesit.el, html-ts-mode): the
    ;; global value is the default function and a buffer's own slot wins.
    ;; It holds the *procedure* here, not the symbol Emacs's obarray
    ;; resolves - the reason `blink-matching-check-function' does.
    (define (show-paren-data-function)
      (let ((buffer (current-buffer)))
        (if (and buffer (local-variable-p 'show-paren-data-function buffer))
            (buffer-local-value buffer 'show-paren-data-function #f)
            show-paren--default)))

    (define (set!show-paren-data-function value)
      (set-buffer-local-value! (current-buffer)
                               'show-paren-data-function value))

    (define (show-paren--snap pos)
      "Return the first position at or after POS that is not mid-string/comment."
      (save-excursion
        (let ((ppss (syntax-ppss pos)))
          (if (not (or (list-ref ppss 3) (list-ref ppss 4)))
              pos
              (guard (e (else pos))
                (parse-partial-sexp pos (point-max) #f #f
                                    ppss 'syntax-table)
                (point))))))

    (define (show-paren--default)
      "Find the opener/closer near point and its match.

It is the default value of `show-paren-data-function'."
      (let* ((temp (show-paren--locate-near-paren))
             (dir (and (pair? temp) (car temp)))
             (outside (and (pair? temp) (cdr temp)))
             ;; If we're inside a comment, then we probably want to blink
             ;; a matching parentheses in the comment.  So don't ignore
             ;; comments in that case.
             (*parse-sexp-ignore-comments*
              (if (ppss-comment-depth (syntax-ppss))
                  #f
                  (*parse-sexp-ignore-comments*))))
        (let ((pos #f) (mismatch #f) (here-beg #f) (here-end #f))
          ;;
          ;; Find the other end of the sexp.
          (if (not dir)
              #f
              (begin
                (set! here-beg (if (eqv? dir 1) outside (- outside 1)))
                (set! here-end (if (eqv? dir 1) (+ outside 1) outside))
                (save-restriction
                  ;; Determine the range within which to look for a match.
                  (when (*blink-matching-paren-distance*)
                    (let ((beg
                           (min (point)
                                (show-paren--snap
                                 (max (point-min)
                                      (- (point) (*blink-matching-paren-distance*)))))))
                      ;; `syntax-propertize' can't widen so make sure it
                      ;; won't need to (bug#81035).
                      (syntax-propertize beg)
                      (narrow-to-region
                       beg
                       (min (point-max)
                            (+ (point) (*blink-matching-paren-distance*))))))
                  ;; Scan across one sexp within that range.
                  ;; Errors or nil mean there is a mismatch.
                  (guard (e (else (set! pos #t) (set! mismatch #t)))
                    (set! pos (scan-sexps outside dir)))
                  ;; Move back the other way and verify we get back to the
                  ;; starting point.  If not, these two parens don't really
                  ;; match.  Maybe the one at point is escaped and doesn't
                  ;; really count, or one is inside a comment.
                  (when (integer? pos)
                    (unless (guard (e (else #f))
                              (eqv? outside (scan-sexps pos (- dir))))
                      (set! pos #f)))
                  ;; If found a "matching" paren, see if it is the right
                  ;; kind of paren to match the one we started at.
                  (if (not (integer? pos))
                      (if mismatch (list here-beg here-end #f #f #t) #f)
                      (let ((beg (min pos outside)) (end (max pos outside)))
                        (unless (eqv? (syntax-class (syntax-after beg)) 8)
                          (set! mismatch
                                (not (or
                                      ;; This can give nil.
                                      (let ((c (char-before end))
                                            (s (syntax-after beg)))
                                        (and c (pair? s) (cdr s)
                                             (eqv? (char->integer c) (cdr s))))
                                      ;; This can give nil.
                                      (let ((c (char-after beg))
                                            (s (syntax-after (- end 1))))
                                        (and c (pair? s) (cdr s)
                                             (eqv? (char->integer c) (cdr s))))
                                      ;; The cdr might hold a
                                      ;; new paren-class info rather than
                                      ;; a matching-char info, in which
                                      ;; case the two CDRs should match.
                                      (let ((s1 (syntax-after (- end 1)))
                                            (s2 (syntax-after beg)))
                                        (and (pair? s1) (pair? s2)
                                             (eqv? (cdr s1) (cdr s2))))))))
                        (list here-beg here-end
                              (if (eqv? dir 1) (- pos 1) pos)
                              (if (eqv? dir 1) pos (+ pos 1))
                              mismatch)))))))))

    ;;----------------------------------------------------------------
    ;; The offscreen context display (`paren.el:380-530')
    ;;----------------------------------------------------------------

    (define show-paren--context-child-frame #f)
    ;; ^ GNU Emacs's `show-paren--context-child-frame' (`paren.el:380').

    (define (show-paren--delete-context-child-frame)
      (when show-paren--context-child-frame
        (delete-frame show-paren--context-child-frame)
        (set! show-paren--context-child-frame #f))
      (remove-hook *post-command-hook*
                   show-paren--delete-context-child-frame))

    (define (show-paren--show-context-in-child-frame text)
      "Show TEXT in a child-frame at the top-left of the current window."
      ;; A child frame needs `parent-frame', `redirect-frame-focus',
      ;; `set-frame-size', `set-frame-position', `make-frame-visible' and
      ;; the `show-paren--context-child-frame-parameters' list, none of
      ;; which this tree has; a normal frame would cover the text the
      ;; context is about, so the gap is reported rather than papered
      ;; over with one.
      (error "Child frames are not supported in this editor"))

    ;; GNU Emacs's `show-paren--context-overlay' is a `defvar-local'
    ;; (`paren.el:466'); this tree's buffer-local slots are behind an
    ;; accessor pair.
    (define (show-paren--context-overlay)
      (let ((buffer (current-buffer)))
        (and buffer
             (buffer-local-value buffer 'show-paren--context-overlay #f))))

    (define (set!show-paren--context-overlay value)
      (set-buffer-local-value! (current-buffer)
                               'show-paren--context-overlay value))

    (define (show-paren--delete-context-overlay)
      (let ((overlay (show-paren--context-overlay)))
        (when overlay
          (delete-overlay overlay)
          (set!show-paren--context-overlay #f)))
      ;; The C removes `show-paren--delete-overlays' here, not this
      ;; function - read literally, and the same in Emacs 32's source.
      (remove-hook *post-command-hook* show-paren--delete-overlays #t)
      #f)

    (define (show-paren--show-context-in-overlay text)
      "Show TEXT in an overlay at the top-left of the current window."
      (set! text (replace-regexp-in-string "\n" " " text))
      (show-paren--delete-context-overlay)
      (let* ((beg (window-start (selected-window)))
             (end (save-excursion
                    (goto-char beg)
                    (line-end-position))))
        (set!show-paren--context-overlay (make-overlay beg end)))
      (overlay-put (show-paren--context-overlay) 'display text)
      ;; Use the (default very high) `show-paren-priority' ensuring that
      ;; no other overlays shine through (bug#59527).
      (overlay-put (show-paren--context-overlay)
                   'priority (*show-paren-priority*))
      (overlay-put (show-paren--context-overlay)
                   'face (list ':inherit 'default
                               ':box (list ':line-width (cons 1 -1)
                                            ':color (face-attribute
                                                     'shadow ':foreground))))
      (add-hook *post-command-hook* show-paren--delete-context-overlay
                #f #t)
      #f)

    ;; The last position of point for which `show-paren-function' was
    ;; called (`paren.el:536'): we track it in order to C-g away a
    ;; context overlay or child-frame without having it pop up again
    ;; after `show-paren-delay'.
    (define (show-paren--last-pos)
      (let ((buffer (current-buffer)))
        (and buffer
             (buffer-local-value buffer 'show-paren--last-pos #f))))

    (define (set!show-paren--last-pos value)
      (set-buffer-local-value! (current-buffer) 'show-paren--last-pos value))

    (define (show-paren--enabled-p)
      (and (show-paren-mode-value)
           ;; If we're using `show-paren-local-mode', then always heed
           ;; the value.
           (or (local-variable-p 'show-paren-mode (current-buffer))
               ;; If not, check that the predicate matches.
               (buffer-match-p (*show-paren-predicate*) (current-buffer)))))

    (define (show-paren-function)
      "Highlight the parentheses until the next input arrives."
      (let ((data (and (show-paren--enabled-p)
                       ;; The variable holds the function (Emacs
                       ;; `funcall's it); the accessor answers its value,
                       ;; which is a procedure, so it is called here.
                       ((show-paren-data-function)))))
        (if (not data)
            (begin
              ;; If show-paren-mode is nil in this buffer or if not at a
              ;; paren that has a match, turn off any previous paren
              ;; highlighting.
              (show-paren--delete-overlays)
              (set!show-paren--last-pos (point)))

            ;; Found something to highlight.
            (catch 'sp-exit
              (lambda ()
                (let* ((here-beg (list-ref data 0))
                       (here-end (list-ref data 1))
                       (there-beg (list-ref data 2))
                       (there-end (list-ref data 3))
                       (mismatch (list-ref data 4))
                       (highlight-expression
                        (or (eq? (*show-paren-style*) 'expression)
                            (and there-beg
                                 (eq? (*show-paren-style*) 'mixed)
                                 (let ((closest (if (< there-beg here-beg)
                                                    (- there-end 1)
                                                    (+ there-beg 1))))
                                   (not (pos-visible-in-window-p closest))))))
                       (face
                        (cond
                         (mismatch
                          (if (and (eq? (*show-paren-not-in-comments-or-strings*)
                                        'on-mismatch)
                                   (save-excursion
                                     (syntax-ppss-context
                                      (syntax-ppss here-beg))))
                              (throw 'sp-exit #f))
                          (if (*show-paren-ring-bell-on-mismatch*)
                              (beep))
                          'show-paren-mismatch)
                         (highlight-expression 'show-paren-match-expression)
                         (else 'show-paren-match))))
                  (if (and (eq? (*show-paren-not-in-comments-or-strings*) 'all)
                           (save-excursion
                             (syntax-ppss-context (syntax-ppss here-beg))))
                      (throw 'sp-exit #f))
                  ;;
                  ;; If matching backwards, highlight the closeparen
                  ;; before point as well as its matching open.
                  ;; If matching forward, and the openparen is unbalanced,
                  ;; highlight the paren at point to indicate misbalance.
                  ;; Otherwise, turn off any such highlighting.
                  (%show-paren--ensure-overlays)
                  (if (or (not here-beg)
                          (and (not (*show-paren-highlight-openparen*))
                               (> here-end (point))
                               (<= here-beg (point))
                               (integer? there-beg)))
                      (delete-overlay show-paren--overlay-1)
                      (begin
                        (move-overlay show-paren--overlay-1
                                      here-beg here-end (current-buffer))
                        ;; Always set the overlay face, since it varies.
                        (overlay-put show-paren--overlay-1 'priority (*show-paren-priority*))
                        (overlay-put show-paren--overlay-1 'face face)))
                  ;;
                  ;; Turn on highlighting for the matching paren, if found.
                  ;; If it's an unmatched paren, turn off any such
                  ;; highlighting.
                  (if (not there-beg)
                      (delete-overlay show-paren--overlay)
                      (begin
                        (if highlight-expression
                            (move-overlay show-paren--overlay
                                          (if (< there-beg here-beg)
                                              here-end
                                              here-beg)
                                          (if (< there-beg here-beg)
                                              there-beg
                                              there-end)
                                          (current-buffer))
                            (move-overlay show-paren--overlay
                                          there-beg there-end
                                          (current-buffer)))
                        ;; If `show-paren-context-when-offscreen' is
                        ;; non-nil and point is at a closing paren, show
                        ;; the context around the opening paren.
                        (let ((openparen (min here-beg there-beg)))
                          (when (and (*show-paren-context-when-offscreen*)
                                     (not (eqv? (show-paren--last-pos)
                                                (point)))
                                     (< there-beg here-beg)
                                     ;; Either OPENPAREN position is
                                     ;; fully visible...
                                     (not (or (pos-visible-in-window-p
                                               openparen)
                                              (let ((dfh4 (* 0.25
                                                             (default-font-height)))
                                                    (part
                                                     (pos-visible-in-window-p
                                                      openparen #f #t)))
                                                ;; ...or partially
                                                ;; visible, and the
                                                ;; invisible part is less
                                                ;; than 1/4th of the
                                                ;; default font height.
                                                (and part
                                                     (>= (length part) 4)
                                                     (< (nth 2 part) dfh4)
                                                     (< (nth 3 part) dfh4))))))
                            (let ((context (blink-paren-open-paren-line-string
                                            openparen
                                            (- there-end there-beg))))
                              (parameterize ((*message-log-max* #f))
                                (cond
                                 ((eq? (*show-paren-context-when-offscreen*)
                                       'child-frame)
                                  (show-paren--show-context-in-child-frame
                                   context))
                                 ((eq? (*show-paren-context-when-offscreen*)
                                       'overlay)
                                  (show-paren--show-context-in-overlay
                                   context))
                                 ((*show-paren-context-when-offscreen*)
                                  (minibuffer-message "Matches ~a"
                                                      context)))))))
                        (set!show-paren--last-pos (point))
                        ;; Always set the overlay face, since it varies.
                        (overlay-put show-paren--overlay 'priority (*show-paren-priority*))
                        (overlay-put show-paren--overlay 'face face)))))
              (lambda (key . args) (and (pair? args) (car args)))))))

    ;; `:init-value t' is Emacs's default: `show-paren-mode' is on in
    ;; the dump. `paren.scm' turns it on at load below, as `electric.scm'
    ;; does for `electric-indent-mode' - with no dump, loading is where
    ;; the same state is made.
    (define-minor-mode show-paren-mode
      "Toggle visualization of matching parens (Show Paren mode).

When enabled, any matching parenthesis is highlighted in `show-paren-style'
after `show-paren-delay' seconds of Emacs idle time.

Also see `show-paren-predicate', which controls which buffers
this mode is enabled in.

This is a global minor mode.  To toggle the mode in a single buffer,
use `show-paren-local-mode'."
      :global #t
      :init-value #t
      :group 'paren-showing
      ;; Enable or disable the mechanism.
      ;; First get rid of the old idle timer.
      (when show-paren--idle-timer
        (cancel-timer show-paren--idle-timer)
        (set! show-paren--idle-timer #f))
      (set! show-paren--idle-timer
            (run-with-idle-timer (*show-paren-delay*) #t
                                 show-paren-function))
      (unless (show-paren-mode-value)
        (show-paren--delete-overlays)))

    (define-minor-mode show-paren-local-mode
      "Toggle `show-paren-mode' only in this buffer."
      :group 'paren-showing
      :variable (lambda () (show-paren--enabled-p))
                (lambda (value)
                  (set-buffer-local-value! (current-buffer)
                                           'show-paren-mode value))
      (cond
       ((eqv? (show-paren-mode-value)
              (default-value 'show-paren-mode #f))
        (unless (show-paren-mode-value)
          (show-paren--delete-overlays)
          (kill-local-variable 'show-paren-mode)))
       ((not (default-value 'show-paren-mode #f))
        ;; Locally enabled, but globally disabled.
        (show-paren-mode 1)                ; Setup the timer.
        (set-default 'show-paren-mode #f)) ; But keep it globally disabled.
       (else ;; Locally disabled only.
        (show-paren--delete-overlays))))

    ;; Emacs is dumped with `show-paren-mode' on; this tree has no dump,
    ;; so loading the library arms the timer.
    (show-paren-mode 1)))
