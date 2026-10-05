(define-library (schemacs editor isearch)
  ;; This library mirrors GNU Emacs's `isearch.el': the incremental
  ;; search - `isearch-forward' (C-s) and `isearch-backward' (C-r), the
  ;; search string as it is typed, the states DEL takes back, and the
  ;; message in the echo area.
  ;;
  ;; It is a command that reads its own keys rather than going through the
  ;; command loop, exactly as Emacs's isearch does: isearch is entered by
  ;; one command and reads keys until a key ends it, so each of its keys
  ;; is handled here rather than dispatched from a keymap.
  ;;
  ;; It publishes `*search-highlight*' (which lives with the display,
  ;; `(schemacs editor xdisp)') so that what it found is drawn - the same
  ;; fact that GNU Emacs records as the `isearch' and `lazy-highlight'
  ;; faces on the match. Keeping those two in step is the one thing here
  ;; that nothing else would notice going wrong, which is why
  ;; `tools/pty-check.py isearch-highlight' exists.
  ;;
  ;; The faces themselves are the display's to merge, and they must be
  ;; merged *over* the face already in effect: in Emacs they arrive as an
  ;; overlay's face and `face_at_buffer_position' merges them with the
  ;; text property's, so a font-locked word inside a match keeps its
  ;; colour. `draw-match' does that merge; a match drawn in the search
  ;; face alone loses the font-lock colour under it, and
  ;; `pgtk-tests.scm'"'"'s "a search match keeps the face colour that was
  ;; under it" is the check that catches it.
  ;;
  ;; See LAYOUT-PLAN.txt for the rule this library is a step of.

  (import
    ;; `kbd' - see `character.sld''s export note for why it is there
    (only (schemacs editor character) kbd)
    (scheme base)
    (scheme char)
    (scheme case-lambda)
    ;; `caddr' and `cadddr' are `(scheme cxr)'s, not `(scheme base)''s.
    ;; Without this the file loads and the failure waits for the first
    ;; search that reads a match: "Unbound variable: caddr" at run time,
    ;; which is the class of bug this project keeps meeting.
    (only (scheme cxr) caddr cadddr)
    ;; isearch reads its keys itself, but through the command loop's read:
    ;; a key is whatever `read-key-event' answers, which is the display's
    ;; event when nothing was pushed back and an event put back on
    ;; `*unread-command-events*' when something was. Reading through it is
    ;; what lets the search give the key that ended it back to the loop.
    (only (schemacs editor keyboard)
          *unread-command-events* read-key-event read-wait-ms)
    ;; `char-alt' is the event model's, in `character.sld': the lowest
    ;; of the six modifier bits, `lisp.h''s `CHAR_ALT', which is the
    ;; boundary between a plain character event and a modified one.
    (only (schemacs editor subr) char-alt)
    ;; `define-key' and the global map: the keys C-s and C-r are stated
    ;; here, beside the commands they run.
    (only (schemacs editor keymap)
         define-key
         *default-keymap*)
    (only (schemacs editor engine)
         set!text-editor-mark string-search-forward text-editor-char-count
         text-editor-copy-string
         text-editor-get-char-index text-editor-get-cursor
         text-editor-point-min text-editor-point-max
         text-editor-search-backward text-editor-search-forward
         text-editor-set-cursor
         ;; what `minibuffer-lazy-highlight-setup' hangs its hook on
         *after-change-functions*
          )
    ;; `minibuffer-lazy-highlight-setup' is isearch.el's and needs the
    ;; minibuffer it watches; no library imports isearch, so it can be
    ;; imported here.
    (only (schemacs editor minibuffer)
          *minibuffer-exit-hook* minibuffer-contents minibufferp)
    ;; `frame-selected-window' and `window-buffer' are the window whose
    ;; matches the lazy highlighter covers, and which it asks for its top
    ;; and bottom - `isearch-lazy-highlight-update''s bounds.
    (only (schemacs editor frame)
         *current-frame* current-editor frame-selected-window
         set!frame-message window-buffer
          )
    (only (schemacs editor command) define-command)
    (only (schemacs editor simple)
         current-kill word-char?
          )
    ;; `render!' redraws after each key; `window-start' and `window-end'
    ;; are the range the lazy highlighter covers - the window, which is
    ;; what GNU Emacs's `lazy-highlight-buffer' nil means.
    (only (schemacs editor xdisp)
         render! window-end window-start)
    ;; The highlight is an *overlay* now - `isearch-highlight' makes one
    ;; and puts the `isearch' face on it - which is GNU Emacs's mechanism
    ;; and the reason a font-locked word keeps its colour inside a match:
    ;; the display merges an overlay's face over the text property's.
    (only (schemacs editor buffer)
          current-buffer delete-overlay make-overlay move-overlay overlay-put)
    )

  (export
   *search-upper-case* isearch-no-upper-case-p
   *search-case-fold?* *search-pattern* isearch isearch-backward isearch-find
   isearch-forward isearch-message isearch-pop-state isearch-pop-to-success
   isearch-repeat isearch-search! isearch-word-at-point
   minibuffer-lazy-highlight-setup
   ;; the highlighting, which `replace.sld' runs for query-replace
   *search-highlight* *isearch-lazy-highlight* *lazy-highlight-cleanup*
   isearch-highlight isearch-dehighlight
   isearch-lazy-highlight-match isearch-lazy-highlight-update
   lazy-highlight-cleanup
   )

  (begin

    ;;----------------------------------------------------------------
    ;; Incremental search
    ;;
    ;; GNU Emacs's `isearch-forward' (C-s) and `isearch-backward' (C-r),
    ;; and mg's isearch(dir): a search that runs again on every key, so
    ;; that the match follows what is being typed. The two references
    ;; agree on the parts that are easy to get wrong, and both were
    ;; checked against the running Emacs:
    ;;
    ;;  - each search runs from the START of the current match, so that
    ;;    extending the pattern re-tries it where the last one began
    ;;    rather than past its end (mg's is_find backs up by the length
    ;;    of the pattern; Emacs reaches the same place by retrying);
    ;;  - point ends at the far end of the match: past it when searching
    ;;    forward, at its start when searching backward. Emacs's
    ;;    `isearch-search-string' says so - "If found, move point to the
    ;;    end of the occurrence" - and mg's forwsrch leaves dot there
    ;;    too;
    ;;  - a search that fails leaves point where it was;
    ;;  - C-s at the last match fails first, and wraps on the NEXT C-s
    ;;    (Emacs's `isearch-wrap-pause' is t by default). mg wraps on the
    ;;    first failing C-s, which is the one place the two differ;
    ;;  - DEL takes back the last thing typed, and C-g while the search
    ;;    is failing takes back characters until it succeeds again; C-g
    ;;    on a successful search abandons it and puts point back where
    ;;    the search started;
    ;;  - leaving the search sets the mark where it started, so there is
    ;;    a way back to it (Emacs's `isearch-done').
    ;;------------------------------------------------------------------

    (define (isearch-message pattern direction success? wrapped? case-fold? point opoint)
      ;; The echo area during a search: GNU Emacs's
      ;; `isearch-message-prefix' followed by the search string. Emacs
      ;; builds the words in lower case and capitalises the first letter,
      ;; so "failing I-search" is shown as "Failing I-search".
      ;;--------------------------------------------------------------
      (let* ((forward? (eq? direction 'forward))
             (over? (and wrapped?
                         (if forward? (< opoint point) (> opoint point))))
             (text (string-append
                    (if success? "" "failing ")
                    (if over? "over" "")
                    (if wrapped? "wrapped " "")
                    (if (and (not success?) (not case-fold?))
                        "case-sensitive " "")
                    (if forward? "I-search" "I-search backward")
                    ": "
                    pattern)))
        (string-append (string-upcase (substring text 0 1))
                       (substring text 1))))

    (define (isearch-find ed pattern direction case-fold? step?)
      ;; Where the search for PATTERN should leave point, or #f when it
      ;; is not found. When STEP? the search starts one character on in
      ;; DIRECTION, which is how a repeated search finds the next match
      ;; instead of the one it is already on (mg's isearch moves a
      ;; character before each repeat).
      ;;--------------------------------------------------------------
      (let* ((forward? (eq? direction 'forward))
             (max (text-editor-point-max ed))
             (point (text-editor-get-cursor ed))
             (len (string-length pattern))
             (start (if step?
                        (if forward? (+ point 1) (- point 1))
                        point)))
        (and (<= (text-editor-point-min ed) start count)
             (let ((from (if forward?
                             (max (text-editor-point-min ed) (- start len))
                             (min count (+ start len)))))
               (if forward?
                   (text-editor-search-forward
                    ed pattern from case-fold?)
                   (text-editor-search-backward
                    ed pattern from case-fold?))))))

    (define (isearch-search! ed pattern direction case-fold?)
      ;; Run the search for PATTERN and move point to the match, the way
      ;; GNU Emacs's `isearch-search' does on every keystroke that
      ;; changes the search string. Reports whether it was found; when it
      ;; was not, point is left where it was.
      ;;--------------------------------------------------------------
      (let ((found (isearch-find ed pattern direction case-fold? #f)))
        (when found (text-editor-set-cursor ed found))
        (and found #t)))

    (define *search-case-fold?*
      ;; Whether the search in progress folds case, GNU Emacs's
      ;; `isearch-case-fold-search'. The renderer needs it as well as the
      ;; pattern, so that it highlights exactly what the search matched.
      ;;--------------------------------------------------------------
      (make-parameter #t))

    (define *search-pattern*
      ;; The search string of the search in progress, or false when there
      ;; is none: what the renderer highlights matches with. GNU Emacs
      ;; keeps the same thing in `isearch-string'.
      ;;--------------------------------------------------------------
      (make-parameter #f))

    (define *search-upper-case*
      ;; GNU Emacs's `search-upper-case' (isearch.el): "If non-nil, an
      ;; upper case character (or REGEXP char) in a search string forces
      ;; case insensitive search." perform-replace consults it with
      ;; `isearch-no-upper-case-p' to decide the search's folding.
      ;;--------------------------------------------------------------
      (make-parameter #t))

    ;;----------------------------------------------------------------
    ;; Highlighting what the search found
    ;;
    ;; GNU Emacs's `isearch-highlight' (isearch.el:4016) and the lazy
    ;; highlighter under it. What the search found is recorded as
    ;; *overlays*: the match point is on gets one carrying the `isearch'
    ;; face and priority 1001, and every other match in the window gets
    ;; one carrying `lazy-highlight' and priority 1000. The display is told
    ;; nothing - it reads those faces like any others, through
    ;; `attrs-at-buffer-position', which merges an overlay's face *over*
    ;; the text property's.
    ;;
    ;; That merge is the point of doing it this way. The previous
    ;; arrangement published the search string to the renderer, which
    ;; searched each drawn row again and painted the match in the search
    ;; face *alone* - so every font-lock face under a match was wiped out
    ;; for as long as the search lasted, and a match spanning a line break
    ;; was not drawn at all (a row-by-row search cannot see one).
    ;;------------------------------------------------------------------

    (define *search-highlight* (make-parameter #t))
    ;; ^ GNU Emacs's `search-highlight' (isearch.el:200), t by default:
    ;; "Non-nil means highlight the current match during search."

    (define *isearch-lazy-highlight* (make-parameter #t))
    ;; ^ GNU Emacs's `isearch-lazy-highlight' (isearch.el:345), t by
    ;; default: "Non-nil means highlight all matches of the current
    ;; search string."

    (define *lazy-highlight-cleanup* (make-parameter #t))
    ;; ^ GNU Emacs's `lazy-highlight-cleanup' (isearch.el:329), t by
    ;; default: "If non-nil, remove lazy highlighting when no search
    ;; string is active."

    (define isearch-overlay (make-parameter #f))
    ;; ^ GNU Emacs's `isearch-overlay': "Overlay for highlighting the
    ;; current match during search."

    (define isearch-lazy-highlight-overlays (make-parameter '()))
    ;; ^ GNU Emacs's `isearch-lazy-highlight-overlays'.

    (define (isearch-highlight beg end)
      ;; GNU Emacs's `isearch-highlight': "Highlight the current match."
      ;; "1001 is higher than lazy's 1000 and ediff's 100+" - the C's own
      ;; note, and the reason the current match wins where a lazy overlay
      ;; covers the same characters. An overlay that already exists is
      ;; *moved* rather than replaced, which is what the C does and keeps
      ;; one overlay alive across a search instead of one per keystroke.
      ;;--------------------------------------------------------------
      (when (*search-highlight*)
        (if (isearch-overlay)
            (move-overlay (isearch-overlay) beg end (current-buffer))
            (let ((overlay (make-overlay beg end)))
              (isearch-overlay overlay)
              (overlay-put overlay 'priority 1001)
              (overlay-put overlay 'face 'isearch)))))

    (define (isearch-dehighlight)
      ;; GNU Emacs's `isearch-dehighlight': "Cancel the current-match
      ;; highlighting."
      ;;--------------------------------------------------------------
      (when (isearch-overlay)
        (delete-overlay (isearch-overlay))
        (isearch-overlay #f)))

    (define (lazy-highlight-cleanup force)
      ;; GNU Emacs's `lazy-highlight-cleanup': "Stop lazy highlighting and
      ;; remove extra highlighting from current buffer. FORCE non-nil means
      ;; do it whether or not `lazy-highlight-cleanup' is nil." The C's
      ;; second argument PROCRASTINATE is its idle-timer bookkeeping and
      ;; has nothing to postpone here - the loop is run when it is asked
      ;; for, not on a timer.
      ;;--------------------------------------------------------------
      (when (or force (*lazy-highlight-cleanup*))
        (for-each delete-overlay (isearch-lazy-highlight-overlays))
        (isearch-lazy-highlight-overlays '())))

    (define (isearch-lazy-highlight-match beg end)
      ;; GNU Emacs's `isearch-lazy-highlight-match`: one overlay per other
      ;; match. "1000 is higher than ediff's 100+, but lower than isearch
      ;; main overlay's 1001" - the C's note again.
      ;;--------------------------------------------------------------
      (let ((overlay (make-overlay beg end)))
        (isearch-lazy-highlight-overlays
         (cons overlay (isearch-lazy-highlight-overlays)))
        (overlay-put overlay 'priority 1000)
        (overlay-put overlay 'face 'lazy-highlight)
        overlay))

    (define (isearch-lazy-highlight-search text pattern from case-fold?)
      ;; GNU Emacs's `isearch-lazy-highlight-search': "Search ahead for the
      ;; next or previous match, for lazy highlighting. Attempt to do the
      ;; search exactly the way the pending Isearch would."
      ;;
      ;; The C searches the *buffer*, with the same search function the
      ;; search itself uses, so a regexp search highlights regexp matches.
      ;; Here the caller has already copied out the window - one copy for
      ;; the whole pass, see `isearch-lazy-highlight-update' - and this
      ;; searches that. The rule is the engine's own literal one, which is
      ;; what `isearch-find' runs, and searching the window's text rather
      ;; than one row's is what lets a match spanning a line break be
      ;; highlighted.
      ;;
      ;; The answer is the index of the match, or #f. The caller knows the
      ;; pattern's length, and the search answers where point would go.
      ;;--------------------------------------------------------------
      (string-search-forward text pattern from case-fold?))

    (define (isearch-lazy-highlight-update ed window pattern case-fold?)
      ;; GNU Emacs's `isearch-lazy-highlight-update': every match of the
      ;; search string in the window is highlighted.
      ;;
      ;; The C walks outwards from the match point is on and wraps at the
      ;; window's edges, so that the matches nearest point are made first
      ;; when `lazy-highlight-max-at-a-time' cuts a pass short; the set it
      ;; arrives at is the window's matches, and that is the set made here
      ;; in one pass. Emacs defers the work to an idle timer so that a
      ;; long search stays responsive; here it is one screenful, so it is
      ;; done where the C's loop would eventually get to.
      ;;
      ;; The window is copied out **once** and the pass walks the copy.
      ;; Searching the buffer a match at a time would be quadratic and was:
      ;; the engine's `text-editor-search-forward' copies from its start
      ;; argument to the end of the *buffer* on every call, and
      ;; `text-editor-copy-string' reads character by character through the
      ;; engine, so a per-match copy of a two-kilobyte window cost about a
      ;; millisecond for each of a screenful of matches - 165ms per
      ;; keystroke on an 800KB file, which is what "isearch has become
      ;; super slow" was. One copy for the pass is the whole of it.
      ;;--------------------------------------------------------------
      (lazy-highlight-cleanup #t)
      (when (and (*isearch-lazy-highlight*)
                 (< 0 (string-length pattern))
                 (eq? (window-buffer window) ed))
        (let* ((limit (min (window-end window) (text-editor-point-max ed)))
               (start (min (window-start window) limit))
               (len (string-length pattern))
               (text (text-editor-copy-string ed start limit))
               (end (string-length text)))
          (let loop ((at 0))
            (let ((found (isearch-lazy-highlight-search text pattern at case-fold?)))
              ;; a match running past the end of the window is not one of
              ;; the window's matches, which is what a bounded search means
              (when (and found (<= (+ found len) end))
                (isearch-lazy-highlight-match (+ start found)
                                              (+ start found len))
                ;; the pattern is at least one character, so this advances
                (loop (+ found len))))))))

    (define (isearch-match-bounds ed pattern direction)
      ;; Where the match the search is on begins and ends, in engine
      ;; indexes. Point sits at the match's far end - past it searching
      ;; forward, at its start searching backward (`isearch-search-string':
      ;; "If found, move point to the end of the occurrence") - so the
      ;; other end is the pattern's length away.
      ;;--------------------------------------------------------------
      (let ((point (text-editor-get-cursor ed))
            (len (string-length pattern)))
        (if (eq? direction 'forward)
            (cons (- point len) point)
            (cons point (+ point len)))))

    (define (isearch-no-upper-case-p string regexp-flag)
      ;; GNU Emacs's `isearch-no-upper-case-p' (isearch.el:3945):
      ;; "Return t if there are no upper case chars in STRING. If
      ;; REGEXP-FLAG is non-nil, disregard letters preceded by `\\'
      ;; (but not `\\\\') since they have special meaning in a regexp."
      ;; The upper-case test is the C's own: a character that
      ;; downcases to something else has upper case; one that does
      ;; not - a digit, a punctuation mark - has not.
      ;;--------------------------------------------------------------
      (let loop ((i 0) (quote-flag #f) (found #f))
        (cond
         (found #f)
         ((>= i (string-length string)) #t)
         ((and regexp-flag (char=? (string-ref string i) #\\))
          (loop (+ i 1) (not quote-flag) #f))
         (else
          (loop (+ i 1) #f
                (and (not quote-flag)
                     (not (char=? (string-ref string i)
                                  (char-downcase
                                   (string-ref string i))))))))))

    (define (isearch-printing-char key)
      ;; The character the key *event* KEY is, or #f when it prints
      ;; nothing - a function key, an arrow, a `M-` key.
      ;;
      ;; A plain character key is itself, which the event spells as its
      ;; own code. TAB and `C-j` are control keys - the decoders fold
      ;; them to `(ctrl #\i)` and `(ctrl #\j)`, which are the events 9
      ;; and 10 - and GNU Emacs's `isearch-printing-char' takes both, so
      ;; a search can be given a tab or a line break to find: that is how
      ;; `C-s foo C-j bar` searches for a string with a line break in
      ;; it.
      ;;
      ;; It compares the *event* rather than a character code, because
      ;; a code above 127 is ambiguous: it is a `M-` key's `CHAR_META`
      ;; form, which the search must *not* take for a character, and it
      ;; is also an ordinary accented letter, which it must. What tells
      ;; them apart is the modifier bits: `(kbd "M-a")' is `a' plus
      ;; `CHAR_META', and the plain character is below every one of
      ;; them - `char-alt' being the lowest of the six. A named key
      ;; (`up', `f1') is a symbol and is not a character at all.
      ;;--------------------------------------------------------------
      (cond
       ((not (integer? key)) #f)
       ((= key 9) #\tab)
       ((= key 10) #\newline)
       ((and (< key char-alt) (>= key 32)) (integer->char key))
       (else #f)))

    (define (isearch forward?)
      ;; The incremental search itself: read a key, act on it, search
      ;; again, and keep going until a key ends the search. Returns
      ;; nothing; point and the mark are left as the search left them.
      ;;--------------------------------------------------------------
      (let* ((frame (*current-frame*))
             (ed (current-editor))
             ;; the window whose matches are highlighted lazily, which is
             ;; the one the search is being watched in
             (window (frame-selected-window frame))
             (opoint (text-editor-get-cursor ed)))
        (let loop ((pattern "")
                   (direction (if forward? 'forward 'backward))
                   (states '())
                   (success? #t)
                   (wrapped? #f)
                   ;; a search folds case until an upper-case letter is
                   ;; typed into it (Emacs's `search-upper-case')
                   (case-fold? #t)
                   ;; whether to draw before waiting for the next key
                   (redraw? #t))
          (*search-pattern* (and (< 0 (string-length pattern)) pattern))
          (*search-case-fold?* case-fold?)
          ;; and record what was found as overlays for the display to
          ;; draw - the match point is on with the `isearch' face, the
          ;; others in the window with `lazy-highlight'. This is GNU
          ;; Emacs's `isearch-search' followed by
          ;; `isearch-lazy-highlight-new-loop', run on the key rather than
          ;; on an idle timer, there being no timer to hang it on and only
          ;; a screenful of work to do.
          (if success?
              (let ((match (isearch-match-bounds ed pattern direction)))
                (isearch-highlight (car match) (cdr match)))
              ;; a failing search leaves the last highlight where it was,
              ;; as `isearch-search' leaves the overlay alone when it
              ;; finds nothing
              #f)
          (isearch-lazy-highlight-update ed window pattern case-fold?)
          (set!frame-message
           frame
           (isearch-message pattern direction success? wrapped? case-fold?
                            (text-editor-get-cursor ed) opoint))
          ;; Draw only when there is something new to draw. The read is
          ;; *timed* whenever the development REPL is open - `read-wait-ms',
          ;; for the reason its note gives - so most iterations of this loop
          ;; are a read that found nothing, and drawing on those repaints
          ;; the whole terminal ten times a second for a search that has not
          ;; moved. GNU Emacs draws from `isearch-update', which the *state*
          ;; changes call, not from a read that timed out; same rule.
          (when redraw? (render! frame))
          ;; The key as `read-key-event' answers it: the *key event* GNU
          ;; Emacs's `read_char' would have answered with, with the
          ;; display's own form already normalised away at the read.
          ;; Nothing below this line knows which front end is running,
          ;; which is the whole point - a comparison against a character
          ;; was a terminal-shaped test, and on Gtk every key is an
          ;; integer, so a search there matched none of them and no key
          ;; did anything, `RET' and `C-g' included.
          ;;
          ;; The exits below compare the event itself: 13 is RET, 7 is
          ;; `C-g', 19 is `C-s', and that is what Emacs's
          ;; `isearch-mode-map' binds them as - `(kbd "RET")' and the
          ;; rest are those same integers. A key that is not a character
          ;; - `M-<', an arrow, a resize - is a symbol or carries
          ;; modifiers, and takes neither an exit nor a printing
          ;; character.
          (let* ((key (read-key-event (read-wait-ms)))
                 (code (and (integer? key) key))
                 (printable (and key (isearch-printing-char key))))
            (cond
             ;; ---- keys that end the search ----
             ((eqv? code 13)                                 ; isearch-exit
              (*search-pattern* #f)
              (isearch-dehighlight)
              (lazy-highlight-cleanup #t)
              (set!frame-message frame "")
              (when (not (= (text-editor-get-cursor ed) opoint))
                (set!text-editor-mark ed opoint)
                (set!frame-message
                 frame "Mark saved where search started")))
             ;; isearch-abort: give up the search if it found something,
             ;; otherwise take back what was typed until it finds again
             ((eqv? code 7)
              (if success?
                  (begin
                    (text-editor-set-cursor ed opoint)
                    (*search-pattern* #f)
                    (isearch-dehighlight)
                    (lazy-highlight-cleanup #t)
                    (set!frame-message frame "Quit"))
                  (let ((popped (isearch-pop-to-success ed states)))
                    (loop (car popped) direction (cdr popped) #t #f
                          case-fold? #t))))
             ;; ---- keys that move the search on ----
             ((eqv? code 19)                                 ; C-s
              (let ((next (isearch-repeat ed states pattern direction
                                          case-fold? success? wrapped?
                                          'forward)))
                (loop (car next) 'forward (cadr next) (caddr next)
                      (cadddr next) case-fold? #t)))
             ((eqv? code 18)                                 ; C-r
              (let ((next (isearch-repeat ed states pattern direction
                                          case-fold? success? wrapped?
                                          'backward)))
                (loop (car next) 'backward (cadr next) (caddr next)
                      (cadddr next) case-fold? #t)))
             ;; isearch-delete-char, which GNU Emacs binds to `"\177"'
             ;; (`isearch.el:607') - DEL is 127, its own key. `C-h' is
             ;; unbound in `isearch-mode-map' there (`isearch.el:608'
             ;; makes `[backspace]' explicitly undefined too), so it
             ;; falls through to the give-the-key-back branch below.
             ((eqv? code 127)
              (if (null? states)
                  (loop pattern direction states success? wrapped?
                        case-fold? #t)
                  (let ((popped (isearch-pop-state ed states)))
                    (loop (car popped) direction (cdr popped) #t #f
                          case-fold? #t))))
             ;; ---- keys that add to the search string ----
             ((eqv? code 23)                                 ; C-w
              ;; isearch-yank-word-or-char: the word (or character) at
              ;; point joins the search string
              (let ((new (string-append pattern (isearch-word-at-point ed))))
                (loop new direction
                      (cons (list pattern (text-editor-get-cursor ed) success?)
                            states)
                      (isearch-search! ed new direction case-fold?)
                      #f case-fold? #t)))
             ((eqv? code 25)                                 ; C-y
              ;; `isearch-yank-kill`: "the latest kill joins the search
              ;; string" - Emacs's `(isearch-yank-string (current-kill 0))',
              ;; which also moves the ring's yank pointer.
              (let ((new (string-append pattern (current-kill 0))))
                (loop new direction
                      (cons (list pattern (text-editor-get-cursor ed) success?)
                            states)
                      (isearch-search! ed new direction case-fold?)
                      #f case-fold? #t)))
             ;; isearch-printing-char: the character joins the search
             ;; string. C-j and TAB count as characters to search for, as
             ;; they do in Emacs's isearch keymap - `isearch-printing-char'
             ;; takes them, and both are control keys in every decoder here.
             (printable
              (let* ((new (string-append pattern (string printable)))
                     ;; Emacs's `search-upper-case': an upper-case letter
                     ;; TYPED into the search string turns case folding off;
                     ;; one yanked with C-w or C-y does not.
                     (fold? (and case-fold?
                                 (not (char-upper-case? printable)))))
                (loop new direction
                      (cons (list pattern (text-editor-get-cursor ed) success?)
                            states)
                      (isearch-search! ed new direction fold?)
                      #f fold? #t)))
             ;; a control key the search does not use ends it and gives the
             ;; key back to the command loop: GNU Emacs's
             ;; `isearch-other-control-char' exits the search
             ;; (`isearch-exit') and re-executes the key, so `C-s C-s C-x
             ;; C-c' quits the editor instead of eating the `C-x' and
             ;; leaving `C-c' as an undefined key. The mark is left alone,
             ;; as it is on this exit.
             ((and code (< code 32))
              (*search-pattern* #f)
              (isearch-dehighlight)
              (lazy-highlight-cleanup #t)
              (set!frame-message frame "")
              ;; Give the key back to the command loop to run, which is
              ;; what pushes it onto `unread-command-events' - Emacs's
              ;; `isearch-other-control-char' does the same, the loop's
              ;; read answering a pushed-back key before the display's.
              ;; The *event* is given back - the one form the command
              ;; loop's own read answers with and the one
              ;; `dispatch-input-event' takes.
              (*unread-command-events* (cons key (*unread-command-events*))))
             ;; anything else that is a *key* is not an answer to the
             ;; search, and ends it: a meta key such as `M-<', a function
             ;; key, an arrow. The key is given back to the command loop to
             ;; run, which is GNU Emacs's `isearch-other-meta-char' - and it
             ;; is what makes `M-<' leave the search and run
             ;; `beginning-of-buffer'. Without this a search simply ignored
             ;; the key: a terminal's `M-<' is the two bytes ESC and `<', so
             ;; the ESC took the control-key exit above, but a window system
             ;; sends ONE event with the meta modifier set, and that key
             ;; matched nothing and was thrown away.
             ;;
             ;; A read that answered nothing - a timeout, the end of input -
             ;; is `#f', which is not a key and is not given back; the
             ;; search simply reads again.
             (else
              (if key
                  (begin
                    (*search-pattern* #f)
                    (isearch-dehighlight)
                    (lazy-highlight-cleanup #t)
                    (set!frame-message frame "")
                    (*unread-command-events*
                     (cons key (*unread-command-events*))))
                  (loop pattern direction states success? wrapped?
                        case-fold? #f))))))))

    (define (isearch-pop-state ed states)
      ;; Take back the last state the search pushed, as DEL does.
      ;; Returns (pattern . states-left), with point put back where that
      ;; state was. A state is (pattern point success?).
      ;;--------------------------------------------------------------
      (if (null? states)
          (cons "" '())
          (let ((state (car states)))
            (text-editor-set-cursor ed (cadr state))
            (cons (car state) (cdr states)))))

    (define (isearch-pop-to-success ed states)
      ;; Take back states until the search was succeeding again, which is
      ;; what C-g does while a search is failing (GNU Emacs's
      ;; `isearch-abort': "rub out until it is once more successful").
      ;; Returns (pattern . states-left).
      ;;--------------------------------------------------------------
      (let loop ((states states))
        (let ((popped (isearch-pop-state ed states)))
          (if (or (null? (cdr popped)) (caddr (car states)))
              popped
              (loop (cdr popped))))))

    (define (isearch-repeat ed states pattern direction case-fold?
                            success? wrapped? new-direction)
      ;; A repeated search: C-s or C-r while searching. Turning the search
      ;; around just searches the other way from where point is; the same
      ;; direction again moves on to the next match, and when there is
      ;; none the search fails - and only the repeat AFTER that one wraps
      ;; to the far end of the buffer (Emacs's `isearch-wrap-pause' is t:
      ;; pause first, then wrap). Returns
      ;; (pattern states success? wrapped?).
      ;;--------------------------------------------------------------
      (let* ((turning? (not (eq? direction new-direction)))
             (forward? (eq? new-direction 'forward))
             (here (text-editor-get-cursor ed))
             (found (cond
                     (turning?
                      (isearch-find ed pattern new-direction case-fold? #f))
                     (success?
                      (isearch-find ed pattern new-direction case-fold? #t))
                     (else
                      ;; the search was failing, so this repeat wraps
                      (text-editor-set-cursor
                       ed (if forward?
                              (text-editor-point-min ed)
                              (text-editor-point-max ed)))
                      (isearch-find ed pattern new-direction
                                    case-fold? #f)))))
        (if found
            (begin
              (text-editor-set-cursor ed found)
              (list pattern
                    (cons (list pattern here success?) states)
                    #t
                    ;; the wrap is reported for the search that wrapped,
                    ;; not for the next match found after it
                    (if (or turning? success?) #f #t)))
            (list pattern states #f wrapped?))))

    (define (isearch-word-at-point ed)
      ;; The word at point, or the character at point when it is not part
      ;; of one - GNU Emacs's `isearch-yank-word-or-char'.
      ;;--------------------------------------------------------------
      (let* ((point (text-editor-get-cursor ed))
             (max (text-editor-point-max ed))
             (c (and (< point max) (text-editor-get-char-index ed point))))
        (cond
         ((not c) "")
         ((word-char? c)
          (let loop ((i point) (acc '()))
            (let ((ch (and (< i max) (text-editor-get-char-index ed i))))
              (if (and ch (word-char? ch))
                  (loop (+ 1 i) (cons ch acc))
                  (list->string (reverse acc))))))
         (else (string c)))))

    (define-command (isearch-forward)
      "Search forward incrementally (bound to C-s)."
      (interactive)
      (isearch #t))

    (define-command (isearch-backward)
      "Search backward incrementally (bound to C-r)."
      (interactive)
      (isearch #f))

    ;; The keys GNU Emacs binds the search to, beside the commands.
    (define-key *default-keymap* (kbd "C-s") isearch-forward)
    (define-key *default-keymap* (kbd "C-r") isearch-backward)

    (define (minibuffer-lazy-highlight-setup highlight cleanup transform
                                             regexp case-fold)
      ;; GNU Emacs's `minibuffer-lazy-highlight-setup' (isearch.el:4507):
      ;; "Set up minibuffer for lazy highlight of matches in the original
      ;; window." The answer is a closure to put on
      ;; `minibuffer-setup-hook', which is how `query-replace-read-args'
      ;; uses it.
      ;;
      ;; As the minibuffer's text changes, the buffer being replaced in is
      ;; searched for what has been typed so far and each match gets a
      ;; `lazy-highlight' overlay - the same `isearch-lazy-highlight-update'
      ;; the search itself runs, aimed at the window the minibuffer was
      ;; entered from (the C's `with-minibuffer-selected-window'). That is
      ;; what lights up the buffer as you type M-%, and what lights it
      ;; again when M-p brings a previous answer back into the minibuffer.
      ;;
      ;; HIGHLIGHT nil, or a minibuffer already active, sets up nothing:
      ;; the C's own two early exits. TRANSFORM turns the minibuffer's
      ;; text into the search string, `query-replace-read-args' passing
      ;; one that splits a FROM/TO pair apart and settles the case
      ;; folding; REGEXP and CASE-FOLD are what it then searches with.
      ;;
      ;; Not ported: the match count the C shows after the prompt
      ;; (`minibuffer-lazy-count-format' over `isearch-lazy-count-total'),
      ;; and the FILTER it adds to `isearch-filter-predicate' for a
      ;; region.
      ;;
      ;; CLEANUP is the C's `unwind' argument: the C deletes the overlays
      ;; itself only when it is true, and otherwise leaves
      ;; `lazy-highlight-cleanup' to decide. Either way the `unwind'
      ;; closure here takes the after-change hook off again, which the C
      ;; does by hand for the same reason - the hook list is global here
      ;; where Emacs's is buffer-local to the minibuffer.
      ;;--------------------------------------------------------------
      (if (or (not highlight) (minibufferp))
          (lambda () #f)
          (let ((buffer (current-buffer))
                ;; the window the minibuffer was entered from, which is
                ;; the one whose matches light up
                (window (frame-selected-window (*current-frame*))))
            (lambda ()
              (define (update!)
                ;; The hook is global here where the C's is buffer-local to
                ;; the minibuffer, so it is asked whether a minibuffer is
                ;; being read at all - without this it fires for the edits
                ;; of any buffer, and `minibuffer-contents' has nothing to
                ;; answer with once the minibuffer is gone.
                (when (minibufferp)
                  (isearch-lazy-highlight-update
                   buffer window (transform (minibuffer-contents)) case-fold)
                  (render! (*current-frame*))))
              (define (after-change beg end old-length)
                (update!))
              (define (unwind)
                (*after-change-functions*
                 (let loop ((l (*after-change-functions*)) (acc '()))
                   (cond ((null? l) (reverse acc))
                         ((eq? (car l) after-change) (loop (cdr l) acc))
                         (else (loop (cdr l) (cons (car l) acc))))))
                (lazy-highlight-cleanup cleanup))
              (*after-change-functions*
               (cons after-change (*after-change-functions*)))
              (*minibuffer-exit-hook*
               (cons unwind (*minibuffer-exit-hook*)))
              ;; and once for what is already in the minibuffer
              (update!)))))

    ))
