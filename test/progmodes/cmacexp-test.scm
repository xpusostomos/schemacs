(import
 (scheme base)
 (scheme write)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (guile) setvbuf)
 (only (schemacs buffer) allocate-buffer set-buffer rename-buffer
       current-buffer)
 (only (schemacs editfns) insert point-max point buffer-string)
 (only (schemacs progmodes cmacexp)
       c-macro-expand c-macro-expansion c-macro-buffer-name
       *c-macro-preprocessor* *c-macro-cppflags*))

;; Regression tests for `lisp/progmodes/cmacexp.el' as this tree ports
;; it - `cmacexp.scm'.
;;
;; **Every expectation here is Emacs 31.1's own**, measured with
;; `emacs -Q --batch -l cmacexp` on the same text and the same
;; CPPCOMMAND. The answer's spelling depends on the preprocessor, so
;; the machinery cases pass a command that is *not* a preprocessor:
;;
;;   * `cat' - the region comes back unchanged, so the test sees the
;;     start marker's removal, the `#line' insertion, and what the
;;     function returns around them;
;;   * `false' - no output at all, Emacs's "Preprocessor produced no
;;     output" branch;
;;   * a shell snippet that writes to stderr and exits 3 - the error
;;     comment inserted at the top, which is the only path that reads
;;     the stderr temp file.
;;
;; One case uses the real `cpp -C', because that is the feature.
;;
;; The buffer must be named `cmxtest', not for a reason of the test's:
;; `c-macro-expansion' puts `(buffer-name inbuf)' in its `#line'
;; directives (a buffer visiting a file uses the file's name instead),
;; and the expected strings carry that name.

(setvbuf (current-output-port) 'none)

(define (expansion text end command)
  ;; The expansion of [1, END) in a fresh buffer named `cmxtest'.
  (let ((buffer (allocate-buffer)))
    (set-buffer buffer)
    (insert text)
    (rename-buffer "cmxtest")
    (c-macro-expansion 1 end command)))

(define (string-has-substring? s sub)
  (let ((n (string-length s))
        (m (string-length sub)))
    (let loop ((i 0))
      (cond ((> (+ i m) n) #f)
            ((string=? (substring s i (+ i m)) sub) #t)
            (else (loop (+ i 1)))))))

(test-begin "schemacs_editor_cmacexp")

;;--------------------------------------------------------------
;; The variables (`cmacexp.el:69').
;;--------------------------------------------------------------
(test-equal "the work buffer is *Macroexpansion*"
            "*Macroexpansion*" c-macro-buffer-name)
(test-equal "the preprocessor's flags start empty" "" (*c-macro-cppflags*))
(test-assert "the preprocessor keeps its -C option, which the docstring demands"
             (string-has-substring? (*c-macro-preprocessor*) "-C"))

;;--------------------------------------------------------------
;; `c-macro-expansion' with a command that is not a preprocessor. The
;; command is applied to [1, END); END below is the third argument.
;;--------------------------------------------------------------
(test-equal "cat: the expansion starts after the removed start marker"
            "\n#line 1 \"cmxtest\"\n"
            (expansion "int a;\nint b;\n" 1 "cat"))

(test-equal "cat: the region's text follows the marker's line"
            "\n#line 1 \"cmxtest\"\nint a;\n"
            (expansion "int a;\nint b;\n" 8 "cat"))

(test-equal "false: no output is Emacs's own message"
            "\nPreprocessor produced no output"
            (expansion "int a;\nint b;\n" 1 "false"))

;; The error comment: stderr is read back from the temp file through
;; `insert-file-contents', inserted between the header and the closing
;; `*/' - the blank lines are Emacs's, and one of them is `echo's.
(test-equal "a failing preprocessor's stderr becomes a comment at the top"
            "/* Preprocessor terminated with status 3\n\n   Messages from 'cat; echo boom >&2; exit 3':\n\nboom\n\n\n*/\n\n#line 1 \"cmxtest\"\n"
            (expansion "int a;\nint b;\n" 1 "cat; echo boom >&2; exit 3"))

;;--------------------------------------------------------------
;; `c-macro-expand' (the command) with SUBST non-nil: the region is
;; replaced by the expansion. The point is `exchange-point-and-mark'd
;; only when it was at START.
;;--------------------------------------------------------------
(test-equal "the command's SUBST path replaces the region"
              (list "\n\nint x = 42;" 14)
            (let ((buffer (allocate-buffer)))
              (set-buffer buffer)
              (insert "#define FOO 42\nint x = FOO;\n")
              (rename-buffer "cmxtest")
              (c-macro-expand 1 (point-max) #t)
              (list (buffer-string) (point))))

(test-end "schemacs_editor_cmacexp")
