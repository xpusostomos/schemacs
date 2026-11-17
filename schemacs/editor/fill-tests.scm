;; -*- mode: scheme; -*-
;; Tests for `(schemacs editor fill)' - GNU Emacs's `textmodes/fill.el'.
;;
;; **Every expectation below is Emacs 31.1's own answer**, produced by
;; running the same text through `emacs -Q --batch' with the same
;; `fill-column' and comparing the bytes. The whole-paragraph cases were
;; the differential harness that found the port's bugs; they stay here so
;; a regression shows up as a diff rather than as a "looks wrong".

(import (scheme base) (scheme write) (srfi 64)
        (only (schemacs editor buffer)
              allocate-buffer set-buffer buffer-fill-column
              set!buffer-fill-column *current-buffer*)
        (only (schemacs editor editfns)
              buffer-string point-min point-max goto-char insert
              point-marker char-after save-excursion
              buffer-substring)
        (only (schemacs editor fill)
              fill-region fill-paragraph unfill-paragraph
              fill-individual-paragraphs canonically-space-region
              current-fill-column fill-context-prefix fill-nobreak-p)
        ;; `fill-comment-paragraph` needs a mode that sets a comment
        ;; syntax - `scheme-mode` is the one this tree has.
        (only (schemacs editor scheme) scheme-mode))

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
