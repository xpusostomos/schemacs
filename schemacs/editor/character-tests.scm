;; Tests for `(schemacs editor character)' and the width-aware half of
;; `(schemacs editor disp-table)'.
;;
;; These two things are one subject: how many *screen columns* a character
;; takes up, which is not how many characters it is written with. Getting
;; it wrong does not corrupt the buffer - the text is drawn, and the
;; terminal and the font both know the real width - so the symptom is
;; always a *position* being wrong: the cursor, the region fill, the mode
;; line's column, the continuation glyph. That is the class of bug the
;; pty battery sees and the unit suites did not, and these tests bring the
;; arithmetic under it.
;;
;; Every number below was taken from `emacs -Q --batch' rather than
;; reasoned out, because a width table is exactly the sort of table that is
;; plausible and wrong:
;;
;;     (char-width ?\t) => 8    (char-width ?\n) => 0
;;     (char-width 20013) => 2  (char-width #x301) => 0
;;     (char-width #x1F600) => 2
;;-------------------------------------------------------------
(import
 (scheme base)
 (scheme char)
 (only (guile) setvbuf)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (prefix (schemacs editor character) c:)
 (prefix (schemacs editor disp-table) d:))

(setvbuf (current-output-port) 'none)

(test-begin "schemacs_editor_character")

;;------------------------------------------------------------------
;; `char-width': GNU Emacs's `character.c'
;;------------------------------------------------------------------

(test-equal 1 (c:char-width #\a))
(test-equal 1 (c:char-width #\space))
;; a tab is `tab-width' wide, and a newline does not occupy a column at all
(test-equal 8 (c:char-width #\tab))
(test-equal 0 (c:char-width #\newline))
;; a control character is two cells in caret notation, DEL included
(test-equal 2 (c:char-width (integer->char 1)))
(test-equal 2 (c:char-width (integer->char 127)))
;; the table: East Asian Wide, a combining mark, an emoji, Hangul Jamo
(test-equal 2 (c:char-width (integer->char #x4E2D)))   ; 中
(test-equal 0 (c:char-width (integer->char #x0301)))   ; combining acute
(test-equal 2 (c:char-width (integer->char #x1F600)))  ; emoji
(test-equal 2 (c:char-width (integer->char #x1100)))   ; Hangul Jamo
(test-equal 2 (c:char-width (integer->char #x3000)))   ; ideographic space
(test-equal 0 (c:char-width (integer->char #x200B)))   ; zero width space
;; and one that is in no range at all: the default is 1
(test-equal 1 (c:char-width (integer->char #x00A0)))   ; no-break space
(test-equal 1 c:char-width-default)

;; `tab-width' is read, not baked in: `CHARACTER_WIDTH' takes it from the
;; buffer, so a buffer with another tab width answers differently.
(test-equal 4 (parameterize ((c:*tab-width* 4)) (c:char-width #\tab)))

;; `sanitize_char_width' clamps a broken width rather than letting
;; redisplay allocate nonsense from it.
(test-equal 1000 (c:sanitize-char-width 1001))
(test-equal 1000 (c:sanitize-char-width -1))
(test-equal 7 (c:sanitize-char-width 7))

;;------------------------------------------------------------------
;; The display table: what a glyph *is* against what it *measures*
;;------------------------------------------------------------------

;; A glyph and its width are two different things, which is the whole
;; point: `char-display-glyph' of a wide character is one character.
(test-equal "中" (d:char-display-glyph (integer->char #x4E2D) 0))
(test-equal 2 (d:char-display-width (integer->char #x4E2D) 0))
;; a tab's glyph is its cells, so its length *is* its width
(test-equal 8 (string-length (d:char-display-glyph #\tab 0)))
(test-equal 8 (d:char-display-width #\tab 0))
(test-equal 3 (d:char-display-width #\tab 5))
;; a caret notation is two characters and two cells
(test-equal 2 (d:char-display-width (integer->char 13) 0))

;; Where each buffer column of a line is drawn. The wide character takes
;; two cells, so the character after it starts at 3 and not at 2.
(test-equal '(0 1 2 3) (d:line-display-offsets "abc"))
(test-equal '(0 1 8 9) (d:line-display-offsets "a\tb"))
(test-equal '(0 1 3 4) (d:line-display-offsets "x中y"))

;; The same line's glyphs, one per buffer character - the vector the
;; renderer slices runs out of.
(test-equal '("x" "中" "y")
  (d:expand-line-glyphs "x中y"))
(test-equal (d:expand-line-display "a\tb" 10000)
  (apply string-append (d:expand-line-glyphs "a\tb")))

;; The cursor sits on the character at point, so over a wide one it is two
;; cells; over a tab or a caret notation, which are several glyphs, it is
;; one. A character with no width of its own still gets a visible cursor.
(test-equal 2 (d:char-display-cursor-width (integer->char #x4E2D) 0))
(test-equal 1 (d:char-display-cursor-width #\tab 0))
(test-equal 1 (d:char-display-cursor-width (integer->char 13) 0))
(test-equal 1 (d:char-display-cursor-width (integer->char #x0301) 0))

(test-end "schemacs_editor_character")
