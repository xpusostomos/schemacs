;; Tests for `(schemacs paren)' - `paren.el' (`show-paren-mode') and the
;; blink block of `simple.el'. **Every expectation is GNU Emacs's own
;; answer**, measured with `emacs -Q --batch' on the same buffer and the
;; same expressions - except `show-paren--snap', which is Emacs 32
;; source (GITE's `lisp/paren.el') and does not exist in the installed
;; 31.1 binary: it was measured by loading that source into 31.1, the
;; method the cc-fonts pass established for source-versus-binary
;; differences.
;;
;; One spelling difference throughout: Emacs prints `nil', this tree
;; prints `#f', and Emacs's `(car nil)' is answered here by an explicit
;; `pair?' test (there is no car-of-nil).

(import
  (scheme base)
  (only (srfi 64) test-assert test-equal test-begin test-end)
  (only (schemacs paren)
        *show-paren-style* *show-paren-delay* *show-paren-priority*
        *show-paren-ring-bell-on-mismatch*
        *show-paren-when-point-inside-paren*
        *show-paren-when-point-in-periphery* *show-paren-highlight-openparen*
        *show-paren-context-when-offscreen*
        *show-paren-not-in-comments-or-strings* *show-paren-predicate*
        show-paren--overlay show-paren--overlay-1 show-paren--idle-timer
        show-paren--delete-overlays show-paren--unescaped-p
        show-paren--categorize-paren show-paren--locate-near-paren
        show-paren--snap show-paren--default show-paren-data-function
        set!show-paren-data-function
        show-paren--last-pos show-paren--enabled-p show-paren-function
        show-paren-mode show-paren-local-mode show-paren-mode-value
        *blink-matching-paren-on-screen* *blink-matching-paren-distance*
        *blink-matching-delay* *blink-matching-paren-dont-ignore-comments*
        *blink-matching-paren-highlight-offscreen*
        blink-matching-check-function blink-matching-check-mismatch
        blink-paren-open-paren-line-string blink-matching--overlay
        blink-matching-open *blink-paren-function*
        blink-paren-post-self-insert-function)
  (only (schemacs buffer)
        get-buffer-create set-buffer erase-buffer current-buffer
        buffer-local-value set-buffer-local-value! local-variable-p
        kill-local-variable
        overlay-start overlay-end overlay-get)
  (only (schemacs data) default-value set-default)
  (only (schemacs editfns)
        insert point point-max goto-char *message-function*)
  (only (schemacs simple) *blink-matching-paren* default-font-height)
  (only (schemacs syntax)
        syntax-ppss syntax-ppss-context standard-syntax-table
        copy-syntax-table set-syntax-table modify-syntax-entry)
  (only (schemacs textprop) text-properties-at)
  (only (schemacs command) *last-command-event*)
  (only (schemacs cmds) *post-self-insert-hook*)
  (only (schemacs dispnew) noninteractive)
  (only (schemacs xdisp) pos-visible-in-window-p)
  (only (schemacs core timer) timer?))

(define (make-buffer name text)
  (let ((b (get-buffer-create name)))
    (set-buffer b)
    (erase-buffer)
    (set-buffer-local-value! b 'major-mode 'fundamental-mode)
    (insert text)
    b))

;; ------------------------------------------------------------------
;; show-paren--default: the opener/closer near point and its match.
;;
;; The table is `(emacs -Q --batch)'s `show-paren--default' at every
;; position of "foo (bar) baz".

(test-begin "schemacs_paren_default")

(set-default 'show-paren-mode #t)
(make-buffer "paren-default" "foo (bar) baz")
(test-equal "the default table"
            '((1 #f) (2 #f) (3 #f) (4 #f) (5 (5 6 9 10 #f)) (6 #f) (7 #f)
              (8 #f) (9 #f) (10 (9 10 5 6 #f)) (11 #f) (12 #f) (13 #f)
              (14 #f))
            (let loop ((p 1) (acc '()))
              (if (> p 14)
                  (reverse acc)
                  (begin
                    (goto-char p)
                    (loop (+ p 1) (cons (list p (show-paren--default)) acc))))))

;; `show-paren-when-point-inside-paren' at point 2 of "(a) b": Emacs
;; answers nil off and (1 2 3 4 nil) on.
(make-buffer "paren-inside" "(a) b")
(goto-char 2)
(test-equal "inside a paren, option off" #f (show-paren--default))
(test-equal "inside a paren, option on" '(1 2 3 4 #f)
            (parameterize ((*show-paren-when-point-inside-paren* #t))
              (show-paren--default)))

;; `show-paren-when-point-in-periphery': "  (a)" at 1 -> (1 . 3);
;; "(a)  " at 5 -> (-1 . 4).
(make-buffer "paren-periphery-before" "  (a)")
(goto-char 1)
(test-equal "periphery before the code, option off" #f
            (show-paren--locate-near-paren))
(test-equal "periphery before the code, option on" (cons 1 3)
            (parameterize ((*show-paren-when-point-in-periphery* #t))
              (show-paren--locate-near-paren)))
(make-buffer "paren-periphery-after" "(a)  ")
(goto-char 5)
(test-equal "periphery after the code, option off" #f
            (show-paren--locate-near-paren))
(test-equal "periphery after the code, option on" (cons -1 4)
            (parameterize ((*show-paren-when-point-in-periphery* #t))
              (show-paren--locate-near-paren)))

;; The escaped paren: "\\(a)" - position 2's paren is escaped, position
;; 4's is not; Emacs: nil, nil, (-1 . 5), nil.
(make-buffer "paren-escaped" "\\(a)")
(test-equal "escaped paren" #f (show-paren--categorize-paren 2))
(test-equal "escaped paren is not unescaped" #f (show-paren--unescaped-p 2))
(test-equal "the close paren" (cons -1 5) (show-paren--categorize-paren 4))
(test-equal "a letter is not a paren" #f (show-paren--categorize-paren 3))

;; `show-paren--snap': the first position at or after POS that is not
;; mid-string/comment. Measured from GITE's `paren.el' loaded in 31.1.
(make-buffer "paren-snap-string" "\"ab\" x")
(test-equal "snap in a string" 5 (show-paren--snap 2))
(test-equal "snap at the string's start" 1 (show-paren--snap 1))
(test-equal "snap after the string" 5 (show-paren--snap 5))
(test-equal "snap past the string" 6 (show-paren--snap 6))
(make-buffer "paren-snap-comment" "")
(let ((table (copy-syntax-table (standard-syntax-table))))
  (modify-syntax-entry #\; "<" table)
  (modify-syntax-entry #\newline ">" table)
  (set-syntax-table table))
(insert ";; ab\nx")
(test-equal "snap in a comment" 7 (show-paren--snap 2))
(test-equal "snap later in a comment" 7 (show-paren--snap 4))
(test-equal "snap at the comment's end" 7 (show-paren--snap 6))
(test-equal "snap at the comment's start" 1 (show-paren--snap 1))

(test-end "schemacs_paren_default")

;; ------------------------------------------------------------------
;; show-paren-function's overlays.
;;
;; The face, priority and spans are `emacs -Q --batch''s: a match is
;; `show-paren-match' with priority 1000, the expression style is
;; `show-paren-match-expression', and a mismatch is
;; `show-paren-mismatch'.

(test-begin "schemacs_paren_overlays")

(set-default 'show-paren-mode #t)
(make-buffer "paren-ov" "foo (bar) baz")
(goto-char 5)
(show-paren-function)
(test-equal "at an open paren: the match"
            '(9 10 show-paren-match)
            (list (overlay-start show-paren--overlay)
                  (overlay-end show-paren--overlay)
                  (overlay-get show-paren--overlay 'face)))
(test-equal "at an open paren: the here paren"
            '(5 6 show-paren-match)
            (list (overlay-start show-paren--overlay-1)
                  (overlay-end show-paren--overlay-1)
                  (overlay-get show-paren--overlay-1 'face)))
(test-equal "the priority" 1000 (overlay-get show-paren--overlay 'priority))
(goto-char 10)
(show-paren-function)
(test-equal "at a close paren: the match" '(5 6)
            (list (overlay-start show-paren--overlay)
                  (overlay-end show-paren--overlay)))
(test-equal "at a close paren: the here paren" '(9 10)
            (list (overlay-start show-paren--overlay-1)
                  (overlay-end show-paren--overlay-1)))
(test-equal "the expression style"
            '(5 10 show-paren-match-expression)
            (parameterize ((*show-paren-style* 'expression))
              (show-paren--delete-overlays)
              (show-paren-function)
              (list (overlay-start show-paren--overlay)
                    (overlay-end show-paren--overlay)
                    (overlay-get show-paren--overlay 'face))))

;; `show-paren-highlight-openparen' nil: the here overlay is turned off
;; at a forward match (Emacs leaves the match at 9..10).
(make-buffer "paren-ov-noopen" "foo (bar) baz")
(goto-char 5)
(parameterize ((*show-paren-highlight-openparen* #f))
  (show-paren-function))
(test-equal "no openparen highlight: the match is still moved" 9
            (overlay-start show-paren--overlay))
(test-equal "no openparen highlight: the here overlay is off" #f
            (overlay-start show-paren--overlay-1))

;; The mismatch: "(]" at point 3.
(make-buffer "paren-ov-mismatch" "(]")
(goto-char 3)
(test-equal "mismatch data" '(2 3 1 2 #t) (show-paren--default))
(show-paren-function)
(test-equal "mismatch face"
            '(1 2 show-paren-mismatch)
            (list (overlay-start show-paren--overlay)
                  (overlay-end show-paren--overlay)
                  (overlay-get show-paren--overlay 'face)))
(test-equal "mismatch here paren" '(2 3)
            (list (overlay-start show-paren--overlay-1)
                  (overlay-end show-paren--overlay-1)))

;; `show-paren-not-in-comments-or-strings': a comment must not even be
;; highlighted with `all'; the overlays stay where the last accepted
;; points put them, and `show-paren--last-pos' is not advanced.
(make-buffer "paren-comment" "")
(let ((table (copy-syntax-table (standard-syntax-table))))
  (modify-syntax-entry #\; "<" table)
  (modify-syntax-entry #\newline ">" table)
  (set-syntax-table table))
(insert "(a) ;; (b)")
(goto-char 4)
(show-paren-function)
(test-equal "before the comment: the match" '(1 2)
            (list (overlay-start show-paren--overlay)
                  (overlay-end show-paren--overlay)))
(test-equal "before the comment: the here paren" '(3 4)
            (list (overlay-start show-paren--overlay-1)
                  (overlay-end show-paren--overlay-1)))
(goto-char 11)
(test-equal "in the comment: the data" '(10 11 8 9 #f)
            (show-paren--default))
(test-equal "in the comment: context" 'comment
            (syntax-ppss-context (syntax-ppss 11)))
(parameterize ((*show-paren-not-in-comments-or-strings* 'all))
  (show-paren-function))
(test-equal "all: the overlays do not move" '(1 2 3 4)
            (list (overlay-start show-paren--overlay)
                  (overlay-end show-paren--overlay)
                  (overlay-start show-paren--overlay-1)
                  (overlay-end show-paren--overlay-1)))
(test-equal "all: last-pos is not advanced" 4 (show-paren--last-pos))
(parameterize ((*show-paren-not-in-comments-or-strings* #f))
  (show-paren-function))
(test-equal "nil: the comment is highlighted" '(8 9 10 11)
            (list (overlay-start show-paren--overlay)
                  (overlay-end show-paren--overlay)
                  (overlay-start show-paren--overlay-1)
                  (overlay-end show-paren--overlay-1)))

;; `show-paren-data-function' is buffer-local - Emacs's `defvar' is
;; `setq-local'-ed by treesit.el and html-ts-mode - so a buffer's own
;; value wins over the global default, which is `show-paren--default'.
(let ((b (make-buffer "paren-data-local" "x(y)")))
  (test-equal "the default data function" show-paren--default
              (show-paren-data-function))
  (set!show-paren-data-function (lambda () (list 2 3 1 2 #f)))
  ;; The variable holds the function (Emacs `funcall's it), so the
  ;; accessor answers a procedure and the test calls it.
  (test-equal "the buffer-local data function" '(2 3 1 2 #f)
              ((show-paren-data-function)))
  (goto-char 3)
  (show-paren-function)
  (test-equal "show-paren-function uses the buffer's function" '(2 3)
              (list (overlay-start show-paren--overlay-1)
                    (overlay-end show-paren--overlay-1)))
  (kill-local-variable 'show-paren-data-function)
  (test-equal "killing the local restores the default" show-paren--default
              (show-paren-data-function)))

(show-paren--delete-overlays)
(test-equal "delete-overlays" '(#f #f)
            (list (overlay-start show-paren--overlay)
                  (overlay-start show-paren--overlay-1)))

(test-end "schemacs_paren_overlays")

;; ------------------------------------------------------------------
;; The modes and the enabled predicate.

(test-begin "schemacs_paren_modes")

(set-default 'show-paren-mode #t)
(test-equal "the global default" #t (default-value 'show-paren-mode #f))
(test-assert "the idle timer exists" (timer? show-paren--idle-timer))
(make-buffer "paren-mode-fund" "")
(test-equal "enabled in fundamental-mode" #t (show-paren--enabled-p))
(test-equal "the variable" #t (show-paren-mode-value))

;; A special-mode-derived buffer: the default predicate excludes it,
;; and `show-paren-local-mode' can override the exclusion. Emacs's
;; answers: nil, then t with a local binding, then nil again.
(make-buffer "paren-mode-special" "")
(set-buffer-local-value! (current-buffer) 'major-mode 'special-mode)
(test-equal "not enabled in special-mode" #f (show-paren--enabled-p))
(show-paren-local-mode 1)
(test-equal "local mode overrides the predicate" #t (show-paren--enabled-p))
(test-assert "the local binding exists"
             (local-variable-p 'show-paren-mode (current-buffer)))
(test-equal "the global is untouched" #t
            (default-value 'show-paren-mode #f))
(show-paren-local-mode -1)
(test-equal "local mode off: not enabled" #f (show-paren--enabled-p))
(test-assert "the local binding is still there (equal to the default)"
             (local-variable-p 'show-paren-mode (current-buffer)))

;; With the global mode off, a local mode turns it on for one buffer and
;; killing the local leaves the global off. Emacs's answers:
;; (nil nil), then (t t nil), then (nil nil).
(set-default 'show-paren-mode #f)
(make-buffer "paren-mode-local" "")
(test-equal "global off: not enabled" #f (show-paren--enabled-p))
(show-paren-local-mode 1)
(test-equal "local on" #t (show-paren--enabled-p))
(test-assert "local binding" (local-variable-p 'show-paren-mode (current-buffer)))
(test-equal "global still off" #f (default-value 'show-paren-mode #f))
(show-paren-local-mode -1)
(test-equal "local off: not enabled" #f (show-paren--enabled-p))
(test-assert "local binding killed" (not (local-variable-p 'show-paren-mode
                                                           (current-buffer))))

;; The global toggle.
(show-paren-mode 1)
(test-equal "global on" #t (default-value 'show-paren-mode #f))
(show-paren-mode -1)
(test-equal "global off" #f (default-value 'show-paren-mode #f))
(test-assert "the timer is still armed when the mode is off" ; Emacs's body
             (timer? show-paren--idle-timer))
(show-paren-mode 1)

(test-end "schemacs_paren_modes")

;; ------------------------------------------------------------------
;; The blink block of simple.el.

(test-begin "schemacs_paren_blink")

;; `blink-matching-check-mismatch' - Emacs's answers on the same text.
(make-buffer "paren-check" "(]")
(test-equal "mismatched" #t (blink-matching-check-mismatch 1 3))
(make-buffer "paren-check2" "(foo]")
(test-equal "mismatched with content" #t (blink-matching-check-mismatch 1 6))
(make-buffer "paren-check3" "(foo)")
(test-equal "matched" #f (blink-matching-check-mismatch 1 6))
(test-equal "no start is a mismatch" #t
            (blink-matching-check-mismatch #f 6))
(make-buffer "paren-check4" "  (foo)")
(test-equal "start at an open paren" #f
            (blink-matching-check-mismatch 3 7))

;; `blink-paren-open-paren-line-string'.
(make-buffer "paren-line" "(foo)\nbar\n  (baz)")
(test-equal "the line before the open" "(foo)"
            (blink-paren-open-paren-line-string 1))
(test-equal "the line after the open" "  (baz)"
            (blink-paren-open-paren-line-string 11))
(test-equal "one space before the open" " (baz)"
            (blink-paren-open-paren-line-string 12))
(make-buffer "paren-line-prev" "foo\n(\nbar")
(test-equal "the previous nonblank line" "foo...("
            (blink-paren-open-paren-line-string 5))
(test-equal "the highlighted offscreen paren"
            '(face blink-matching-paren-offscreen)
            (parameterize ((*blink-matching-paren-highlight-offscreen* #t))
              (text-properties-at 6
                                  (blink-paren-open-paren-line-string 5))))

;; The hook is installed at load, appended after the others (Emacs's
;; `put ... 'priority 100' plus an `append' add-hook).
(test-assert "the blink hook is on post-self-insert-hook"
             (memq blink-paren-post-self-insert-function
                   (*post-self-insert-hook*)))

;; `blink-paren-post-self-insert-function': Emacs's table, measured by
;; calling the hook directly with `last-command-event' bound.
(define (blink-hook-run text event)
  (make-buffer "paren-hook" text)
  (let ((called #f))
    (parameterize ((*blink-paren-function*
                    (lambda () (set! called #t)))
                   (*last-command-event* (char->integer event)))
      (blink-paren-post-self-insert-function))
    called))

(test-equal "a close paren calls the function" #t (blink-hook-run "()" #\)))
(test-equal "the event must be the inserted char" #f
            (blink-hook-run "(" #\)))
(test-equal "an ordinary char does not" #f (blink-hook-run "x" #\)))
(test-equal "one backslash quotes it" #f (blink-hook-run "\\)" #\)))
(test-equal "two backslashes do not" #t (blink-hook-run "\\\\)" #\)))
(test-equal "noninteractive does not blink" #f
            (let ((saved noninteractive))
              (dynamic-wind
               (lambda () (set! noninteractive #t))
               (lambda () (blink-hook-run "()" #\)))
               (lambda () (set! noninteractive saved)))))
(test-equal "no blink function, no blink" #f
            (begin
              (make-buffer "paren-hook-none" "()")
              (parameterize ((*blink-paren-function* #f)
                             (*last-command-event* (char->integer #\))))
                (blink-paren-post-self-insert-function)
                #f)))

;; `blink-matching-open''s two messages, captured through the echo
;; area's seam (Emacs prints the same strings).
(define (blink-messages thunk)
  (let ((messages '()))
    (parameterize ((*message-function*
                    (lambda (text) (set! messages (cons text messages)))))
      (thunk))
    (reverse messages)))

(make-buffer "paren-blink-mismatch" "(]")
(goto-char 3)
(test-equal "mismatched parentheses message" '("Mismatched parentheses")
            (blink-messages blink-matching-open))
(make-buffer "paren-blink-matches" "(foo)")
(goto-char 6)
(test-equal "the off-screen opener's line" '("Matches (foo)")
            (blink-messages blink-matching-open))
(test-equal "no display means no visible position" #f
            (pos-visible-in-window-p 1))
(make-buffer "paren-blink-far"
             (string-append "(" (make-string 200 #\x) "\n"
                            (make-string 200 #\y) "\n)"))
(goto-char (point-max))
(test-equal "no matching parenthesis message"
            '("No matching parenthesis found")
            (parameterize ((*blink-matching-paren-distance* 50))
              (blink-messages blink-matching-open)))

;; `default-font-height' with no display is 1, as in a batch Emacs.
(test-equal "default-font-height without a display" 1
            (default-font-height))

(test-end "schemacs_paren_blink")

(set-default 'show-paren-mode #t)
