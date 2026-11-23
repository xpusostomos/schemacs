;; Tests for `(schemacs progmodes cc-mode)' - the first pass of
;; `lisp/progmodes/cc-mode.el': the found-type half of the change
;; machinery.
;;
;; **Every expectation here is Emacs 31.1's own answer**, measured with
;; `emacs -Q --batch' in a real `c-mode' buffer (`/tmp/measure-ccmode.el'
;; and `/tmp/measure-coalesce2.el', rebuilt from the cases below).
;;
;; The two `c-*-de-typedef' functions are carried but not tested here:
;; their inputs are the `c-typedef' text properties font locking writes,
;; so they are exercised by the change-hook differential once
;; `c-before-change'/`c-after-change' are wired. Emacs's own answers
;; were measured: after `(delete-region 1 8)' on
;; "typedef int myint;\nmyint x;", "myint" is out of `c-found-types',
;; and `c-before-change-de-typedef' over the same text empties it.
;;--------------------------------------------------------------

(import
 (scheme base)
 (only (guile) hash-ref hash-set!)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (schemacs buffer) allocate-buffer set-buffer current-buffer buffer-local-value
       set-buffer-local-value! buffer-z)
 (only (schemacs editfns) insert goto-char point point-min point-max)
 (only (schemacs search) match-beginning match-end)
 (only (schemacs syntax) set-syntax-table)
 (only (schemacs marker) marker-position)
 (only (schemacs textprop) get-text-property)
 (only (schemacs progmodes cc-defs) c-lang-const *c-buffer-is-cc-mode*
       c-clear-char-property c-mark-<-as-paren c-mark->-as-paren
       c-clear-char-property-with-value-on-char)
 (schemacs progmodes cc-langs)
 (only (schemacs progmodes cc-styles) c-set-style)
 (only (schemacs progmodes cc-engine) c-found-types c-add-type-1 c-clear-found-types
       c-new-id-start c-new-id-end c-new-id-is-type
       c-new-BEG set!c-new-BEG c-new-END set!c-new-END
       c-put-syntax-table-trim-caches
       c-clear-syntax-table-with-value-on-char-trim-caches)
 (only (schemacs progmodes cc-mode)
       c-unfind-enclosing-token c-unfind-coalesced-tokens c-update-new-id
       c-put-syn-tab c-clear-syn-tab c-clear-string-fences
       c-restore-string-fences c-remove-string-fences
       c-multiline-string-check-final-quote
       c-min-syn-tab-mkr c-max-syn-tab-mkr
       c-before-change-check-unbalanced-strings
       c-after-change-mark-abnormal-strings
       c-after-change-escape-NL-in-string
       c-open-string-opener
       c-before-change-include-<> c-after-change-include-<>
       c-before-change-fix-comment-escapes c-after-change-fix-comment-escapes
       c-quoted-number-head-before-point c-quoted-number-tail-after-point
       c-quoted-number-straddling-point
       c-parse-quotes-before-change c-parse-quotes-after-change))

(test-begin "schemacs_editor_cc_mode")

(define (fresh text)
  (let ((b (allocate-buffer)))
    (set-buffer b)
    (insert text)
    (set-buffer-local-value! b 'major-mode 'c-mode)
    (set-buffer-local-value! b 'parse-sexp-ignore-comments #t)
    (parameterize ((*c-buffer-is-cc-mode* 'c-mode))
      (c-init-language-vars c-mode)
      (set-syntax-table ((c-lang-const c-make-mode-syntax-table c)))
      (c-set-style "gnu")
      ;; `c-common-init' creates the table; cc-mode.el's mode
      ;; definitions are not ported, so the replay does it.
      (c-clear-found-types))
    b))

(define (found? name)
  (let ((h (c-found-types)))
    (and h (hash-ref h name))))

(define (put-found! name)
  (hash-set! (c-found-types) name #t))

;;--------------------------------------------------------------
;; `c-unfind-enclosing-token'
;;--------------------------------------------------------------
;; Emacs, measured: inside "abc" the function answers t and removes the
;; name; at the following space it answers nil and leaves the name.
(let ((b (fresh "abc def\n")))
  (c-add-type-1 1 4)
  (test-equal "the type was recorded" #t (found? "abc"))
  (test-equal "c-unfind-enclosing-token inside the token" #t
              (c-unfind-enclosing-token 2))
  (test-equal "and it removed the name" #f (found? "abc")))

(let ((b (fresh "abc def\n")))
  (c-add-type-1 1 4)
  (test-equal "c-unfind-enclosing-token at the space" #f
              (c-unfind-enclosing-token 4))
  (test-equal "the name is still there" #t (found? "abc")))

;;--------------------------------------------------------------
;; `c-unfind-coalesced-tokens'
;;--------------------------------------------------------------
;; Emacs, measured on "fo o": removing the space (BEG 3, END 4) would
;; join the fragments, so both fragments are removed - "o" by the
;; end-of-region arm and "fo" by the beg one - while the joined name,
;; which nobody had recorded, is untouched.
(let ((b (fresh "fo o\n")))
  (put-found! "o")
  (put-found! "fo")
  (put-found! "foo")
  (c-unfind-coalesced-tokens 3 4)
  (test-equal "the fragment after END is removed" #f (found? "o"))
  (test-equal "the fragment before BEG is removed" #f (found? "fo"))
  (test-equal "the joined name is not touched" #t (found? "foo")))

;; Emacs, measured on "xfo oy": both whole identifiers go.
(let ((b (fresh "xfo oy\n")))
  (put-found! "xfo")
  (put-found! "oy")
  (c-unfind-coalesced-tokens 4 5)
  (test-equal "xfo is removed" #f (found? "xfo"))
  (test-equal "oy is removed" #f (found? "oy")))

;;--------------------------------------------------------------
;; `c-update-new-id'
;;--------------------------------------------------------------
;; Emacs, measured: at the end of "abc" in "int abc = 1;" the bounds
;; are 5 and 9, and the type flag is cleared.
(let ((b (fresh "int abc = 1;\n")))
  (goto-char 8)
  (set-buffer-local-value! b 'c-new-id-is-type #t)
  (c-update-new-id (point))
  (test-equal "c-update-new-id's start" 5 (c-new-id-start))
  (test-equal "c-update-new-id's end" 9 (c-new-id-end))
  (test-equal "c-update-new-id clears the type flag" #f (c-new-id-is-type)))

(test-end "schemacs_editor_cc_mode")


;;--------------------------------------------------------------
;; The string-fence layer (`cc-mode.el:1298'-`:1465')
;;--------------------------------------------------------------
;; A single-line string, so the mode's own machinery marks nothing and
;; the fences below are the only ones in the buffer. The positions:
;;
;;     1..6 "int a;"   7 newline
;;     8..17 "char *s = "   18 the opening quote
;;     19..20 "xy"     21 the closing quote   22 ";"   23 newline
;;
;; Measured in `emacs -Q --batch' with the mode's own marks wiped first
;; (`c-clear-syn-tab' at every fenced position); `(inhibit-modification-
;; hooks t)' around every probe, so Emacs's change functions - not yet
;; ported here - cannot react to the property writes.
(test-begin "schemacs_editor_cc_mode_fences")

(define fence-text "int a;\nchar *s = \"xy\";\nint b;\n")

(define (fences)
  ;; The fenced positions of the buffer as (POS SYNTAX-TABLE C-FL-SYN-TAB).
  (let loop ((p (point-min)) (acc '()))
    (if (> p (buffer-z (current-buffer)))
        (reverse acc)
        (let ((st (get-text-property p 'syntax-table))
              (fl (get-text-property p 'c-fl-syn-tab)))
          (if (or st fl)
              (loop (+ p 1) (cons (list p st fl) acc))
              (loop (+ p 1) acc))))))

(define (mrk)
  (list (and (c-min-syn-tab-mkr) (marker-position (c-min-syn-tab-mkr)))
        (and (c-max-syn-tab-mkr) (marker-position (c-max-syn-tab-mkr)))))

(fresh fence-text)

(test-equal "a fresh buffer has no string fences" '() (fences))
(test-equal "... and no fence markers" '(#f #f) (mrk))

(c-put-syn-tab 18 '(15))
(test-equal "c-put-syn-tab writes both properties"
  (list 18 '(15) '(15)) (car (fences)))
(test-equal "... and plants both markers" '(18 19) (mrk))

(c-put-syn-tab 21 '(15))
(test-equal "the maximum marker grows past the second fence" '(18 22) (mrk))

(c-put-syn-tab 20 '(1))
(test-equal "a non-fence value is written to both properties too"
  '(20 (1) (1)) (cadr (fences)))

(c-clear-syn-tab 18)
(test-equal "clearing the minimum fence moves the minimum marker"
  '(20 22) (mrk))
(test-equal "... and removes both properties" #f
  (get-text-property 18 'syntax-table))

(c-clear-syn-tab 21)
(test-equal "clearing the last fence moves the maximum marker" '(20 21) (mrk))

(c-clear-syn-tab 20)
(test-equal "clearing the only fence left unsets both markers" '(#f #f) (mrk))
(test-equal "... and empties the buffer of fences" '() (fences))

;; `c-clear-string-fences' and `c-restore-string-fences'
(c-put-syn-tab 18 '(15))
(c-put-syn-tab 21 '(15))
(c-clear-string-fences)
(test-equal "clearing the fences leaves the mirrors, not the syntax"
  (list (list 18 #f '(15)) (list 21 #f '(15))) (fences))
(test-equal "... and leaves the markers alone" '(18 22) (mrk))

(c-restore-string-fences)
(test-equal "restoring puts the syntax back from the mirrors"
  (list (list 18 '(15) '(15)) (list 21 '(15) '(15))) (fences))

(c-remove-string-fences 18)
(test-equal "c-remove-string-fences removes the quote it is given"
  (list (list 21 '(15) '(15))) (fences))
(test-equal "... and moves the markers with it" '(21 22) (mrk))

;; An opener whose closing quote is not fenced: the C leaves the opener
;; with a `(1)' syntax-table property - "unbalanced".
(fresh fence-text)
(c-put-syn-tab 18 '(15))
(c-clear-string-fences)
(test-equal "an unbalanced opener is left with '(1) syntax"
  (list (list 18 '(1) '(15))) (fences))
(test-equal "... and its markers are unchanged" '(18 19) (mrk))

;; The last quote in the buffer, when the string is unterminated.
(fresh "int x;\nchar *s = \"abc")
(c-multiline-string-check-final-quote)
(test-equal "the last quote of an unterminated string is fenced"
  (list (list 18 '(15) '(15))) (fences))
(test-equal "... and the markers cover it" '(18 19) (mrk))

;; ... and when it is terminated, nothing is marked.
(fresh "int x;\nchar *s = \"abc\";\nint y;\n")
(c-multiline-string-check-final-quote)
(test-equal "a terminated string leaves no fence" '() (fences))
(test-equal "... and no markers" '(#f #f) (mrk))

(test-end "schemacs_editor_cc_mode_fences")


;;--------------------------------------------------------------
;; The string change functions (`cc-mode.el:1472'-`:1771')
;;--------------------------------------------------------------
;; Every expectation is Emacs 31.1's, measured with the same calls on
;; the same buffers (`/tmp/chg-em.el' and `/tmp/chg-em2.el'), with the
;; mode's own initial fences wiped first so both sides start empty.
;;
;; The fixture's positions:
;;
;;     "int x;\n"                       1..7
;;     "char *s = "                     8..17   opener 18
;;     "abc"                           19..21   newline 22
;;     "def"                           23..25   closing quote 26
;;     ";"                                  27   newline 28
(test-begin "schemacs_editor_cc_mode_string_changes")

(define (wipe-fences!)
  (let loop ()
    (when (c-min-syn-tab-mkr)
      (c-clear-syn-tab (marker-position (c-min-syn-tab-mkr)))
      (loop))))

(define abnormal-text "int x;\nchar *s = \"abc\ndef\";\nint y;\n")

(fresh abnormal-text)
(wipe-fences!)
(set!c-new-BEG 1) (set!c-new-END (point-max))
(c-after-change-mark-abnormal-strings 1 (point-max) 0)
(test-equal "a terminated multi-line string is fenced opener-to-newline"
  (list (list 18 '(15) '(15)) (list 22 '(15) '(15))
        (list 26 '(15) '(15)) (list 28 '(15) '(15)))
  (fences))
(test-equal "... and its markers cover the range" '(18 29) (mrk))
(test-equal "... the region is extended over it" (list 1 36)
  (list (c-new-BEG) (c-new-END)))
(test-equal "... and the last opener is remembered" 26 (c-open-string-opener))

(fresh "int x;\nchar *s = \"abc\ndef;\n")
(wipe-fences!)
(set!c-new-BEG 1) (set!c-new-END (point-max))
(c-after-change-mark-abnormal-strings 1 (point-max) 0)
(test-equal "an unterminated string is fenced at its opener and newline"
  (list (list 18 '(15) '(15)) (list 22 '(15) '(15))) (fences))
(test-equal "... its markers stop after the newline" '(18 23) (mrk))
(test-equal "... and the region ends at point-max" (list 1 28)
  (list (c-new-BEG) (c-new-END)))
(test-equal "... remembering the first opener" 18 (c-open-string-opener))

(fresh abnormal-text)
(wipe-fences!)
(set!c-new-BEG 1) (set!c-new-END (point-max))
(c-before-change-check-unbalanced-strings 22 22)
(test-equal "before a change with no fences nothing is added" '() (fences))
(test-equal "... and the region is unchanged" (list 1 36)
  (list (c-new-BEG) (c-new-END)))

(fresh abnormal-text)
(c-put-syn-tab 18 '(15)) (c-put-syn-tab 22 '(15))
(c-put-syn-tab 26 '(15)) (c-put-syn-tab 28 '(15))
(set!c-new-BEG 1) (set!c-new-END (point-max))
(c-before-change-check-unbalanced-strings 22 22)
(test-equal "a change at a fenced newline clears that fence pair only"
  (list (list 26 '(15) '(15)) (list 28 '(15) '(15))) (fences))
(test-equal "... and moves the markers with it" '(26 29) (mrk))

(fresh "int x;\nchar *s = \"abc\\\ndef\";\nint y;\n")
(wipe-fences!)
(c-put-syn-tab 18 '(15))
(c-put-syn-tab 23 '(15))
(c-put-syn-tab 27 '(15))
(c-after-change-escape-NL-in-string 22 23 0)
(test-equal "escaping a newline clears the fences through the closing quote"
  '() (fences))
(test-equal "... and unsets the markers" '(#f #f) (mrk))

(fresh "int x;\nchar *s = \"abc\\\ndef\";\nint y;\n")
(wipe-fences!)
(c-put-syn-tab 18 '(15))
(c-put-syn-tab 23 '(15))
(c-after-change-escape-NL-in-string 22 23 0)
(test-equal "with no fenced quote ahead, escaping the newline changes nothing"
  (list (list 18 '(15) '(15)) (list 23 '(15) '(15))) (fences))
(test-equal "... and leaves the markers" '(18 24) (mrk))

(test-end "schemacs_editor_cc_mode_string_changes")


;;--------------------------------------------------------------
;; `#include <...>' and the comment escapes (`cc-mode.el:2029'-`:2166')
;;--------------------------------------------------------------
;; Every expectation is Emacs 31.1's. Emacs's `c-mode' marks the include
;; brackets itself during initialisation (its before-font-lock sweep);
;; the tests mark them explicitly, which is the same state the
;; after-change function produces.
(test-begin "schemacs_editor_cc_mode_include_comment_escapes")

(fresh "#include <stdio.h>\nint a;\n")
(c-mark-<-as-paren 10)
(c-mark->-as-paren 18)
(test-equal "the include brackets are marked as parens"
  (list (list 10 '(4 . 62) #f) (list 18 '(5 . 60) #f)) (fences))

(set!c-new-BEG 1) (set!c-new-END (point-max))
(c-before-change-include-<> 1 18)
(test-equal "before a change the include brackets lose their syntax"
  '() (fences))
(test-equal "... and the region is extended" (list 1 27)
  (list (c-new-BEG) (c-new-END)))

(c-after-change-include-<> 1 18 0)
(test-equal "after the change they are marked again"
  (list (list 10 '(4 . 62) #f) (list 18 '(5 . 60) #f)) (fences))

;; A line comment ending in two backslashes: "int a;\n// c \\\\\nint b;\n".
;; The backslashes are 13 and 14; the newline 15.
(fresh "int a;\n// c \\\\\nint b;\n")
(c-clear-char-property 13 'syntax-table)
(c-clear-char-property 14 'syntax-table)
(set!c-new-BEG 1) (set!c-new-END (point-max))
(c-after-change-fix-comment-escapes 13 15 0)
(test-equal "the first of two backslashes at a // end is punctuation"
  (list (list 13 '(1) #f)) (fences))

(c-clear-char-property 13 'syntax-table)
(c-clear-char-property 14 'syntax-table)
(c-put-syntax-table-trim-caches 13 '(1))
(c-put-syntax-table-trim-caches 14 '(1))
(set!c-new-BEG 1) (set!c-new-END (point-max))
(c-before-change-fix-comment-escapes 15 15)
(test-equal "before the change only the first marker is cleared"
  (list (list 14 '(1) #f)) (fences))
(test-equal "... and the region is extended" (list 1 23)
  (list (c-new-BEG) (c-new-END)))

;; A block comment with a backslash before its terminator:
;; "int a;\n/* c \\*/\nint b;\n" - the backslash is 13.
(fresh "int a;\n/* c \\*/\nint b;\n")
(c-clear-char-property 13 'syntax-table)
(set!c-new-BEG 1) (set!c-new-END (point-max))
(c-after-change-fix-comment-escapes 13 15 0)
(test-equal "a backslash before */ is punctuation" (list (list 13 '(1) #f)) (fences))

(set!c-new-BEG 1) (set!c-new-END (point-max))
(c-before-change-fix-comment-escapes 13 15)
(test-equal "before the change it is cleared again" '() (fences))

(test-end "schemacs_editor_cc_mode_include_comment_escapes")


;;--------------------------------------------------------------
;; The quote parsing (`cc-mode.el:1785'-`:2020')
;;--------------------------------------------------------------
;; Every expectation is Emacs 31.1's. The query functions were
;; differentialled at every position of the fixture to build these rows.
(test-begin "schemacs_editor_cc_mode_quotes")

(define quote-fixture
  "int a = 4'294'967'295;\nint h = 0x1'2'3;\nint b = 1'2;\nchar c = 'x'; char d = '\\n'; int e = 1;\n")

(define (quote-row at)
  ;; The five values of one position: straddling (flag, start, end),
  ;; the tail after point, and the head before point.
  (goto-char at)
  (let ((st (c-quoted-number-straddling-point)))
    (list (if st #t #f)
          (and st (match-beginning 0))
          (and st (match-end 0))
          (c-quoted-number-tail-after-point)
          (c-quoted-number-head-before-point))))

(define (quote-props)
  (let loop ((p 1) (acc '()))
    (if (> p (point-max)) (reverse acc)
        (let ((st (get-text-property p 'syntax-table))
              (ds (get-text-property p 'c-digit-separator)))
          (if (or st ds)
              (loop (+ p 1) (cons (list p st ds) acc))
              (loop (+ p 1) acc))))))

(fresh quote-fixture)
(test-equal "on a digit separator the number straddles point"
  '(#t 9 22 22 9) (quote-row 10))
(test-equal "inside a quoted run the straddled number is the same"
  '(#t 9 22 22 9) (quote-row 12))
(test-equal "on a number's first digit nothing straddles"
  '(#f #f #f 22 #f) (quote-row 9))
(test-equal "a hex number quoted the same way"
  '(#t 32 39 39 32) (quote-row 35))
(test-equal "a two-digit quoted number"
  '(#t 49 52 52 49) (quote-row 50))
(test-equal "... and just after its separator no head precedes it"
  '(#t 49 52 52 #f) (quote-row 51))
(test-equal "a character literal is not a quoted number"
  '(#f #f #f #f #f) (quote-row 58))

;; The after-change parse marks every separator and nothing else.
(fresh quote-fixture)
(c-clear-syntax-table-with-value-on-char-trim-caches 1 (point-max) '(1) #\')
(c-clear-char-property-with-value-on-char 1 (point-max) 'c-digit-separator #t #\')
(set!c-new-BEG 1) (set!c-new-END (point-max))
(c-parse-quotes-after-change 1 (point-max) 0)
(test-equal "after a change the separators are punctuation and digit separators"
  (list (list 10 '(1) #t) (list 14 '(1) #t) (list 18 '(1) #t)
        (list 35 '(1) #t) (list 37 '(1) #t) (list 50 '(1) #t))
  (quote-props))
(test-equal "... and the region is unchanged" (list 1 94)
  (list (c-new-BEG) (c-new-END)))

;; The before-change parse strips them again.
(set!c-new-BEG 1) (set!c-new-END (point-max))
(c-parse-quotes-before-change 1 (point-max))
(test-equal "before a change the properties are removed" '() (quote-props))
(test-equal "... and the region is unchanged" (list 1 94)
  (list (c-new-BEG) (c-new-END)))

(test-end "schemacs_editor_cc_mode_quotes")
