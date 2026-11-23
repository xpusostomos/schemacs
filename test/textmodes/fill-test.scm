;; -*- mode: scheme; -*-
;; Tests for `(schemacs textmodes fill)' - GNU Emacs's `textmodes/fill.el'.
;;
;; **Every expectation below is Emacs 31.1's own answer**, produced by
;; running the same text through `emacs -Q --batch' with the same
;; `fill-column' and comparing the bytes. The whole-paragraph cases were
;; the differential harness that found the port's bugs; they stay here so
;; a regression shows up as a diff rather than as a "looks wrong".

(import (scheme base) (scheme write) (srfi 64)
        (only (schemacs buffer)
              allocate-buffer set-buffer buffer-fill-column
              set!buffer-fill-column *current-buffer*
              set!buffer-left-margin local-variable-p kill-local-variable
              call-with-buffer-local)
        (only (schemacs textmodes paragraphs)
              *paragraph-start* paragraph-start set!paragraph-start)
        (only (schemacs editfns)
              buffer-string point-min point-max goto-char insert
              point-marker char-after save-excursion
              buffer-substring)
        (only (schemacs textmodes fill)
              fill-region fill-paragraph unfill-paragraph
              fill-individual-paragraphs canonically-space-region
              current-fill-column fill-context-prefix fill-nobreak-p
              auto-fill-mode)
        ;; `auto-fill-mode` is `internal_self_insert`'s caller, so the
        ;; test types the text rather than inserting it.
        (only (schemacs cmds) self-insert-command
              *post-self-insert-hook*)
        ;; `newline` and the two page options it reads.
        (only (schemacs simple) insert-newline
              *use-hard-newlines* *page-delimiter*)
        (only (schemacs textprop) get-text-property)
        (only (schemacs command) command-record-named
              command-procedure)
        ;; `fill-comment-paragraph` needs a mode that sets a comment
        ;; syntax - `scheme-mode` is the one this tree has.
        (only (schemacs progmodes scheme) scheme-mode)
        (only (schemacs newcomment) *comment-auto-fill-only-comments*
              *comment-multi-line*)
        (only (schemacs textmodes fill) comment-indent-new-line))

(define (with-text text)
  (let ((b (allocate-buffer)))
    (set-buffer b)
    (insert text)
    (goto-char (point-min))
    b))

(define (filled text)
  (let ((b (with-text text)))
    (set-buffer b)
    (fill-region (point-min) (point-max))
    (buffer-string)))

(test-begin "schemacs_editor_fill_region")

;; A plain paragraph joins its lines and wraps at 70. Every line below is Emacs 31.1's own.
(test-equal "This is a long line of text that should be wrapped at the fill column\nof this buffer because it is longer than seventy characters in total.\nAnd this is a second line in the same paragraph, so it joins the first\none before being wrapped again.\n\nThis is another paragraph, separate from the first one. It has two\nsentences. And a third.\n"
  (filled "This is a long line of text that should be wrapped at the fill column of this buffer because it is longer than seventy characters in total.\nAnd this is a second line in the same paragraph, so it joins the first one before being wrapped again.\n\nThis is another paragraph, separate from the first one. It has two sentences. And a third.\n"))

;; An indented paragraph keeps its indentation as the fill prefix.
(test-equal "  Indented paragraph line one, which is long enough to need wrapping\n  when it reaches the fill column of seventy characters.  Indented\n  paragraph line two, which also needs to be wrapped when it reaches\n  the column.\n"
  (filled "  Indented paragraph line one, which is long enough to need wrapping when it reaches the fill column of seventy characters.\n  Indented paragraph line two, which also needs to be wrapped when it reaches the column.\n"))

;; `sentence-end-double-space`: a period followed by ONE space is not a break
;; point, so a line whose every space follows a period is not broken at all.
(test-equal "One. Two. Three. Four. Five. Six. Seven. Eight. Nine. Ten. Eleven. Twelve. Thirteen. Fourteen. Fifteen. Sixteen.\n"
  (filled "One. Two. Three. Four. Five. Six. Seven. Eight. Nine. Ten. Eleven. Twelve. Thirteen. Fourteen. Fifteen. Sixteen.\n"))

;; Full justification spreads the extra spaces between the words.
(test-equal "This paragraph will be fully justified  so the words are spread out to\nboth margins evenly  and the extra spaces go between  the words rather\nthan at the end of the line.\n"
  (let ((b (with-text "This paragraph will be fully justified so the words are spread out to both margins evenly and the extra spaces go between the words rather than at the end of the line.\n")))
    (set-buffer b)
    (fill-region (point-min) (point-max) (quote full))
    (buffer-string)))

;; ... and centring pads on both sides.
(test-equal " This paragraph will be centred so every line has space on both sides\nof it and the text is balanced on the page in the middle of the column\n\t\t\t\twidth.\n"
  (let ((b (with-text "This paragraph will be centred so every line has space on both sides of it and the text is balanced on the page in the middle of the column width.\n")))
    (set-buffer b)
    (fill-region (point-min) (point-max) (quote center))
    (buffer-string)))

(test-end "schemacs_editor_fill_region")

;;--------------------------------------------------------------------
;; `fill-individual-paragraphs' and `unfill-paragraph'
;;--------------------------------------------------------------------

(test-begin "schemacs_editor_fill_individual")

;; A citation changes indentation; with the default
;; `fill-individual-varying-indent' nil the whole region is one paragraph.
(test-equal "foo> This line is a citation and it is long enough that it needs to be\nwrapped when it reaches the fill column.  foo> a second line of the\nsame citation which continues here.  bar>> This is a deeper citation\nthat is long enough to need wrapping at the fill column as well.\n"
  (let ((b (with-text "foo> This line is a citation and it is long enough that it needs to be wrapped when it reaches the fill column.\nfoo> a second line of the same citation which continues here.\nbar>> This is a deeper citation that is long enough to need wrapping at the fill column as well.\n")))
    (set-buffer b)
    (fill-individual-paragraphs (point-min) (point-max))
    (buffer-string)))

;; `unfill-paragraph' joins the lines back into one.
(test-equal "This paragraph has been wrapped already and it will be unwrapped so that the lines join back together into one long line again here.\n"
  (let ((b (with-text "This paragraph has been wrapped already and\nit will be unwrapped so that the lines join\nback together into one long line again here.\n")))
    (set-buffer b)
    (goto-char (point-min))
    (unfill-paragraph #f)
    (buffer-string)))

;; A comment is filled as a comment: the `;;` prefix is kept on every
;; line. Emacs 31.1 in `scheme-mode` gives exactly these bytes.
(test-equal ";; this is a very long comment line that should be filled by M-q when\n;; it is too long for the fill column of seventy characters\n"
  (let ((b (with-text ";; this is a very long comment line that should be filled by M-q when it is too long for the fill column of seventy characters\n")))
    (set-buffer b)
    (scheme-mode)
    (goto-char 10)
    (fill-paragraph #f #f)
    (buffer-string)))

(test-end "schemacs_editor_fill_individual")

;;--------------------------------------------------------------------
;; The pieces
;;--------------------------------------------------------------------

(test-begin "schemacs_editor_fill_pieces")

;; `current-fill-column' is the buffer's `fill-column' when no
;; `right-margin' property says otherwise.
(test-equal '(70 40)
  (let ((b (with-text "a line\n")))
    (set-buffer b)
    (let ((one (current-fill-column)))
      (set!buffer-fill-column b 40)
      (list one (current-fill-column)))))

;; `canonically-space-region' leaves one space between words and two at
;; a sentence end, and takes the tabs out.
(test-equal "One.  Two three four."
  (let ((b (with-text "One.  Two\t three   four.\n")))
    (set-buffer b)
    (canonically-space-region (point-min) (- (point-max) 1))
    (buffer-substring (point-min) (- (point-max) 1))))

;; `fill-context-prefix' takes the second line's indentation when the
;; first line is compatible with it.
(test-equal "  "
  (let ((b (with-text "  first line\n  second line\n")))
    (set-buffer b)
    (fill-context-prefix (point-min) (point-max))))

;; `fill-nobreak-p' at the space after "One." in "One. Two" ... and at a
;; space that is not after a period.
(test-equal '(#t #f)
  (let ((b (with-text "One. Two three four\n")))
    (set-buffer b)
    (list (save-excursion (goto-char 5) (fill-nobreak-p))
          (save-excursion (goto-char 10) (fill-nobreak-p)))))

(test-end "schemacs_editor_fill_pieces")

;;--------------------------------------------------------------------
;; Auto Fill mode
;;--------------------------------------------------------------------

(define (type-text text)
  (let loop ((i 0))
    (when (< i (string-length text))
      (self-insert-command 1 (char->integer (string-ref text i)))
      (loop (+ i 1)))))

(test-begin "schemacs_editor_fill_auto")

;; Emacs 31.1 with `auto-fill-mode' on and `fill-column' 20, typing the
;; same text one character at a time.
(test-equal "This is a long line\nof text that should\nwrap automatically\nwhen it passes the\nfill column."
  (let ((b (with-text "")))
    (set-buffer b)
    (auto-fill-mode 1)
    (set!buffer-fill-column b 20)
    (type-text "This is a long line of text that should wrap automatically when it passes the fill column.")
    (buffer-string)))

;; With the mode off the same typing does not wrap.
(test-equal "This is a long line of text that should wrap automatically when it passes the fill column."
  (let ((b (with-text "")))
    (set-buffer b)
    (set!buffer-fill-column b 20)
    (type-text "This is a long line of text that should wrap automatically when it passes the fill column.")
    (buffer-string)))

(test-end "schemacs_editor_fill_auto")

;;--------------------------------------------------------------------
;; A typed RET - `newline' (`simple.el:621')
;;--------------------------------------------------------------------
;;
;; `newline` is not a loop over `insert`: it calls `self-insert-command`
;; with the line break, so the break goes through `internal_self_insert`
;; like any typed character. Each expectation is Emacs 31.1's own answer
;; for the same buffer and the same call, measured with
;; `emacs -Q --batch` first.

(test-begin "schemacs_editor_fill_newline")

;; The long line is filled by the RET, then the RET's own break lands.
(test-equal "aaa bbb ccc ddd eee\nfff ggg hhh\n"
  (let ((b (with-text "")))
    (set-buffer b)
    (auto-fill-mode 1)
    (set!buffer-fill-column b 20)
    ;; `insert`, not `type-text`: Emacs's measurement was `(insert ...)`
    ;; then `(newline)`, and typing the text would auto-fill it on the
    ;; way in and leave nothing for the RET to fill.
    (insert "aaa bbb ccc ddd eee fff ggg hhh")
    (insert-newline)
    (buffer-string)))

;; A prefix argument inhibits the filling - Emacs's
;; `(let ((inhibit-auto-fill (or inhibit-auto-fill arg))) ...)'.
(test-equal "aaa bbb ccc ddd eee fff ggg hhh\n\n\n\n"
  (let ((b (with-text "")))
    (set-buffer b)
    (auto-fill-mode 1)
    (set!buffer-fill-column b 20)
    (insert "aaa bbb ccc ddd eee fff ggg hhh")
    (insert-newline 4 #t)
    (buffer-string)))

;; `post-self-insert-hook` runs after a typed character.
(test-equal "abc|"
  (let ((b (with-text "ab")))
    (set-buffer b)
    (goto-char (point-max))
    (parameterize ((*post-self-insert-hook*
                    (list (lambda () (insert "|")))))
      (self-insert-command 1 (char->integer #\c)))
    (buffer-string)))

;; A *programmatic* `(newline)' runs that hook's `newline` entry only, not
;; the caller's functions - the C's `(let ((post-self-insert-hook (list
;; postproc))) ...)'.
(test-equal "ab\n"
  (let ((b (with-text "ab")))
    (set-buffer b)
    (goto-char (point-max))
    (parameterize ((*post-self-insert-hook*
                    (list (lambda () (insert "|")))))
      (insert-newline))
    (buffer-string)))

;; An interactive RET does run them.
(test-equal "ab\n|"
  (let ((b (with-text "ab")))
    (set-buffer b)
    (goto-char (point-max))
    (parameterize ((*post-self-insert-hook*
                    (list (lambda () (insert "|")))))
      ((command-procedure (command-record-named "insert-newline")) #f))
    (buffer-string)))

;; With `use-hard-newlines' the break carries the `hard' property.
(test-equal #t
  (let ((b (with-text "ab")))
    (set-buffer b)
    (goto-char (point-max))
    (parameterize ((*use-hard-newlines* #t))
      (insert-newline))
    (get-text-property 3 'hard)))

;; A newline that leaves the previous line blank deletes its indentation,
;; and the new line is indented to the left margin.
(test-equal "\n  "
  (let ((b (with-text "   ")))
    (set-buffer b)
    (goto-char (point-max))
    (set!buffer-left-margin b 2)
    (insert-newline)
    (buffer-string)))

(test-equal "ab\n   "
  (let ((b (with-text "ab")))
    (set-buffer b)
    (goto-char (point-max))
    (set!buffer-left-margin b 3)
    (insert-newline)
    (buffer-string)))

;; ... unless the break is inserted at the beginning of a page.
(test-equal "\n\f\nx"
  (let ((b (with-text "\f\nx")))
    (set-buffer b)
    (set!buffer-left-margin b 3)
    (insert-newline)
    (buffer-string)))

(test-end "schemacs_editor_fill_newline")

;;--------------------------------------------------------------------
;; `comment-indent-new-line' - the comment continuation
;;--------------------------------------------------------------------
;;
;; Every expectation is Emacs 31.1's own bytes for the same text in
;; `scheme-mode', measured with `emacs -Q --batch'. It is `newcomment.el`'s
;; and lives in `fill.scm` - see the note there - and it is what
;; `comment-line-break-function' calls, so the auto-fill tests above are
;; its other caller.

(test-begin "schemacs_editor_fill_comment_line")

;; The plain case: the `;;` is repeated and the continuation column is
;; the comment's own.
(test-equal ";; hello world\n;; "
  (let ((b (with-text ";; hello world")))
    (set-buffer b)
    (scheme-mode)
    (goto-char (point-max))
    (comment-indent-new-line)
    (buffer-string)))

;; Split in the middle of a comment: the text after point keeps its
;; place and the starter is continued with no space added.
(test-equal ";;\n;;aaa bbb"
  (let ((b (with-text ";; aaa bbb")))
    (set-buffer b)
    (scheme-mode)
    (goto-char 4)
    (comment-indent-new-line)
    (buffer-string)))

;; `comment-multi-line' inserts no second starter.
(test-equal ";; aaa bbb\n;; "
  (let ((b (with-text ";; aaa bbb")))
    (set-buffer b)
    (scheme-mode)
    (goto-char (point-max))
    (parameterize ((*comment-multi-line* #t))
      (comment-indent-new-line))
    (buffer-string)))

;; A `;;;' comment keeps its three semicolons.
(test-equal ";;; doc line here\n;;; "
  (let ((b (with-text ";;; doc line here")))
    (set-buffer b)
    (scheme-mode)
    (goto-char (point-max))
    (comment-indent-new-line)
    (buffer-string)))

;; A comment after code continues at the left margin, not under the code.
(test-equal "(foo bar) ;; a comment\n;; "
  (let ((b (with-text "(foo bar) ;; a comment")))
    (set-buffer b)
    (scheme-mode)
    (goto-char (point-max))
    (comment-indent-new-line)
    (buffer-string)))

;; ... and one inside an indented body continues at the body's
;; indentation.
(test-equal "(define (f x)\n  ;; body comment\n  ;; "
  (let ((b (with-text "(define (f x)\n  ;; body comment")))
    (set-buffer b)
    (scheme-mode)
    (goto-char (point-max))
    (comment-indent-new-line)
    (buffer-string)))

;; Auto Fill now repeats the starter - `internal-self-insert` calls
;; `internal-auto-fill`, which is `do-auto-fill`, which calls
;; `default-indent-new-line`, which calls this. Emacs 31.1 with
;; `fill-column` 20 and the same text typed one character at a time.
(test-equal ";; aaa bbb ccc ddd\n;; eee fff "
  (let ((b (with-text "")))
    (set-buffer b)
    (scheme-mode)
    (set!buffer-fill-column b 20)
    (auto-fill-mode 1)
    (type-text ";; aaa bbb ccc ddd eee fff ")
    (buffer-string)))

;; `comment-auto-fill-only-comments' says no to a line that is not a
;; comment, and yes to one that is.
(test-equal "aaa bbb ccc ddd eee fff "
  (let ((b (with-text "")))
    (set-buffer b)
    (scheme-mode)
    (set!buffer-fill-column b 20)
    (auto-fill-mode 1)
    (parameterize ((*comment-auto-fill-only-comments* #t))
      (type-text "aaa bbb ccc ddd eee fff "))
    (buffer-string)))

(test-equal ";; aaa bbb ccc ddd\n;; eee fff "
  (let ((b (with-text "")))
    (set-buffer b)
    (scheme-mode)
    (set!buffer-fill-column b 20)
    (auto-fill-mode 1)
    (parameterize ((*comment-auto-fill-only-comments* #t))
      (type-text ";; aaa bbb ccc ddd eee fff "))
    (buffer-string)))

(test-end "schemacs_editor_fill_comment_line")

;;----------------------------------------------------------------------
;; The paragraph variables are buffer-local (`make-variable-buffer-local'
;; in `paragraphs.el'; measured on Emacs 31.1: after `setq' in one
;; buffer, `(default-value 'paragraph-start)' is unchanged and another
;; buffer still sees the standard value).
;;----------------------------------------------------------------------
(test-begin "schemacs_editor_fill_buffer_local")
(let ((b1 (allocate-buffer)))
  (set-buffer b1)
  (test-equal "a buffer with no local value reads the global"
              "\f\\|[ \t]*$" (paragraph-start))
  (set!paragraph-start "X")
  (test-equal "the buffer now has its own value" "X" (paragraph-start))
  (test-equal "and the global is untouched"
              "\f\\|[ \t]*$" (*paragraph-start*))
  (let ((b2 (allocate-buffer)))
    (set-buffer b2)
    (test-equal "another buffer still sees the global"
                "\f\\|[ \t]*$" (paragraph-start)))
  (set-buffer b1)
  (kill-local-variable 'paragraph-start)
  (test-equal "killing the slot restores the global"
              "\f\\|[ \t]*$" (paragraph-start))
  (test-equal "call-with-buffer-local binds the buffer's value and restores"
              (list "Y" "\f\\|[ \t]*$" #f)
              (let ((inside (call-with-buffer-local 'paragraph-start "Y"
                                                    (lambda () (paragraph-start)))))
                (list inside (paragraph-start)
                      (local-variable-p 'paragraph-start b1))))
  (set!paragraph-start "W")
  (test-equal "and restores a value the buffer already had"
              (list "Z" "W" #t)
              (let ((inside (call-with-buffer-local 'paragraph-start "Z"
                                                    (lambda () (paragraph-start)))))
                (list inside (paragraph-start)
                      (local-variable-p 'paragraph-start b1)))))
(test-end "schemacs_editor_fill_buffer_local")


