(import
 (scheme base)
 (scheme char)
 (schemacs editor engine)
 (schemacs editor buffer)
 (schemacs editor frame)
 (schemacs editor editfns)
 (schemacs editor search)
 (schemacs editor casefiddle)
 (schemacs editor simple)
 (schemacs editor replace)
 (only (schemacs editor isearch) *search-upper-case*)
 ;; `kbd', so the two erase keys are spelled as the map binds them.
 (only (schemacs editor subr) kbd)
 (prefix (schemacs keymap) km:)
 (only (srfi 64) test-assert test-equal test-begin test-end)
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
  (parameterize ((*current-frame* (new-frame (new-text-editor) 24 80))
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

(test-end)
