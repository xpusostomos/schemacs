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
 (only (guile) hash-ref hash-set! make-hash-table hash-for-each sort string<?)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (schemacs buffer) allocate-buffer set-buffer current-buffer buffer-local-value
       set-buffer-local-value! buffer-z get-buffer-create with-current-buffer
       erase-buffer major-mode mode-name hook-value)
 (only (schemacs editfns) insert goto-char point point-min point-max widen
       save-restriction save-excursion buffer-substring)
 (only (schemacs search) match-beginning match-end)
 (only (schemacs syntax) set-syntax-table)
 (only (schemacs marker) marker-position)
 (only (schemacs insdel) *before-change-functions* *after-change-functions*)
 (only (schemacs textprop) get-text-property put-text-property
       remove-text-properties)
 (only (schemacs cmds) delete-char)
 (only (schemacs progmodes cc-defs) c-lang-const *c-buffer-is-cc-mode*
       c-clear-char-property c-get-char-property
       c-mark-<-as-paren c-mark->-as-paren
       c-clear-char-property-with-value-on-char)
 (schemacs progmodes cc-langs)
 (only (schemacs progmodes cc-styles) c-set-style)
 (only (schemacs progmodes cc-engine) c-found-types set!c-found-types
       c-add-type-1 c-clear-found-types
       c-new-id-start c-new-id-end c-new-id-is-type
       c-new-BEG set!c-new-BEG c-new-END set!c-new-END
       %c-langvar %c-lang-function
       c-maybe-stale-found-type c-old-END-literality
       c-ml-string-end-delim-disrupted c-macro-cache
       c-put-syntax-table-trim-caches c-clear-syn-tab-properties
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
       c-parse-quotes-before-change c-parse-quotes-after-change
       c-called-from-text-property-change-p
       c-locate-first-punctuation-prop
       c-depropertize-CPP c-extend-region-for-CPP c-depropertize-new-text
       c-extend-font-lock-region-for-macros
       c-neutralize-CPP-line c-neutralize-syntax-in-CPP
       c-before-change c-after-change c-just-done-before-change
       c-open-string-opener c-in-after-change-fontification
       c-fl-decl-start c-fl-decl-end
       c-doc-fl-decl-start c-doc-fl-decl-end c-change-expand-fl-region)
 (only (schemacs progmodes cc-engine) c-doc-line-join-re set!c-doc-line-join-re)
 (only (schemacs font-lock) set!font-lock-mode! font-lock-defaults
       set!font-lock-defaults! font-lock-ensure
       font-lock-extend-after-change-region-function)
 (only (schemacs font-core) font-lock-mode)
 (only (schemacs keymap) lookup-key keymapp)
 (only (schemacs subr) kbd)
 (only (schemacs syntax) char-syntax)
 (only (schemacs progmodes cc-cmds)
       c-indent-line c-indent-region c-do-auto-fill c-fill-paragraph
       c-mark-function c-electric-brace c-forward-conditional
       c-beginning-of-defun c-hungry-delete-forward)
 (only (schemacs progmodes cc-styles) c-set-style)
 (only (schemacs textmodes fill) fill-paragraph-function
       fill-paragraph-handle-comment normal-auto-fill-function-value)
 (only (schemacs newcomment) comment-start comment-end comment-start-skip
       comment-multi-line)
 (only (schemacs files) find-file-noselect)
 (only (schemacs progmodes cc-mode)
       c-mode c++-mode c-or-c++-mode c-mode-map c-mode-syntax-table
       c++-mode-map c++-mode-syntax-table c-mode-hook c++-mode-hook
       c-extend-after-change-region c-basic-common-init c-common-init
       c-font-lock-init c-initialize-cc-mode c-init-language-vars-for
       c-before-context-fl-expand-region c-font-lock-fontify-region
       c-c-menu c-c++-menu)
 (only (schemacs progmodes cc-fonts)
       c-force-redisplay *c-font-lock-fontify-region-function*))

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


;;--------------------------------------------------------------
;; `c-clear-syn-tab-properties' (`cc-defs.el:1444') and its seam
;;--------------------------------------------------------------
;; Emacs's macro lives in cc-mode here because the fence state does;
;; cc-engine reaches it through *c-clear-syn-tab-properties-function*.
(test-begin "schemacs_editor_cc_mode_clear_syn_tab")

(fresh "int a;\nchar *s = \"xy\";\nint b;\n")
(c-put-syn-tab 18 '(15))
(c-put-syn-tab 22 '(15))
(test-equal "the fences are in place first"
  (list (list 18 '(15) '(15)) (list 22 '(15) '(15))) (fences))
(c-clear-syn-tab-properties 1 (point-max))
(test-equal "clearing the syn-tab properties removes both kinds"
  '() (fences))
(test-equal "... and unsets the markers" '(#f #f) (mrk))

(test-end "schemacs_editor_cc_mode_clear_syn_tab")

;;--------------------------------------------------------------
;; `c-called-from-text-property-change-p' and the CPP propertizers
;; (`cc-mode.el:997'-`:1260')
;;--------------------------------------------------------------
;; Emacs answers the first by walking its own stack (`(backtrace-frame
;; 3)'); this tree binds `*in-property-change-p*' in `textprop.scm''s
;; `modify-text-properties', so the contract measured here is the same:
;; a property write's change hooks see t, an insertion's do not. (An
;; insertion here raises the hook twice - once for the text change and
;; once for the property graft, which is a property write - so the
;; test looks at the first call.)
(test-begin "schemacs_editor_cc_mode_cpp")

(let ((b (fresh "abc")))
  (let ((got #f))
    (parameterize ((*before-change-functions*
                    (list (lambda (beg end)
                            (set! got (c-called-from-text-property-change-p))))))
      (put-text-property 1 2 'face 'bold)
      (test-equal "a property write's hook sees the property-change flag"
        #t got))))

(let ((b (fresh "abc")))
  (let ((calls '()))
    (parameterize ((*before-change-functions*
                    (list (lambda (beg end)
                            (set! calls (cons (c-called-from-text-property-change-p)
                                              calls))))))
      (insert "x")
      (test-equal "an insertion's first hook call does not see it"
        #f (car (reverse calls))))))

(define cpp-fx (string-append "#define A (x\nint y;\n#define B R" (string #\")
                              "d(hi)d" (string #\") "\nint z;\n"))

(define (fresh-cpp text)
  (let ((b (allocate-buffer)))
    (set-buffer b)
    (insert text)
    (set-buffer-local-value! b 'major-mode 'c++-mode)
    (set-buffer-local-value! b 'parse-sexp-ignore-comments #t)
    (parameterize ((*c-buffer-is-cc-mode* 'c++-mode))
      (c-init-language-vars c++-mode)
      (set-syntax-table ((c-lang-const c-make-mode-syntax-table c++))))
    (let loop ((p 1))
      (when (<= p (1- (point-max)))
        (c-clear-char-property p 'syntax-table)
        (c-clear-char-property p 'c-fl-syn-tab)
        (loop (+ p 1))))
    b))

(define (cpp-props)
  (let loop ((p 1) (acc '()))
    (if (> p (1- (point-max)))
        (reverse acc)
        (let ((v (c-get-char-property p 'syntax-table)))
          (loop (+ p 1) (if v (cons (list p v) acc) acc))))))

(define (mark p) (c-put-syntax-table-trim-caches p '(1)))

;; A: a change inside the first macro depropertizes that whole macro
(fresh-cpp cpp-fx)
(for-each mark '(8 10 21 30 32 34 42))
(set!c-new-BEG 1) (set!c-new-END 48)
(c-depropertize-CPP 12 13)
(test-equal "c-depropertize-CPP clears the changed macro's punctuation"
  (list (list 1 48) (list (list 42 '(1))))
  (list (list (c-new-BEG) (c-new-END)) (cpp-props)))

;; A2: a raw string inside a macro is depropertized too
(fresh-cpp cpp-fx)
(for-each mark '(32 34 38 42))
(set!c-new-BEG 1) (set!c-new-END 48)
(c-depropertize-CPP 40 41)
(test-equal "... including a raw string inside the macro"
  (list (list 42 '(1))) (cpp-props))

;; B: the region grows to the macro's bounds
(fresh-cpp cpp-fx)
(set!c-new-BEG 5) (set!c-new-END 15)
(c-extend-region-for-CPP 5 15)
(test-equal "c-extend-region-for-CPP grows the region to the macro start"
  (list 1 15) (list (c-new-BEG) (c-new-END)))

(fresh-cpp cpp-fx)
(set!c-new-BEG 23) (set!c-new-END 26)
(c-extend-region-for-CPP 23 26)
(test-equal "... and at the other end to the macro's terminating newline"
  (list 21 41) (list (c-new-BEG) (c-new-END)))

;; C: the font-lock region is restricted to the macro
(fresh-cpp cpp-fx)
(set!c-new-BEG 1) (set!c-new-END 30)
(c-extend-font-lock-region-for-macros 1 30 0)
(test-equal "c-extend-font-lock-region-for-macros extends to the macro end"
  (list 1 40) (list (c-new-BEG) (c-new-END)))

(fresh-cpp cpp-fx)
(set!c-new-BEG 1) (set!c-new-END 10)
(c-extend-font-lock-region-for-macros 1 10 0)
(test-equal "... without shrinking, and bounded by the macro"
  (list 1 13) (list (c-new-BEG) (c-new-END)))

;; D: an unmatched ( on a macro line gets punctuation syntax
(fresh-cpp cpp-fx)
(c-neutralize-CPP-line 1 13)
(test-equal "c-neutralize-CPP-line marks the unmatched paren"
  (list (list 11 '(1))) (cpp-props))

;; E: ... and the region walk does it for every macro line
(fresh-cpp cpp-fx)
(set!c-new-BEG 1) (set!c-new-END 48)
(c-neutralize-syntax-in-CPP 1 48 0)
(test-equal "c-neutralize-syntax-in-CPP marks it through the region"
  (list (list 11 '(1))) (cpp-props))

;; F: new text loses the properties that would interfere
(fresh-cpp cpp-fx)
(for-each mark '(8 10 21 30 32 34 42))
(c-depropertize-new-text 21 40 19)
(test-equal "c-depropertize-new-text clears the new region only"
  (list (list 8 '(1)) (list 10 '(1)) (list 42 '(1))) (cpp-props))

;; G: the first punctuation property in a region, point unchanged
(fresh-cpp cpp-fx)
(for-each mark '(8 30))
(goto-char 48)
(test-equal "c-locate-first-punctuation-prop answers the first and keeps point"
  (list 8 48)
  (list (c-locate-first-punctuation-prop 1) (point)))

(fresh-cpp cpp-fx)
(goto-char 20)
(test-equal "... and nil when there is none"
  (list #f 20)
  (list (c-locate-first-punctuation-prop 1) (point)))

(test-end "schemacs_editor_cc_mode_cpp")

;;--------------------------------------------------------------
;; `c-before-change' (`cc-mode.el:2224')
;;--------------------------------------------------------------
;; Driven through the real hook, as cc-mode installs it, with the buffer
;; set up the way `c-common-init''s replay leaves it. Every expectation
;; is Emacs 31.1's answer for the same edit (the probes are
;; `/tmp/before-em.el' and `/tmp/before-ours.scm'); Emacs spells the two
;; nils `nil' where this tree spells them `#f' and `()'.
(test-begin "schemacs_editor_cc_mode_before_change")

(define before-fx
  (string-append "typedef int myint;\nmyint x;\n#define A (y\n"
                 "char *s = R" (string #\") "d(hi)d" (string #\") ";\n// c\n"))

(define (before-wipe!)
  (let loop ((p 1))
    (when (<= p (1- (point-max)))
      (remove-text-properties p (+ p 1)
        (list 'syntax-table #f 'c-fl-syn-tab #f 'category #f 'c-type #f
              'c-is-sws #f 'c-in-sws #f))
      (loop (+ p 1)))))

(define (before-buffer)
  (let ((b (allocate-buffer)))
    (set-buffer b)
    (insert before-fx)
    (set-buffer-local-value! b 'major-mode 'c++-mode)
    (set-buffer-local-value! b 'parse-sexp-ignore-comments #t)
    (c-init-language-vars c++-mode)
    (set-syntax-table ((c-lang-const c-make-mode-syntax-table c++)))
    (before-wipe!)
    (set!c-found-types (make-hash-table))
    (c-add-type-1 13 18)               ; "myint"
    (save-restriction
      (widen)
      (set!c-new-BEG (point-min)) (set!c-new-END (point-max))
      (save-excursion
        (parameterize ((*before-change-functions* '()))
          (for-each (lambda (fn)
                      ((%c-lang-function fn) (point-min) (point-max)))
                    (%c-langvar 'c-get-state-before-change-functions))
          (before-wipe!))))
    b))

(define (found-types)
  (let ((h (c-found-types)) (acc '()))
    (hash-for-each (lambda (k v) (set! acc (cons k acc))) h)
    (sort acc string<?)))

(define (before-props)
  (let loop ((p 1) (acc '()))
    (if (> p (1- (point-max)))
        (reverse acc)
        (let ((v (get-text-property p 'syntax-table)))
          (loop (+ p 1) (if v (cons (list p v) acc) acc))))))

(define (before-report)
  (list (c-new-BEG) (c-new-END) (c-just-done-before-change)
        (c-maybe-stale-found-type) (c-open-string-opener)
        c-old-END-literality (found-types) (before-props)))

(define (before-edit beg text)
  (goto-char beg)
  (parameterize ((*before-change-functions* (list c-before-change)))
    (if text (insert text) (delete-char 1))
    (before-report)))

(test-equal "typing inside an identifier drops it from the found types"
  (list 14 14 #t #f #f #f '() '())
  (begin (before-buffer) (before-edit 14 "z")))

(test-equal "a change in a macro extends the region over the whole macro"
  (list 29 43 #t #f #f #f '("myint") '())
  (begin (before-buffer) (before-edit 30 #f)))

(test-equal "a change at a raw string's end records the literal and the region"
  (list 52 61 #t #f #f 'string '("myint") '())
  (begin (before-buffer) (before-edit 60 (string #\"))))

(test-equal "a change at the start of the buffer clears the found types"
  (list 1 1 #t #f #f #f '() '())
  (begin (before-buffer) (before-edit 1 "x")))

(test-equal "deleting the typedef prefix clears them too"
  (list 1 2 #t #f #f #f '() '())
  (begin (before-buffer) (before-edit 1 #f)))

(test-equal "a c-type property beside the change is recorded as possibly stale"
  (list 20 20 #t '(c-decl-id-start #f 20 27 "myint x" "") #f #f
        '("myint") '())
  (begin (before-buffer)
         (put-text-property 19 20 'c-type 'c-decl-id-start)
         (before-edit 20 "z")))

(test-end "schemacs_editor_cc_mode_before_change")

;;--------------------------------------------------------------
;; The font-lock region expanders (`cc-mode.el:2448'-`:2665')
;;--------------------------------------------------------------
;; Every expectation is Emacs 31.1's answer for the same fixture (the
;; whole-position differential is `/tmp/fldecl-em.el' against
;; `/tmp/fldecl-ours.scm': 370 rows, identical). The calls bind
;; `*c-buffer-is-cc-mode*' as `c-basic-common-init' will, because
;; `c-major-mode-is' reads it.
(test-begin "schemacs_editor_cc_mode_fldecl")

(define fl-fxc
  (string-append "int f (void)\n{\n  int a = 1;\n  {\n    char *p;\n  }\n"
                 "  x = (a +\n       b);\n}\n"))
(define fl-fxcpp
  (string-append "void f ()\n{\n  auto l = [x] (int y) { return x + y; };\n"
                 "  std::vector<int> v;\n}\n"))

(define (fl-buffer text mode)
  (let ((b (allocate-buffer)))
    (set-buffer b)
    (insert text)
    (set-buffer-local-value! b 'major-mode mode)
    (set-buffer-local-value! b 'parse-sexp-ignore-comments #t)
    (if (eq? mode 'c-mode)
        (begin
          (c-init-language-vars c-mode)
          (set-syntax-table ((c-lang-const c-make-mode-syntax-table c))))
        (begin
          (c-init-language-vars c++-mode)
          (set-syntax-table ((c-lang-const c-make-mode-syntax-table c++)))))
    (c-clear-found-types)
    (let loop ((p 1))
      (when (<= p (1- (point-max)))
        (remove-text-properties p (+ p 1)
          (list 'syntax-table #f 'c-fl-syn-tab #f 'category #f 'c-type #f
                'c-is-sws #f 'c-in-sws #f))
        (loop (+ p 1))))
    b))

(define (fl-row fun pos mode)
  (parameterize ((*c-buffer-is-cc-mode* mode))
    (goto-char pos)
    (let ((ans (fun pos)))
      (list ans (point)))))

(fl-buffer fl-fxc 'c-mode)
(test-equal "c-fl-decl-start on the open brace line answers the header"
  (list 1 1) (fl-row c-fl-decl-start 14 'c-mode))
(test-equal "... and inside a continued statement the declaration's start"
  (list 52 49) (fl-row c-fl-decl-start 65 'c-mode))
(test-equal "c-fl-decl-end after a function header answers the arglist end"
  (list 15 15) (fl-row c-fl-decl-end 7 'c-mode))
(test-equal "... and nil where there is no declarator"
  (list #f 45) (fl-row c-fl-decl-end 46 'c-mode))

(fl-buffer fl-fxcpp 'c++-mode)
(test-equal "c-fl-decl-start in a C++ function header answers its start"
  (list 1 1) (fl-row c-fl-decl-start 11 'c++-mode))
(test-equal "c-fl-decl-end on the C++ header's identifier answers the arglist"
  (list 12 12) (fl-row c-fl-decl-end 7 'c++-mode))
(test-equal "... and after a declarator's id, the following token"
  (list 23 23) (fl-row c-fl-decl-end 21 'c++-mode))

;; The doc-comment pair. Emacs's mode init leaves `c-doc-line-join-re' at
;; `regexp-unmatchable' until font locking sets it, so the tests set it,
;; as the differential did on both sides.
(fl-buffer (string-append "int f ()\n{\n  /** first line\n   * continued\n"
                          "   */\n  g ();\n}\n")
           'c-mode)
(set!c-doc-line-join-re "^[ \t]*\\(\\*\\|//+\\)")
(test-equal "c-doc-fl-decl-start on a continuation line answers the doc start"
  (list 29 29) (fl-row c-doc-fl-decl-start 30 'c-mode))
(test-equal "c-doc-fl-decl-end there answers the line after the doc"
  (list 50 48) (fl-row c-doc-fl-decl-end 30 'c-mode))

(fl-buffer fl-fxc 'c-mode)
(set!font-lock-mode! #t)
(for-each
 (lambda (case)
   (let ((pair (car case)))
     (set!c-new-BEG (car pair)) (set!c-new-END (cadr pair))
     (parameterize ((*c-buffer-is-cc-mode* 'c-mode))
       (c-change-expand-fl-region 1 2 3))
     (test-equal (list 'change-expand pair)
       (cadr case)
       (list (c-new-BEG) (c-new-END)))))
 (list (list '(10 12) '(1 14))
       (list '(6 8) '(1 15))
       (list '(20 24) '(16 25))
       (list '(30 40) '(29 46))))

(test-end "schemacs_editor_cc_mode_fldecl")

;;--------------------------------------------------------------
;; `c-after-change' (`cc-mode.el:2364')
;;--------------------------------------------------------------
;; Driven through both real hooks, as the mode installs them. Every
;; expectation is Emacs 31.1's answer for the same edit (the seven-edit
;; differential is `/tmp/after-em.el' against `/tmp/after-ours.scm',
;; identical).
(test-begin "schemacs_editor_cc_mode_after_change")

(define (after-report)
  (list (c-new-BEG) (c-new-END) (c-just-done-before-change)
        (c-in-after-change-fontification) (c-maybe-stale-found-type)
        (c-open-string-opener)
        (if c-ml-string-end-delim-disrupted #t #f)
        (found-types) (c-macro-cache)
        (buffer-substring (point-min) (point-max))
        (before-props)))

(define (after-edit beg text)
  (goto-char beg)
  (parameterize ((*before-change-functions* (list c-before-change))
                 (*after-change-functions* (list c-after-change))
                 (*c-buffer-is-cc-mode* 'c++-mode))
    (if text (insert text) (delete-char 1))
    (after-report)))

(test-equal "typing inside an identifier: the region and the found types"
  (list 14 15 #f #t #f #f #f '()
        #f
        (string-append "typedef int mzyint;\nmyint x;\n#define A (y\n"
                       "char *s = R" (string #\") "d(hi)d" (string #\") ";\n// c\n")
        '())
  (begin (before-buffer) (after-edit 14 "z")))

(test-equal "deleting in a macro records its cache and extends the region"
  (list 29 42 #f #t #f #f #f '("myint")
        '(29 . 40)
        (string-append "typedef int myint;\nmyint x;\n#efine A (y\n"
                       "char *s = R" (string #\") "d(hi)d" (string #\") ";\n// c\n")
        '((38 (1))))
  (begin (before-buffer) (after-edit 30 #f)))

(test-equal "a quote at a raw string's end records the opener and disruption"
  (list 52 69 #f #t #f 61 #t '("myint")
        #f
        (string-append "typedef int myint;\nmyint x;\n#define A (y\n"
                       "char *s = R" (string #\") "d(hi)d" (string #\") (string #\")
                       ";\n// c\n")
        '((61 (1))))
  (begin (before-buffer) (after-edit 60 (string #\"))))

(test-equal "deleting the typedef prefix clears the found types"
  (list 1 1 #f #t #f #f #f '()
        #f
        (string-append "ypedef int myint;\nmyint x;\n#define A (y\n"
                       "char *s = R" (string #\") "d(hi)d" (string #\") ";\n// c\n")
        '())
  (begin (before-buffer) (after-edit 1 #f)))

(test-end "schemacs_editor_cc_mode_after_change")

;; ------------------------------------------------------------------
;; The mode definitions (`cc-mode.el:2860'-`:3040')
;;
;; Every answer here is Emacs 31.1's, measured with `emacs -Q --batch'
;; in a real `c-mode' buffer first:
;;
;;   mode=c-mode name="C/*l"
;;   comment-start="/* " end=" */" skip="\\(?://+\\|/\\*+\\)\\s *"
;;   indent-line=c-indent-line indent-region=c-indent-region ppps-ignore=t
;;   fill-fn=c-fill-paragraph normal-af=c-do-auto-fill multi=t
;;   require-nl=t
;;   keys=C-M-h->c-mark-function {->c-electric-brace
;;        C-c C-n->c-forward-conditional M-C-a->c-beginning-of-defun
;;        C-c .->c-set-style
;;   syntax: / 46, * 46, { 40, _ 95, @ 46
;; ----------------------------------------------------------------
(test-begin "schemacs_editor_cc_mode_definitions")

(define (mode-buffer name text)
  (let ((b (get-buffer-create name)))
    (with-current-buffer b
      (erase-buffer)
      (insert text)
      (goto-char (point-min)))
    b))

(test-equal "c-mode's name and mode line are Emacs's"
  (list 'c-mode "C/*l")
  (let ((b (mode-buffer "mode-defs-1.c" "int x;\n")))
    (with-current-buffer b
      (c-mode)
      (list (major-mode) (mode-name)))))

(test-equal "c++-mode's name and mode line are Emacs's"
  (list 'c++-mode "C++//l")
  (let ((b (mode-buffer "mode-defs-2.cc" "int x;\n")))
    (with-current-buffer b
      (c++-mode)
      (list (major-mode) (mode-name)))))

(test-equal "the comment syntax is the language's"
  (list "/* " " */" "\\(?://+\\|/\\*+\\)\\s *")
  (let ((b (mode-buffer "mode-defs-3.c" "int x;\n")))
    (with-current-buffer b
      (c-mode)
      (list (comment-start) (comment-end) (comment-start-skip)))))

(test-equal "the mode installs its indentation, filling and comment functions"
  (list #t #t #t #t #t #t #t)
  (let ((b (mode-buffer "mode-defs-4.c" "int x;\n")))
    (with-current-buffer b
      (c-mode)
      (list (eq? (buffer-local-value b 'indent-line-function #f) c-indent-line)
            (eq? (buffer-local-value b 'indent-region-function #f) c-indent-region)
            (eq? (buffer-local-value b 'parse-sexp-ignore-comments #f) #t)
            (eq? (fill-paragraph-function) c-fill-paragraph)
            (eq? (fill-paragraph-handle-comment) #f)
            (eq? (normal-auto-fill-function-value) c-do-auto-fill)
            (comment-multi-line)))))

(test-equal "the mode asks for a final newline, as Emacs's c-require-final-newline does"
  #t
  (let ((b (mode-buffer "mode-defs-5.c" "int x;\n")))
    (with-current-buffer b
      (c-mode)
      (buffer-local-value b 'require-final-newline #f))))

(test-equal "the syntax table is c-mode's, character for character"
  ;; The tree's `char-syntax' answers the designator *character*
  ;; (Emacs answers its integer code); the classes are Emacs's.
  (list #\. #\. #\( #\_ #\.)
  (let ((b (mode-buffer "mode-defs-6.c" "int x;\n")))
    (with-current-buffer b
      (c-mode)
      (list (char-syntax #\/) (char-syntax #\*) (char-syntax #\{)
            (char-syntax #\_) (char-syntax #\@)))))

(test-equal "the mode's keymap binds the C commands"
  (list #t #t #t #t #t #t)
  (let ((b (mode-buffer "mode-defs-7.c" "int x;\n")))
    (with-current-buffer b
      (c-mode)
      (list (eq? (lookup-key c-mode-map (kbd "C-M-h")) c-mark-function)
            (eq? (lookup-key c-mode-map (kbd "{")) c-electric-brace)
            (eq? (lookup-key c-mode-map (kbd "C-c C-n")) c-forward-conditional)
            (eq? (lookup-key c-mode-map (kbd "M-C-a")) c-beginning-of-defun)
            (eq? (lookup-key c-mode-map (kbd "C-c .")) c-set-style)
            ;; Measured on Emacs 31.1: C-c C-d is the *forward* hungry
            ;; delete, despite the later `[?\C-c ?\d]' entries in
            ;; `cc-mode.el' naming the backward one.
            (eq? (lookup-key c-mode-map (kbd "C-c C-d"))
                 c-hungry-delete-forward)))))

(test-equal "the mode installs its change hooks and the font-lock region extender"
  (list #t #t #t)
  (let ((b (mode-buffer "mode-defs-8.c" "int x;\n")))
    (with-current-buffer b
      (c-mode)
      (list (and (memq c-before-change
                       (hook-value *before-change-functions*)) #t)
            (and (memq c-after-change
                       (hook-value *after-change-functions*)) #t)
            (eq? (font-lock-extend-after-change-region-function)
                 c-extend-after-change-region)))))

(test-equal "font-lock's defaults name the four c levels and c's syntax table fix"
  (list 4 2)
  (let ((b (mode-buffer "mode-defs-9.c" "int x;\n")))
    (with-current-buffer b
      (c-mode)
      (list (length (car (font-lock-defaults)))
            (length (list-ref (font-lock-defaults) 3))))))

(test-equal "a C buffer fontifies through the real mode"
  (list 'font-lock-type-face 'font-lock-function-name-face)
  (let ((b (mode-buffer "mode-defs-10.c" "int main (void)\n{\n  return 0;\n}\n")))
    (with-current-buffer b
      (c-mode)
      (font-lock-mode 1)
      (font-lock-ensure)
      (list (get-text-property 1 'face) (get-text-property 5 'face)))))

(test-equal "a .c file opens in c-mode through auto-mode-alist's autoload"
  'c-mode
  (let ((f "/tmp/sc-cc-mode-defs.c"))
    (with-output-to-file f
      (lambda () (display "int main (void) { return 0; }\n")))
    (with-current-buffer (find-file-noselect f)
      (major-mode))))

(test-equal "a .h file of C++ is c++-mode, and one of C is c-mode"
  '(c++-mode c-mode)
  (let ((f1 "/tmp/sc-cc-mode-defs-cpp.h") (f2 "/tmp/sc-cc-mode-defs-c.h"))
    (with-output-to-file f1 (lambda () (display "class Foo {\npublic:\n  int x;\n};\n")))
    (with-output-to-file f2 (lambda () (display "#include <stdio.h>\nint f(void);\n")))
    (list (with-current-buffer (find-file-noselect f1) (major-mode))
          (with-current-buffer (find-file-noselect f2) (major-mode)))))

(test-equal "c-or-c++-mode picks by content, as Emacs's regexp does"
  '(c-mode c++-mode)
  (let ((b1 (mode-buffer "mode-defs-11.c" "int f(void);\n"))
        (b2 (mode-buffer "mode-defs-12.c" "template <typename T>\nvoid f(T x) {}\n")))
    (list (with-current-buffer b1 (c-or-c++-mode) (major-mode))
          (with-current-buffer b2 (c-or-c++-mode) (major-mode)))))

(test-equal "the context-fontification seam is installed"
  #t
  (let ((b (mode-buffer "mode-defs-8.c" "int x;\n")))
    (with-current-buffer b
      (c-mode)
      (eq? (*c-font-lock-fontify-region-function*) c-font-lock-fontify-region))))

(test-equal "c-before-context-fl-expand-region resolves the language function"
  (list #f (cons 1 7))
  (let ((b (mode-buffer "mode-defs-9.c" "int x;\n")))
    (with-current-buffer b
      (c-mode)
      ;; `c-force-redisplay' used to raise "`c-font-lock-fontify-region'
      ;; is not yet initialised" (the seam was never installed), and the
      ;; expansion used to raise "Wrong type to apply:
      ;; c-context-expand-fl-region" (the language constant holds the
      ;; symbol; Emacs funcalls it through the obarray).
      (list (c-force-redisplay (current-buffer) 1 6)
            (c-before-context-fl-expand-region 4 6)))))

(test-equal "context expansion widens to the whole declaration, as Emacs's does"
  (cons 16 25)
  (let ((b (mode-buffer "mode-defs-10.c"
                        "int f (void)\n{\n  int y;\n  return 0;\n}\n")))
    (with-current-buffer b
      (c-mode)
      (c-before-context-fl-expand-region 20 24))))

(test-end "schemacs_editor_cc_mode_definitions")

;;----------------------------------------------------------------------
;; The mode menus (`cc-mode.el:2880', `:3007')
;;----------------------------------------------------------------------
;; The `c-mode-menu' constant is Emacs's, less the items whose commands
;; this tree does not have (named in cc-langs' comment): a menu item
;; naming a missing command signals when it is clicked. These pin the
;; data and the two bindings, not the drawing; the terminal battery's
;; `c-menu' check is the end-to-end one.
(define (menu-labels menu)
  (let loop ((l menu) (acc '()))
    (cond ((null? l) (reverse acc))
          ((string? (car l)) (loop (cdr l) (cons (car l) acc)))
          ((vector? (car l))
           (loop (cdr l) (cons (vector-ref (car l) 0) acc)))
          (else (loop (cdr l) acc)))))

(test-begin "schemacs_editor_cc_mode_menu")
(let ((menu (c-lang-const c-mode-menu c)))
  (test-equal "the first item is Comment Out Region"
              "Comment Out Region" (vector-ref (car menu) 0))
  (test-assert "the cpp items are present for a language with a preprocessor"
               (member "Backslashify" (menu-labels menu)))
  (let* ((toggle (car (reverse menu)))
         (item (car (cdr toggle))))
    (test-equal "the Toggle submenu's first item is Syntactic indentation"
                "Syntactic indentation" (vector-ref item 0))
    (test-equal "whose :selected is the accessor call, not the variable"
                '(c-syntactic-indentation) (vector-ref item 5))
    (test-equal "and whose style is toggle"
                'toggle (vector-ref item 3))))

(let ((menu (c-lang-const c-mode-menu awk)))
  (test-assert "awk, with no preprocessor, has no Backslashify item"
               (not (member "Backslashify" (menu-labels menu)))))

(test-assert "c-c-menu is a keymap" (keymapp c-c-menu))
(test-assert "the C menu is bound in c-mode-map under [menu-bar c]"
             (keymapp (lookup-key c-mode-map (vector 'menu-bar 'c))))
(test-assert "c-c++-menu is a keymap" (keymapp c-c++-menu))
(test-assert "and bound in c++-mode-map"
             (keymapp (lookup-key c++-mode-map
                                  (vector 'menu-bar (string->symbol "c++")))))
(test-end "schemacs_editor_cc_mode_menu")
