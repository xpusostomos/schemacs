(import
  (scheme base)
  (scheme char)
  (scheme time)
  (only (srfi 64) test-assert test-equal test-begin test-end)
  (only (schemacs editor command) *quit-flag* quit-condition?)
  (only (schemacs editor buffer)
        *current-buffer* allocate-buffer get-buffer-create set-buffer
        erase-buffer buffer-z set-point buffer-pt)
  (only (schemacs editor editfns)
        insert point-max save-restriction narrow-to-region)
  (only (schemacs editor frame) *current-frame* new-frame)
  (only (schemacs editor syntax)
        char-syntax string-to-syntax matching-paren modify-syntax-entry
        parse-partial-sexp syntax-ppss syntax-table standard-syntax-table
        copy-syntax-table set-syntax-table with-syntax-table
        forward-word-position backward-word-position scan-sexps)
  (only (schemacs editor font-lock)
        font-lock-set-defaults font-lock-fontify-buffer set!font-lock-defaults!)
  (only (schemacs editor textprop) get-text-property put-text-property))

;; Regression tests for `(schemacs editor syntax)', which mirrors GNU
;; Emacs's `src/syntax.c' and the `syntax.el' half. **Every expectation
;; is Emacs 31.1's own answer**, measured with `emacs -Q --batch' on the
;; same buffer and the same expressions.
;;
;; One spelling difference: `char-syntax' answers a *character* here
;; where Emacs prints its integer - 119 for `a' - because a Scheme char
;; is how this tree spells one. `string-to-syntax' answers a cons whose
;; cdr is `#f' where Emacs has nil.

(test-begin "schemacs_editor_syntax")

(define (fresh-syntax-table!)
  ;; **A buffer's table starts as the standard table *object*** -
  ;; `reset_buffer_local_variables' installs it - so a
  ;; `modify-syntax-entry' with no table argument writes into the
  ;; standard table and every later buffer sees it. That is Emacs's
  ;; behaviour too (a mode always installs its own table first), and
  ;; these groups have to do the same or they read each other's edits.
  (set-syntax-table (copy-syntax-table (standard-syntax-table))))

(define (with-buffer thunk)
  (parameterize ((*current-frame* (new-frame (allocate-buffer) 24 80))
                 (*current-buffer* #f))
    (let ((b (get-buffer-create "*syntax-tests*")))
      (set-buffer b)
      (erase-buffer)
      (thunk b))))

;; ------------------------------------------------------------------
;; `char-syntax'

(test-equal "char-syntax of a letter"
  #\w (char-syntax #\a))
(test-equal "char-syntax of underscore - *symbol*, not word"
  #\_ (char-syntax #\_))
(test-equal "... and of dash, which is also symbol"
  #\_ (char-syntax #\-))
(test-equal "space is whitespace"
  #\space (char-syntax #\space))
(test-equal "dot is punctuation"
  #\. (char-syntax #\.))
(test-equal "an open paren"
  #\( (char-syntax #\())
(test-equal "a string quote"
  #\" (char-syntax #\"))
(test-equal "an escape"
  #\\ (char-syntax #\\))
(test-equal "newline is whitespace"
  #\space (char-syntax #\newline))
(test-equal "a control character is punctuation"
  #\. (char-syntax (integer->char 1)))
;; It used to be `€' here, expecting `w' - which is what this tree gave
;; every character above ASCII before `characters.scm''s runs landed.
;; Emacs says `€' is a *symbol* (95) and gives `word' to the code points
;; its Unicode data does not name; the default is tested on one of those.
(test-equal "an unnamed multibyte character is word by default"
  #\w (char-syntax (integer->char 9999)))

;; ------------------------------------------------------------------
;; `string-to-syntax'

(test-equal "a bare class is the shared (CODE . nil) entry"
  (cons 2 #f) (string-to-syntax "w"))
(test-equal "a matching character is the cdr"
  (cons 4 93) (string-to-syntax "(]"))
(test-equal "a two-character comment start's flags are bits 16 and 17"
  (cons 196609 #f) (string-to-syntax ". 12"))
(test-equal "@ means inherit, which is nil"
  #f (string-to-syntax "@"))
(with-buffer
 (lambda (b)
   (insert "x")
   (test-equal "a matched pair's paren is the closing bracket"
     41 (matching-paren #\())
   (test-equal "punctuation has no matching paren"
     #f (matching-paren #\a))))

;; ------------------------------------------------------------------
;; the word motion - `scan_words' over the syntax table, where `_' is
;; *not* a word constituent (Emacs: 4, 8, 11, and back to 10).

(with-buffer
 (lambda (b)
   (insert "foo_bar (a \"s\" ) ; c\nx")
   (set-point b 1)
   (test-equal "forward-word stops at the underscore"
     4 (forward-word-position b))
   (set-point b 4)
   (test-equal "... and the next word is bar"
     8 (forward-word-position b))
   (set-point b 8)
   (test-equal "... then the paren is punctuation"
     11 (forward-word-position b))
   (set-point b 11)
   (test-equal "backward-word from the quote lands after `a'"
     10 (backward-word-position b))))

;; ------------------------------------------------------------------
;; `parse-partial-sexp' - the state table, measured in Emacs on the same
;; text: `foo_bar (a "s" ) ; c' then a newline and `x'.  Elements 0, 3,
;; 4 and 8 are depth, instring, incomment and the comment/string start.

(define %string-states
  '((1 0 #f #f)
    (2 0 #f #f) (3 0 #f #f) (4 0 #f #f) (5 0 #f #f) (6 0 #f #f)
    (7 0 #f #f) (8 0 #f #f) (9 0 #f #f) (10 1 #f #f)
    (11 1 #f #f) (12 1 #f #f)
    (13 1 34 12) (14 1 34 12)
    (15 1 #f #f) (16 1 #f #f)
    (17 0 #f #f) (18 0 #f #f) (19 0 #f #f) (20 0 #f #f)
    (21 0 #f #f) (22 0 #f #f)))

(with-buffer
 (lambda (b)
   (insert "foo_bar (a \"s\" ) ; c\nx")
   (let loop ((i 1) (acc '()))
     (if (> i 22)
         (test-equal "the state at each position, as Emacs gives it"
           %string-states (reverse acc))
         (begin
           (set-point b 1)
           (let ((st (parse-partial-sexp 1 i)))
             (loop (+ i 1)
                   (cons (list i (list-ref st 0) (list-ref st 3)
                               (list-ref st 8))
                         acc))))))))

;; a comment, with the syntax a mode would install
(define %comment-states
  '((1 0 #f #f) (2 0 #f #f) (3 0 #f #f)
    (4 0 #t 3) (5 0 #t 3) (6 0 #t 3) (7 0 #t 3) (8 0 #t 3)
    (9 0 #f #f) (10 0 #f #f)))

(with-buffer
 (lambda (b)
   (fresh-syntax-table!)
   (modify-syntax-entry #\; "<")
   (modify-syntax-entry #\newline ">")
   (insert "a ; foo\nb")
   (let loop ((i 1) (acc '()))
     (if (> i 10)
         (test-equal "a comment opens at the semicolon and closes at the newline"
           %comment-states (reverse acc))
         (begin
           (set-point b 1)
           (let ((st (parse-partial-sexp 1 i)))
             (loop (+ i 1)
                   (cons (list i (list-ref st 0) (list-ref st 4)
                               (list-ref st 8))
                         acc))))))
   ;; `commentstop' = `syntax-table' stops after the comment's start
   (set-point b 1)
   (parse-partial-sexp 1 10 #f #f #f 'syntax-table)
   (test-equal "... and the scanner stops just after the `;'"
     4 (buffer-pt b))))

(with-buffer
 (lambda (b)
   (fresh-syntax-table!)
   (modify-syntax-entry #\/ ". 124")
   (modify-syntax-entry #\* ". 23")
   (insert "a /* x */ b")
   (set-point b 1)
   (let ((st (parse-partial-sexp 1 9)))
     (test-equal "a two-character C-style comment is open at its middle"
       #t (list-ref st 4)))
   (set-point b 1)
   (let ((st (parse-partial-sexp 1 11)))
     (test-equal "... and closed after its `*/'"
       #f (list-ref st 4)))
   (set-point b 1)
   (parse-partial-sexp 1 12 #f #f #f 'syntax-table)
   (test-equal "commentstop stops after the opening `/*'"
     5 (buffer-pt b))))

;; ------------------------------------------------------------------
;; `syntax-ppss' agrees with a from-scratch parse

(with-buffer
 (lambda (b)
   (fresh-syntax-table!)
   (modify-syntax-entry #\; "<")
   (modify-syntax-entry #\newline ">")
   (insert "a ; foo\nb \"s\" c")
   (let loop ((pos 1))
     (when (<= pos (buffer-z b))
       (let ((a (syntax-ppss pos)))
         (set-point b 1)
         (let ((b-state (parse-partial-sexp 1 pos)))
           (test-equal (string-append "syntax-ppss agrees at " (number->string pos))
             (list (list-ref b-state 0) (list-ref b-state 3) (list-ref b-state 4))
             (list (list-ref a 0) (list-ref a 3) (list-ref a 4)))))
       (loop (+ pos 1))))))

;; ------------------------------------------------------------------
;; the syntactic fontification pass - the faces and their positions are
;; Emacs's (`a ; foo' in a comment, `"s"' in a string, and nothing on
;; the newline that ends the comment or on the surrounding text).

(with-buffer
 (lambda (b)
   (fresh-syntax-table!)
   (modify-syntax-entry #\; "<")
   (modify-syntax-entry #\newline ">")
   (insert "a ; foo\nb \"s\" c")
   (set!font-lock-defaults! '(()))
   (font-lock-set-defaults)
   (font-lock-fontify-buffer)
   (test-equal "the comment's characters get font-lock-comment-face"
     '(font-lock-comment-face font-lock-comment-face
       font-lock-comment-face font-lock-comment-face
       font-lock-comment-face font-lock-comment-face)
     (map (lambda (i) (get-text-property i 'face)) '(3 4 5 6 7 8)))
   (test-equal "the string's characters get font-lock-string-face"
     '(font-lock-string-face font-lock-string-face font-lock-string-face)
     (map (lambda (i) (get-text-property i 'face)) '(11 12 13)))
   (test-equal "and the text around them gets nothing"
     '(#f #f) (map (lambda (i) (get-text-property i 'face)) '(9 15)))))

;; ------------------------------------------------------------------
;; `copy-syntax-table' and `with-syntax-table'

(define (char-syntax-of table c)
  ;; `char-syntax' in TABLE - the C's `char-syntax' reads the current
  ;; buffer's table, so the check has to bind it.
  (with-syntax-table table (lambda () (char-syntax c))))


(with-buffer
 (lambda (b)
   ;; the buffer is shared by every group, and an earlier one installed
   ;; `;' as a comment starter - start from the standard table again
   (fresh-syntax-table!)
   (let ((copy (copy-syntax-table)))
     (modify-syntax-entry #\; "<" copy)
     (test-equal "a copied table takes its own entries"
       #\< (char-syntax-of copy #\;))
     (test-equal "... and inherits the rest from its parent"
       #\w (char-syntax-of copy #\a))
     (test-equal "while the buffer's own table is untouched"
       #\. (char-syntax #\;)))
   (let ((other (copy-syntax-table)))
     (modify-syntax-entry #\a ".")
     (with-syntax-table other
       (lambda ()
         (test-equal "with-syntax-table installs the table"
           #\w (char-syntax #\a))))
     (test-equal "... and restores the buffer's on the way out"
       #\. (char-syntax #\a)))))

;; ------------------------------------------------------------------
;; `gl_state', the syntax-table cache (`syntax.h:66', `syntax.c:336').
;;
;; Two regressions from the same report (2026-11-15): `C-M-b' from the
;; end of a 257 KB Scheme file with font-lock on took 144 s and looked
;; like a hang. The cache that stood here was a forward-only run cache
;; built with `next-single-property-change', which reads every interval
;; between the position asked about and the next *syntax-table* change -
;; on a font-locked buffer that is the end of the buffer, for every
;; character of a backward scan.

;; measured on Emacs 31.1 with `parse-sexp-lookup-properties' on: the
;; plain answers are 4 and, with `(' and `)' made punctuation by the
;; property, 3 forward and 2 backward.
(with-buffer
 (lambda (b)
   (fresh-syntax-table!)
   (insert "(a)")
   (let ((plain (scan-sexps 1 1)))
     (put-text-property 1 2 'syntax-table (string-to-syntax "."))
     (put-text-property 3 4 'syntax-table (string-to-syntax "."))
     (test-equal "the scan reads a `syntax-table' text property"
       (list 4 3 2)
       (list plain (scan-sexps 1 1) (scan-sexps 4 -1))))))

;; This buffer is a shape the cache has to get right and the old one got
;; wrong: 40 000 characters carrying 4 000 `face' intervals and no
;; `syntax-table' property at all. Measured with the C's cache: 450 ms
;; backward (21 ms before the per-character propertize check of
;; 2026-11-15, which is a vector-ref and a compare); with the
;; forward-only cache the same backward scan took 11 900 ms, and the
;; cost grows with the square of the buffer. The bound sits well under
;; the old number and far above the measured one so a loaded machine
;; does not fail it.
(with-buffer
 (lambda (b)
   (fresh-syntax-table!)
   (insert "(" (make-string 40000 #\a) ")")
   (let loop ((p 2))
     (when (< p 40000)
       (put-text-property p (+ p 10) 'face 'bold)
       (loop (+ p 10))))
   (let* ((t0 (current-jiffy))
          (where (scan-sexps (point-max) -1))
          (ms (* 1000 (/ (- (current-jiffy) t0) (jiffies-per-second)))))
     (test-equal "a backward scan lands where the forward one started"
       1 where)
     (test-assert "and it crosses the intervals once, not once per character"
       (< ms 5000)))))

;; `C-g' during a long command. The C's scan loops call `rarely_quit'
;; (`lisp.h:3914') once every 65536 characters, which looks at
;; `quit-flag' and signals `quit'. Nothing outside the read looked at
;; the flag before, so a C-g pressed during a scan was never seen - a
;; long scan was uninterruptible.
(with-buffer
 (lambda (b)
   (fresh-syntax-table!)
   (insert "(" (make-string 70000 #\a) ")")
   (*quit-flag* #t)
   (test-equal "a long scan answers C-g"
     (list 'quit #f)
     (list (guard (e (#t (if (quit-condition? e) 'quit 'other)))
             (scan-sexps 1 1))
           (*quit-flag*)))))


;; ---------------------------------------------------------------------
;; The characters above ASCII: `characters.scm' carries Emacs 31.1's own
;; answers (`standard-syntax-runs'), because `init_syntax_once' gives
;; them all `word' and `characters.el' then walks the Unicode blocks.
;; Without the runs every one of these was `word', and the font-lock
;; entries that match the typographic quotes matched inside strings.
;; Measured on `emacs -Q --batch' with `(char-syntax CH)': 46, 95, 95,
;; 46, 119, 119.
;; ---------------------------------------------------------------------
(test-equal "the typographic quotes are punctuation"
  #\. (char-syntax (integer->char #x2018)))
(test-equal "... the closing one too"
  #\. (char-syntax (integer->char #x2019)))
(test-equal "an arrow is a symbol"
  #\_ (char-syntax (integer->char #x2192)))
(test-equal "so is a currency sign"
  #\_ (char-syntax (integer->char #x20AC)))
(test-equal "a Cyrillic letter is still a word constituent"
  #\w (char-syntax (integer->char #x0430)))
(test-equal "and an unassigned code point keeps the default"
  #\w (char-syntax (integer->char 9999)))

(test-end "schemacs_editor_syntax")

;; ------------------------------------------------------------------
;; The `syntax-ppss' cache (`syntax.el:525-560')
;; ------------------------------------------------------------------
;;
;; **Two buffer-local cells, as Emacs has** - `syntax-ppss-wide' and
;; the narrowed one - and a `pt-min` of `(point-min)`. A single global
;; cell let a state cached at a high position be read back at a lower
;; one, and a narrowed parse poison an unnarrowed one. The failure was
;; "Wrong type argument in position 2: #f" from the `<= pt-min pos>
;; test, three functions from the cause: `M-j' in a fresh buffer.
;;
;; Emacs's own answers, measured with `emacs -Q --batch': with `;' a
;; comment starter and `\n' its ender, a state at 11 in ";; aaa bbb\n"
;; is the comment's - in comment, started at 1 - and one at 1 is the
;; top level. Each buffer and each narrowing has its own cache.

(test-begin "schemacs_editor_ppss_cache")

(with-buffer
 (lambda (b)
   (fresh-syntax-table!)
   (modify-syntax-entry #\; "<")
   (modify-syntax-entry #\newline ">")
   (insert ";; aaa bbb\n")
   (let ((high (syntax-ppss 11)))
     (test-equal "a state at a high position is the comment's"
       (list 0 #t 1) (list (list-ref high 0) (list-ref high 4)
                           (list-ref high 8))))
   (let ((low (syntax-ppss 1)))
     (test-equal "and one at a lower position after it is the top level"
       (list 0 #f #f) (list (list-ref low 0) (list-ref low 4)
                            (list-ref low 8))))))

(test-equal "a second buffer does not read the first buffer's cache"
  (list 0 #f #f)
  (parameterize ((*current-frame* (new-frame (allocate-buffer) 24 80))
                 (*current-buffer* #f))
    (let ((a (get-buffer-create "*ppss-a*"))
          (b (get-buffer-create "*ppss-b*")))
      (set-buffer a)
      (erase-buffer)
      (modify-syntax-entry #\; "<")
      (modify-syntax-entry #\newline ">")
      (insert ";; one\n")
      (syntax-ppss 8)
      (set-buffer b)
      (erase-buffer)
      (insert "xyz\n")
      (let ((st (syntax-ppss 3)))
        (list (list-ref st 0) (list-ref st 3) (list-ref st 8))))))

(with-buffer
 (lambda (b)
   (fresh-syntax-table!)
   (modify-syntax-entry #\; "<")
   (modify-syntax-entry #\newline ">")
   (insert ";; aaa bbb\n")
   (let ((before (syntax-ppss 11)))
     (save-restriction
      (narrow-to-region 1 5)
      (syntax-ppss 1))
     (let ((after (syntax-ppss 11)))
       (test-equal "a narrowed parse does not displace the unnarrowed state"
         (list (list-ref before 0) (list-ref before 8))
         (list (list-ref after 0) (list-ref after 8)))))))

(test-end "schemacs_editor_ppss_cache")
