(import
 (only (schemacs buffer) allocate-buffer bufferp buffer-pt buffer-beg buffer-z text-editor-buffer-name set!text-editor-buffer-name text-editor-file-name set!text-editor-file-name buffer-modified-p set-buffer-modified-p buffer-read-only? set!buffer-read-only text-editor-text-props set!text-editor-text-props *inhibit-read-only* *buffer-visited-file-modtime-function* buffer-modified-tick buffer-chars-modified-tick text-editor-cache-long-scans set!text-editor-cache-long-scans show-text-editor text-editor-undo-list set!text-editor-undo-list)
 (only (schemacs undo) record-insert record-delete text-editor-undo-boundary! text-editor-undo-disable! text-editor-undo-enable! text-editor-undo-recording? *undo-limit* undo-insertion-entry? undo-deletion-entry? undo-modified-entry? *point-before-last-command-or-undo* *buffer-before-last-command-or-undo*)
 (only (schemacs insdel) *after-change-functions* signal-after-change *text-property-offset-function* invalidate-buffer-caches)
 (only (schemacs fns) %count-lines)
 (scheme base)
 (scheme char)
 
 (schemacs buffer)
 (schemacs frame)
 (schemacs editfns)
 (schemacs search)
 (schemacs casefiddle)
 (schemacs simple)
 (schemacs replace)
 (only (schemacs isearch) *search-upper-case*)
 ;; `kbd', so the two erase keys are spelled as the map binds them.
 (only (schemacs subr) kbd)
 (prefix (schemacs keymap) km:)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (ice-9 exceptions) exception-message)
 )

;; replace.el's tests: the answer map, the caret description, and the
;; automatic replacement path of `perform-replace'. The QUERY loop
;; draws - the highlight and the prompt go to the display - so its
;; testing is the pty battery's and the REPL's, not this suite's,
;; exactly as isearch's own loop is tested.

(test-begin "replace")

;; ------------------------------------------------------------------
;; a buffer to work in, without a query to draw

(define (in-buffer thunk)
  (parameterize ((*current-frame* (new-frame (allocate-buffer) 24 80))
                 (*current-buffer* #f)
                 (*case-fold-search* #f)
                 (*kill-ring* '())
                 (*kill-ring-yank-pointer* '())
                 (*this-command* #f)
                 (*last-command* #f))
    (thunk)))

;; ------------------------------------------------------------------
;; the answer map

(test-equal "the map's space is act"
  'act (km:keymap-lookup *query-replace-map* (km:keymap-index (list #\space))))
;; DEL and `C-h` are two different answers in Emacs's map - `"\d"` is
;; skip and `"\C-h"` is help - because they are two different bytes.
(test-equal "the map's DEL is skip"
  'skip (km:keymap-lookup *query-replace-map* (km:keymap-index (kbd "DEL"))))
(test-equal "the map's C-h is help"
  'help (km:keymap-lookup *query-replace-map* (km:keymap-index (kbd "C-h"))))
(test-equal "the map's ? is help"
  'help (km:keymap-lookup *query-replace-map* (km:keymap-index (list #\?))))
(test-equal "the map's C-g is quit"
  'quit (km:keymap-lookup *query-replace-map* (km:keymap-index (kbd "C-g"))))
(test-equal "the map's M-v is scroll-down"
  'scroll-down (km:keymap-lookup *query-replace-map* (km:keymap-index (kbd "M-v"))))

;; ------------------------------------------------------------------
;; the caret description

(test-equal "query-replace-descr shows a control character as ^X"
  "^I" (query-replace-descr (string #\tab)))
(test-equal "query-replace-descr shows DEL as ^?"
  "^?" (query-replace-descr (string (integer->char 127))))
(test-equal "query-replace-descr passes plain text"
  "plain" (query-replace-descr "plain"))

;; ------------------------------------------------------------------
;; replace-string: the automatic path, driven by perform-replace

(define (replace-string-in from to text)
  (in-buffer
   (lambda ()
     (insert text)
     (goto-char (point-min))
     (replace-string from to #f #f #f #f)
     (buffer-substring (point-min) (point-max)))))

(test-equal "replace-string replaces every occurrence"
  "one FRUIT, two FRUITs, three FRUITs"
  (replace-string-in "apple" "FRUIT" "one apple, two apples, three apples"))
(test-equal "replace-string with no match leaves the text"
  "no change" (replace-string-in "pear" "FRUIT" "no change"))
(test-equal "replace-string preserves case"
  ;; case-fold-search is on for this one, as it is by default in
  ;; Emacs - all three match
  "Fruit fruit FRUIT"
  (in-buffer
   (lambda ()
     (parameterize ((*case-fold-search* #t))
       (insert "Apple apple APPLE")
       (goto-char (point-min))
       (replace-string "apple" "fruit" #f #f #f #f)
       (buffer-substring (point-min) (point-max))))))

;; ------------------------------------------------------------------
;; delimited: word boundaries

;; "cat catalogue catalog", every "cat" taken as it stands:
;; "dog" + "dog" + "alogue" + "dog" + "alog"
(test-equal "undelimited replaces inside words"
  "dog dogalogue dogalog"
  (replace-string-in "cat" "dog" "cat catalogue catalog"))
;; delimited: only the whole words - the "cat" of "catalogue" is not
;; one (an `a' follows it), nor the "cat" of "catalog" (a `g' follows)
(test-equal "delimited keeps whole words only"
  "dog catalogue catalog"
  (in-buffer
   (lambda ()
     (insert "cat catalogue catalog")
     (goto-char (point-min))
     (replace-string "cat" "dog" #t #f #f #f)
     (buffer-substring (point-min) (point-max)))))

;; ------------------------------------------------------------------
;; the region limits

(test-equal "replace-string in a region stops at its end"
  "xx bb"
  (in-buffer
   (lambda ()
     (insert "aa bb")
     (goto-char (point-min))
     ;; the region 1..5 is "aa" plus the space; the second "a" run is
     ;; outside it
     (replace-string "a" "x" #f 1 5 #f)
     ;; the region 1..5 is the first "aa" and the space; the second
     ;; "b" run is outside it
     (buffer-substring (point-min) (point-max)))))


;; ------------------------------------------------------------------
;; `replace-region-contents' and the three `subr.el' functions over it
;;
;; **Every expectation below is `emacs -Q --batch`'s own answer** on the
;; same input, measured before the port - final text, point and return
;; value.

(define (rrc-buffer text)
  (let ((b (get-buffer-create "*rrc-tests*")))
    (set-buffer b)
    (erase-buffer)
    (insert text)
    b))

;; Point's three placements: at END it follows the replacement; before
;; BEG it stays; inside the region it lands where `replace_range` puts
;; it. Measured (t "hello there" 12), (t ... 1), (t ... 7), (t ... 10).
(test-equal '((#t "hello there" 12) (#t "hello there" 1)
              (#t "hello there" 7) (#t "hello there" 10))
  (in-buffer
   (lambda ()
     (map (lambda (at)
            (rrc-buffer "hello world")
            (goto-char at)
            (let ((ret (replace-region-contents 7 12 "there")))
              (list ret (buffer-string) (point))))
          (list 12 1 7 9)))))

;; A buffer source contributes its accessible portion; a `[buf beg end]'
;; vector that stretch of it. Measured (t "xxAAbbCCxx" 11) and
;; (t "xxbbxx" 7) - the vector's range is identical text, so the diff
;; finds nothing to do.
(test-equal '((#t "xxAAbbCCxx" 11) (#t "xxbbxx" 7))
  (in-buffer
   (lambda ()
     (let ((src (get-buffer-create "*rrc-src*")))
       (set-buffer src) (erase-buffer) (insert "AAbbCC")
       (set-buffer (get-buffer-create "*rrc-tests*"))
       (let ((one
              (begin (rrc-buffer "xxbbxx") (goto-char 7)
                     (let ((ret (replace-region-contents 3 5 src)))
                       (list ret (buffer-string) (point)))))
             (two
              (begin (rrc-buffer "xxbbxx") (goto-char 7)
                     (let ((ret (replace-region-contents 3 5 (vector src 3 5))))
                       (list ret (buffer-string) (point))))))
         (list one two))))))

;; The trivial paths - an empty replacement, MAX-SECS 0 and MAX-COSTS 0
;; all skip the diff and go straight to replace/replace_range. Measured
;; (t "abc" 2), (t "aXYc" 2), (t "aXYc" 2).
(test-equal '((#t "abc" 2) (#t "aXYc" 2) (#t "aXYc" 2))
  (in-buffer
   (lambda ()
     (list (begin (rrc-buffer "abc") (goto-char 2)
                  (list (replace-region-contents 2 2 "") (buffer-string) (point)))
           (begin (rrc-buffer "abc") (goto-char 2)
                  (list (replace-region-contents 2 3 "XY" 0) (buffer-string) (point)))
           (begin (rrc-buffer "abc") (goto-char 2)
                  (list (replace-region-contents 2 3 "XY" #f 0)
                        (buffer-string) (point)))))))

;; Two hunks through the diff path, and a function source. Measured
;; (t "abc123def456ghi" 16) and (t "aQc" 4).
(test-equal '((#t "abc123def456ghi" 16) (#t "aQc" 4))
  (in-buffer
   (lambda ()
     (list (begin (rrc-buffer "abcXXXdefYYYghi") (goto-char 16)
                  (list (replace-region-contents 1 16 "abc123def456ghi")
                        (buffer-string) (point)))
           (begin (rrc-buffer "abc") (goto-char 4)
                  (list (replace-region-contents 2 3 (lambda () "Q"))
                        (buffer-string) (point)))))))

;; A buffer is not its own source - measured `(error "Cannot replace a
;; buffer with itself")'.
(test-equal "Cannot replace a buffer with itself"
  (in-buffer
   (lambda ()
     (rrc-buffer "abc")
     (guard (e (#t (exception-message e)))
       (replace-region-contents 1 3 (current-buffer))))))

;; `replace-string-in-region': fixed case, the range, and the two range
;; errors. Measured (2 "XX"), (#f "abcabc"), (1 "ABCX"),
;; "Start before start of buffer", "End after end of buffer".
(test-equal '(2 "XX" #f "abcabc" 1 "ABCX"
                "Start before start of buffer" "End after end of buffer")
  (in-buffer
   (lambda ()
     (list (begin (rrc-buffer "abcabc") (goto-char 1)
                  (replace-string-in-region "abc" "X"))
           (begin (buffer-string))
           (begin (rrc-buffer "abcabc") (goto-char 1)
                  (replace-string-in-region "abc" "X" 2 5))
           (begin (buffer-string))
           (begin (rrc-buffer "ABCabc") (goto-char 1)
                  (replace-string-in-region "abc" "X"))
           (begin (buffer-string))
           (begin (guard (e (#t (exception-message e)))
                    (replace-string-in-region "a" "X" 0)))
           (begin (guard (e (#t (exception-message e)))
                    (replace-string-in-region "a" "X" 1 99)))))))

;; `replace-regexp-in-region': measured (2 "a#b#c"), (2 "1a2b2c") and
;; (nil "xyz").
(test-equal '(2 "a#b#c" 2 "1a2b2c" #f "xyz")
  (in-buffer
   (lambda ()
     (list (begin (rrc-buffer "a1b22c") (goto-char 1)
                  (replace-regexp-in-region "[0-9]+" "#"))
           (begin (buffer-string))
           (begin (rrc-buffer "a1b22c") (goto-char 1)
                  (replace-regexp-in-region "\\([a-z]\\)\\([0-9]\\)"
                                            "\\2\\1"))
           (begin (buffer-string))
           (begin (rrc-buffer "xyz") (goto-char 1)
                  (replace-regexp-in-region "[0-9]" "#"))
           (begin (buffer-string))))))

;; `replace-buffer-contents' is the obsolete wrapper over the whole
;; buffer - measured (t "axc").
(test-equal '(#t "axc")
  (in-buffer
   (lambda ()
     (rrc-buffer "abc")
     (let ((src (get-buffer-create "*rrc-src2*")))
       (set-buffer src) (erase-buffer) (insert "axc")
       (set-buffer (get-buffer-create "*rrc-tests*"))
       (let ((ret (replace-buffer-contents src)))
         (list ret (buffer-string)))))))

(test-end)
