(define-library (schemacs editor paragraphs)
  ;; This library mirrors GNU Emacs's `textmodes/paragraphs.el': the
  ;; paragraph variables and motions, the sentence variables and
  ;; motions, and the kills and the mark that act on them.
  ;;
  ;; **This file's walks are the real ones now** (2026-11-17). They used
  ;; to test `paragraph-start`/`paragraph-separate`'s *default* meaning
  ;; line by line, because there was no regexp engine; `forward-paragraph`
  ;; and `backward-paragraph` are now `paragraphs.el:224` and `:366` whole
  ;; - the fill-prefix branch, `use-hard-newlines`, the `sp-parstart`
  ;; search and the `constrain-to-field` at the end.
  ;;
  ;; **Two placements are departures, both forced by the import graph.**
  ;; `fill-prefix` is `fill.el`'s defcustom and lives in `indent.scm`,
  ;; where the header says why; `sentence-end`'s variables are
  ;; paragraphs.el's and are here, as in Emacs.
  ;;
  ;; Not carried, each named with what it waits for:
  ;;
  ;;   * `use-hard-newlines`' *mode* (the `define-minor-mode`). The
  ;;     variable is here and is read by every branch that Emacs reads
  ;;     it in; the mode cannot be turned on because `:extra-args` is not
  ;;     a keyword this tree's `define-minor-mode` carries and
  ;;     `set-hard-newline-properties` is not ported. A buffer therefore
  ;;     never has a `hard` newline, so the branches are dead until that
  ;;     changes.
  ;;   * `paragraph-indent-minor-mode` and its abbrev table, which need
  ;;     `indent-relative` to be the default `indent-line-function`.
  ;;   * `transpose-paragraphs`, `transpose-sentences` (need
  ;;     `transpose-subr` with a motion function), `count-sentences`,
  ;;     `repunctuate-sentences` (needs `isearch-filter-predicate` and
  ;;     `query-replace-regexp`'s REGION arguments), `mark-end-of-sentence`
  ;;     (needs `push-mark`'s ACTIVATE and the repeat rule).
  ;;
  ;; See LAYOUT-PLAN.txt for the rule this library is a step of.

  (import
    ;; `kbd' - see `character.sld''s export note for why it is there
    (only (schemacs editor character) kbd)
    (scheme base)
    ;; `define-custom` - every variable in this file is a defcustom
    (only (schemacs editor custom) define-custom)
    (only (schemacs editor editfns)
          bobp bolp eobp point point-min point-max goto-char save-excursion
          forward-line preceding-char
          constrain-to-field char-after)
    (only (schemacs editor cmds)
          beginning-of-line end-of-line forward-char backward-char)
    ;; the margins - `move-to-left-margin` is what the walks' "at the
    ;; left margin" means (`paragraphs.el:262`, `:290`, `:315`)
    (only (schemacs editor indent)
          current-left-margin move-to-left-margin *fill-prefix*)
    (only (schemacs editor indentc) current-column)
    (only (schemacs editor search)
          looking-at match-beginning match-end re-search-backward
          re-search-forward regexp-quote)
    (only (schemacs editor syntax) skip-chars-forward skip-chars-backward)
    (only (schemacs editor textprop) get-text-property)
    ;; the line ends and the blank-line question are simple.sld's -
    ;; `paragraph-separate''s default is a blank line. The two page
    ;; options are Emacs's own here (`paragraphs.el`) but live in
    ;; `simple.scm` because `newline` reads them; they are imported and
    ;; re-exported.
    (only (schemacs editor simple)
          kill-region mark set-mark push-mark
          *page-delimiter* *use-hard-newlines*)
    ;; the mark-active and transient-mark-mode of the extend branch are
    ;; `buffer.c''s variables, beside `*last-command*' which is
    ;; simple.sld's (the command loop binds it there)
    (only (schemacs editor buffer)
          current-buffer mark-active transient-mark-mode
          buffer-beg buffer-z buffer-pt
          buffer-local-value set-buffer-local-value!)
    (only (schemacs editor simple) *last-command*)
    (only (schemacs editor command) current-prefix-arg define-command
          uarg->integer)
    (only (schemacs editor keymap) define-key *default-keymap*)
    )

  (export
   ;; the variables
   *paragraph-start* *paragraph-separate* *paragraph-ignore-fill-prefix*
   paragraph-start set!paragraph-start
   paragraph-separate set!paragraph-separate
   paragraph-ignore-fill-prefix set!paragraph-ignore-fill-prefix
   *use-hard-newlines* *page-delimiter*
   *sentence-end* *sentence-end-base* *sentence-end-double-space*
   *sentence-end-without-period* *sentence-end-without-space*
   sentence-end
   ;; the motions
   forward-paragraph backward-paragraph
   start-of-paragraph-text end-of-paragraph-text
   forward-sentence forward-sentence-default-function
   forward-sentence-function
   backward-sentence
   ;; the commands
   kill-paragraph backward-kill-paragraph mark-paragraph
   kill-sentence backward-kill-sentence
   )

  (begin

    (define-custom *paragraph-start* "\f\\|[ \t]*$"
      "Regexp for beginning of a line that starts OR separates paragraphs.
This regexp should match lines that separate paragraphs
and should also match lines that start a paragraph
\(and are part of that paragraph).

This is matched against the text at the left margin, which is not necessarily
the beginning of the line, so it should never use \"^\" as an anchor.  This
ensures that the paragraph functions will work equally well within a region
of text indented by a margin setting.

The variable `paragraph-separate' specifies how to distinguish
lines that start paragraphs from those that separate them.

If the variable `use-hard-newlines' is non-nil, then only lines following a
hard newline are considered to match."
      :type 'regexp
      :safe 'stringp
      :group 'paragraphs)

    ;; Emacs makes `paragraph-start' buffer-local (`make-variable-buffer-local):
    ;; the parameter is its default, the slot is the buffer's
    ;; value, and this pair is `symbol-value'/`set'. ELisp's
    ;; `let' of it is `call-with-buffer-local'.
    (define (paragraph-start)
      (buffer-local-value (current-buffer) 'paragraph-start (*paragraph-start*)))
    (define (set!paragraph-start value)
      (set-buffer-local-value! (current-buffer) 'paragraph-start value))

    (define-custom *paragraph-separate* "[ \t\f]*$"
      "Regexp for beginning of a line that separates paragraphs.
If you change this, you may have to change `paragraph-start' also.

This is matched against the text at the left margin, which is not necessarily
the beginning of the line, so it should not use \"^\" as an anchor.  This
ensures that the paragraph functions will work equally within a region
of text indented by a margin setting."
      :type 'regexp
      :safe 'stringp
      :group 'paragraphs)

    ;; Emacs makes `paragraph-separate' buffer-local (`make-variable-buffer-local):
    ;; the parameter is its default, the slot is the buffer's
    ;; value, and this pair is `symbol-value'/`set'. ELisp's
    ;; `let' of it is `call-with-buffer-local'.
    (define (paragraph-separate)
      (buffer-local-value (current-buffer) 'paragraph-separate (*paragraph-separate*)))
    (define (set!paragraph-separate value)
      (set-buffer-local-value! (current-buffer) 'paragraph-separate value))

    (define-custom *sentence-end-double-space* #t
      "Non-nil means a single space does not end a sentence.
This user option affects fill commands and sentence commands.

If this variable is non-nil, Emacs considers a period followed by two
spaces or by a newline as the end of a sentence."
      :type 'boolean
      :safe 'booleanp
      :group 'fill)

    (define-custom *sentence-end-without-period* #f
      "Non-nil means a sentence will end without a period.
For example, a sentence in Thai text ends with double space but
without a period."
      :type 'boolean
      :safe 'booleanp
      :group 'fill)

    (define-custom *sentence-end-without-space* "。．？！"
      "String of characters that end sentence without following spaces."
      :type 'string
      :group 'fill)

    (define-custom *sentence-end* #f
      "Regexp describing the end of a sentence.
The value includes the whitespace following the sentence.
All paragraph boundaries also end sentences, regardless.

The value nil means to use the default value defined by the
function `sentence-end'.  You should always use this function
to obtain the value of this variable."
      :type '(choice regexp (const :tag "Use default value" nil))
      :safe 'string-or-null-p
      :group 'paragraphs)

    (define-custom *sentence-end-base* "[.?!…‽][]\"'”’)}»›]*"
      "Regexp matching the basic end of a sentence, not including following space."
      :type 'regexp
      :safe 'stringp
      :group 'paragraphs)

    (define (sentence-end)
      ;; GNU Emacs's `sentence-end' (`paragraphs.el:190'): "Return the
      ;; regexp describing the end of a sentence.
      ;;
      ;; This function returns either the value of the variable
      ;; `sentence-end' if it is non-nil, or the default value constructed
      ;; from the variables `sentence-end-base', `sentence-end-double-space',
      ;; `sentence-end-without-period' and `sentence-end-without-space'."
      ;;
      ;; The C accepts a non-break space where it accepts a space, and the
      ;; built string is the measured one: `emacs -Q --batch' answers
      ;; "\\([.?!…‽][]\"'”’)}»›]*\\($\\|[  ]$\\|\t\\|[  ][  ]\\)\\|[。．？！]+\\)[  \t\n]*"
      ;; for the defaults.
      ;;--------------------------------------------------------------
      (or (*sentence-end*)
          (string-append
           (if (*sentence-end-without-period*) "\\w[\u00a0 ][\u00a0 ]\\|" "")
           "\\("
           (*sentence-end-base*)
           (if (*sentence-end-double-space*)
               "\\($\\|[ \u00a0]$\\|\t\\|[ \u00a0][ \u00a0]\\)"
               "\\($\\|[\t \u00a0]\\)")
           "\\|[" (*sentence-end-without-space*) "]+"
           "\\)"
           "[ \u00a0\t\n]*")))

    ;; `page-delimiter` and `use-hard-newlines` are **imported from
    ;; `simple.scm`**, not defined here: `simple.el`'s `newline` is their
    ;; lowest reader, and this library is above it. Emacs declares both
    ;; in `paragraphs.el`; the departure is the move, the same one
    ;; `*minor-mode-alist*` made into `subr.scm`. This library
    ;; re-exports them, so `pages.scm`, `lisp.scm` and `fill.scm` are
    ;; unchanged.

    (define-custom *paragraph-ignore-fill-prefix* #f
      "Non-nil means the paragraph commands are not affected by `fill-prefix'.
This is desirable in modes where blank lines are the paragraph delimiters."
      :type 'boolean
      :safe 'booleanp
      :group 'paragraphs)

    ;; Emacs makes `paragraph-ignore-fill-prefix' buffer-local (`make-variable-buffer-local):
    ;; the parameter is its default, the slot is the buffer's
    ;; value, and this pair is `symbol-value'/`set'. ELisp's
    ;; `let' of it is `call-with-buffer-local'.
    (define (paragraph-ignore-fill-prefix)
      (buffer-local-value (current-buffer) 'paragraph-ignore-fill-prefix (*paragraph-ignore-fill-prefix*)))
    (define (set!paragraph-ignore-fill-prefix value)
      (set-buffer-local-value! (current-buffer) 'paragraph-ignore-fill-prefix value))

    (define-command (forward-paragraph . args)
      "Move forward to end of paragraph.
With argument ARG, do it ARG times;
a negative argument ARG = -N means move backward N paragraphs.

A line which `paragraph-start' matches either separates paragraphs
\(if `paragraph-separate' matches it also) or is the first line of a paragraph.
A paragraph end is the beginning of a line which is not part of the paragraph
to which the end of the previous line belongs, or the end of the buffer.
Returns the count of paragraphs left to move."
      (interactive (list (uarg->integer 1 (current-prefix-arg))))
      ;; GNU Emacs's `forward-paragraph' (`paragraphs.el:224'): "Move
      ;; forward to end of paragraph. With argument ARG, do it ARG times;
      ;; a negative argument ARG = -N means move backward N paragraphs.
      ;;
      ;; A line which `paragraph-start' matches either separates
      ;; paragraphs (if `paragraph-separate' matches it also) or is the
      ;; first line of a paragraph.
      ;; ...
      ;; Returns the count of paragraphs left to move."
      ;;
      ;; The two `while' loops are named `let`s and the `if`s whose ELSE
      ;; branch is several forms are `when`s - Elisp's `if` takes ELSE...
      ;; and Scheme's takes one, so writing `if` here would nest a
      ;; `begin` into every arm. `cond` is not used for the same reason:
      ;; the arms are Emacs's `if`/`while` pair and the source should read
      ;; like it.
      ;;--------------------------------------------------------------
      (let* ((arg (let ((a (and (pair? args) (car args))))
                    (if a a 1)))
             (opoint (point))
             (fill-prefix-regexp
              (and (*fill-prefix*)
                   (not (equal? (*fill-prefix*) ""))
                   (not (paragraph-ignore-fill-prefix))
                   (regexp-quote (*fill-prefix*))))
             ;; "Remove ^ from paragraph-start and paragraph-sep if they
             ;; are there. These regexps shouldn't be anchored, because
             ;; we look for them starting at the left-margin. This
             ;; allows paragraph commands to work normally with indented
             ;; text. This hack will not find problem cases like
             ;; \"whatever\\|^something\"."
             (parstart (if (and (not (equal? "" (paragraph-start)))
                                (char=? #\^ (string-ref (paragraph-start) 0)))
                           (substring (paragraph-start) 1)
                           (paragraph-start)))
             (parsep (if (and (not (equal? "" (paragraph-separate)))
                              (char=? #\^ (string-ref (paragraph-separate) 0)))
                         (substring (paragraph-separate) 1)
                         (paragraph-separate)))
             (parsep (if fill-prefix-regexp
                         (string-append parsep "\\|"
                                        fill-prefix-regexp "[ \t]*$")
                         parsep))
             ;; "This is used for searching."
             (sp-parstart (string-append "^[ \t]*\\(?:" parstart "\\|"
                                         parsep "\\)")))
        (define start #f)
        (define found-start #f)

        ;;----------------------------------------------------------------
        ;; `(while (and (< arg 0) (not (bobp))) ...)'
        ;;----------------------------------------------------------------
        (let while-back ()
          (when (and (< arg 0) (not (bobp)))
            (if (and (not (looking-at parsep))
                     (re-search-backward "^\n"
                                         (max (- (point) 1) (point-min))
                                         #t)
                     (looking-at parsep))
                ;; "In this case we have a paragraph-separating line
                ;; immediately before the current paragraph." - the C's
                ;; `(setq arg (1+ arg))' arm.
                (set! arg (+ arg 1))
                (begin
                  (set! start (point))
                  ;; "Move back over paragraph-separating lines."
                  (forward-char -1)
                  (beginning-of-line 1)
                  (let skip ()
                    (when (and (not (bobp))
                               (begin (move-to-left-margin 1 #f)
                                      (looking-at parsep)))
                      (forward-line -1)
                      (skip)))
                  (unless (bobp)
                    (set! arg (+ arg 1))
                    ;; "Go to end of the previous (non-separating) line."
                    (end-of-line 1)
                    ;; "Search back for line that starts or separates
                    ;; paragraphs."
                    (if (if fill-prefix-regexp
                            ;; "There is a fill prefix; it overrides
                            ;; parstart."
                            (begin
                              (let skip2 ()
                                (when (and (begin (beginning-of-line 1)
                                                  (not (bobp)))
                                           (begin (move-to-left-margin 1 #f)
                                                  (not (looking-at parsep)))
                                           (looking-at fill-prefix-regexp))
                                  (forward-line -1)
                                  (skip2)))
                              (move-to-left-margin 1 #f)
                              (not (bobp)))
                            (let find ()
                              (if (and (re-search-backward sp-parstart #f 1)
                                       (begin
                                         (set! found-start #t)
                                         (set! start (point))
                                         (move-to-left-margin 1 #f)
                                         (not (looking-at parsep)))
                                       (not (and (looking-at parstart)
                                                 (or (not (*use-hard-newlines*))
                                                     (bobp)
                                                     (get-text-property
                                                      (- start 1) 'hard)))))
                                  (begin
                                    (set! found-start #f)
                                    (goto-char start)
                                    (find))
                                  found-start)))
                        ;; "Found one."
                        (begin
                          ;; "Move forward over paragraph separators. We
                          ;; know this cannot reach the place we started
                          ;; because we know we moved back over a
                          ;; non-separator."
                          (let skip3 ()
                            (when (and (not (eobp))
                                       (begin (move-to-left-margin 1 #f)
                                              (looking-at parsep)))
                              (forward-line 1)
                              (skip3)))
                          ;; "If line before paragraph is just margin,
                          ;; back up to there."
                          (end-of-line 0)
                          (if (> (current-column) (current-left-margin))
                              (forward-char 1)
                              (begin
                                (skip-chars-backward " \t")
                                (when (not (bolp))
                                  (forward-line 1)))))
                        ;; "No starter or separator line => use buffer
                        ;; beg."
                        (goto-char (point-min))))))
            (while-back)))

        ;;----------------------------------------------------------------
        ;; `(while (and (> arg 0) (not (eobp))) ...)'
        ;;----------------------------------------------------------------
        (let while-fwd ()
          (when (and (> arg 0) (not (eobp)))
            ;; "Move forward over separator lines..."
            (let skip ()
              (when (and (not (eobp))
                         (begin (move-to-left-margin 1 #f) (not (eobp)))
                         (looking-at parsep))
                (forward-line 1)
                (skip)))
            (when (not (eobp)) (set! arg (- arg 1)))
            ;; "... and one more line."
            (forward-line 1)
            (if fill-prefix-regexp
                ;; "There is a fill prefix; it overrides parstart."
                (let skip2 ()
                  (when (and (not (eobp))
                             (begin (move-to-left-margin 1 #f) (not (eobp)))
                             (not (looking-at parsep))
                             (looking-at fill-prefix-regexp))
                    (forward-line 1)
                    (skip2)))
                (begin
                  (let find ()
                    (when (and (re-search-forward sp-parstart #f 1)
                               (begin (set! start (match-beginning 0))
                                      (goto-char start)
                                      (not (eobp)))
                               (begin (move-to-left-margin 1 #f)
                                      (not (looking-at parsep)))
                               (or (not (looking-at parstart))
                                   (and (*use-hard-newlines*)
                                        (not (get-text-property
                                              (- start 1) 'hard)))))
                      (forward-char 1)
                      (find)))
                  (when (and start (< (point) (point-max)))
                    (goto-char start))))
            (while-fwd)))

        (constrain-to-field #f opoint #t)
        ;; "Return the number of steps that could not be done."
        arg))

    (define-command (backward-paragraph . args)
      "Move backward to start of paragraph.
With argument ARG, do it ARG times;
a negative argument ARG = -N means move forward N paragraphs.

A paragraph start is the beginning of a line which is a
`paragraph-start' or which is ordinary text and follows a
`paragraph-separate'ing line; except: if the first real line of a
paragraph is preceded by a blank line, the paragraph starts at that
blank line.

See `forward-paragraph' for more information."
      (interactive (list (uarg->integer 1 (current-prefix-arg))))
      ;; GNU Emacs's `backward-paragraph' (`paragraphs.el:366'): "Move
      ;; backward to start of paragraph. With argument ARG, do it ARG
      ;; times; a negative argument ARG = -N means move forward N
      ;; paragraphs."
      ;;--------------------------------------------------------------
      (let ((arg (let ((a (and (pair? args) (car args))))
                   (if a a 1))))
        (forward-paragraph (- arg))))

    (define (start-of-paragraph-text)
      ;; GNU Emacs's `start-of-paragraph-text' (`paragraphs.el:436'):
      ;; "Move to the start of the current paragraph."
      ;;--------------------------------------------------------------
      (let ((opoint (point)))
        (forward-paragraph -1)
        (let ((npoint (point)))
          (skip-chars-forward " \t\n")
          ;; "If the range of blank lines found spans the original start
          ;; point, try again from the beginning of it. Must be careful
          ;; to avoid infinite loop when following a single return at
          ;; start of buffer."
          (if (and (>= (point) opoint) (< npoint opoint))
              (begin
                (goto-char npoint)
                (if (> npoint (point-min))
                    (start-of-paragraph-text)))))))

    (define (end-of-paragraph-text)
      ;; GNU Emacs's `end-of-paragraph-text' (`paragraphs.el:452'):
      ;; "Move to the end of the current paragraph."
      ;;--------------------------------------------------------------
      (let ((opoint (point)))
        (forward-paragraph 1)
        (if (char=? (preceding-char) #\newline) (forward-char -1))
        (if (<= (point) opoint)
            (begin
              (forward-char 1)
              (if (< (point) (point-max))
                  (end-of-paragraph-text))))))

    (define-command (kill-paragraph arg)
      ;; GNU Emacs's `kill-paragraph' (`paragraphs.el:412'): "Kill
      ;; forward to end of paragraph. With ARG N, kill forward to Nth
      ;; end of paragraph; negative ARG -N means kill backward to Nth
      ;; start of paragraph."
      "Kill forward to end of paragraph."
      (interactive (list (uarg->integer 1 (current-prefix-arg))))
      (let* ((ed (current-buffer))
             (here (point)))
        ;; Emacs's `(progn (forward-paragraph arg) (point))': the motion
        ;; moves point, and it is point AFTER it that the kill runs to -
        ;; the motion's own answer is the count left undone, which is
        ;; not the position.
        (if (< arg 0)
            (backward-paragraph (- arg))
            (forward-paragraph arg))
        (let ((there (point)))
          (kill-region (min here there) (max here there)))))

    (define-command (backward-kill-paragraph arg)
      ;; GNU Emacs's `backward-kill-paragraph' (`paragraphs.el:419'):
      ;; "Kill back to start of paragraph."
      "Kill back to start of paragraph."
      (interactive (list (uarg->integer 1 (current-prefix-arg))))
      (kill-paragraph (- arg)))

    (define-command (mark-paragraph arg allow-extend)
      ;; GNU Emacs's `mark-paragraph' (`paragraphs.el:382'): "Put point at
      ;; beginning of this paragraph, mark at end." With ARG, mark ARG
      ;; paragraphs; repeated, or with the mark active, extend by ARG
      ;; more. The two parameters are the C's `"p\np"' interactive
      ;; spec's - the count, and ALLOW-EXTEND, which interactively is
      ;; true.
      "Put point at beginning of this paragraph, mark at end.
The paragraph marked is the one that contains point or follows point.

With argument ARG, puts mark at end of a following paragraph, so that
the number of paragraphs marked equals ARG.

If ARG is negative, point is put at end of this paragraph, mark is put
at beginning of this or a previous paragraph.

Interactively (or if ALLOW-EXTEND is non-nil), if this command is
repeated or (in Transient Mark mode) if the mark is active,
it marks the next ARG paragraphs after the ones already marked."
      (interactive (list (uarg->integer 1 (current-prefix-arg)) #t))
      (if (= arg 0)
          (error "Cannot mark zero paragraphs"))
      ;; Emacs's condition is
      ;;
      ;;   (and allow-extend
      ;;        (or (and (eq last-command this-command) (mark t))
      ;;            (and transient-mark-mode mark-active)))
      ;;
      ;; - the `(mark t)' conjunct is load-bearing: the extend branch
      ;; starts by going to the mark, so it may only be taken when there
      ;; *is* one. Without it a repeat with no mark went to `(goto-char
      ;; #f)' and died with "text editor index must be set with an
      ;; integer".
      (if (and allow-extend
               (or (and (eq? (*last-command*) mark-paragraph) (mark #t))
                   (and (transient-mark-mode) (mark-active))))
          ;; extend: the mark is where the last one ended.
          (set-mark
           (save-excursion
             (goto-char (mark #t))
             (forward-paragraph arg)
             (point)))
          (begin
            (forward-paragraph arg)
            (push-mark #f #t #t)
            (backward-paragraph arg)))
      #f)

    ;;----------------------------------------------------------------
    ;; Sentences
    ;;----------------------------------------------------------------

    (define (forward-sentence-default-function . args)
      ;; GNU Emacs's `forward-sentence-default-function'
      ;; (`paragraphs.el:463'): "Move forward to next end of sentence.
      ;; With argument, repeat. When ARG is negative, move backward
      ;; repeatedly to start of sentence.
      ;;
      ;; The variable `sentence-end' is a regular expression that matches
      ;; ends of sentences.  Also, every paragraph boundary terminates
      ;; sentences as well."
      ;;--------------------------------------------------------------
      (let ((arg (let ((a (and (pair? args) (car args)))) (if a a 1)))
            (opoint (point))
            (sentence-end (sentence-end)))
        (let loop-back ()
          (if (< arg 0)
              (begin
                (let ((pos (point)))
                  (let-values (((par-text-beg par-beg)
                                (save-excursion
                                  (start-of-paragraph-text)
                                  ;; "Start of real text in the paragraph.
                                  ;; We move back to here if we don't see a
                                  ;; sentence-end."
                                  (let ((text-beg (point)))
                                    ;; "Start of the first line of the
                                    ;; paragraph. We use this as the search
                                    ;; limit to allow sentence-end to match
                                    ;; if it is anchored at BOL and the
                                    ;; paragraph starts indented."
                                    (beginning-of-line 1)
                                    (values text-beg (point))))))
                    (if (and (re-search-backward sentence-end par-beg #t)
                             (or (< (match-end 0) pos)
                                 (re-search-backward sentence-end par-beg #t)))
                        (goto-char (match-end 0))
                        (goto-char par-text-beg))))
                (set! arg (+ arg 1))
                (loop-back))))
        (let loop-forward ()
          (if (> arg 0)
              (begin
                (let ((par-end (save-excursion
                                 (end-of-paragraph-text)
                                 (point))))
                  (if (re-search-forward sentence-end par-end #t)
                      (skip-chars-backward " \t\n")
                      (goto-char par-end)))
                (set! arg (- arg 1))
                (loop-forward))))
        (constrain-to-field #f opoint #t)))

    (define forward-sentence-function forward-sentence-default-function)
    ;; ^ GNU Emacs's `forward-sentence-function' (`paragraphs.el:500').
    ;; A plain variable rather than a parameter: nothing `let`-binds it,
    ;; it is only read and `setq`-ed. The self-assignment is the cure for
    ;; the compiler folding a top-level definition that this module never
    ;; assigns - see the `menu-bar-tests` note in AGENTS.md.
    (set! forward-sentence-function forward-sentence-function)

    (define (forward-sentence . args)
      ;; GNU Emacs's `forward-sentence' (`paragraphs.el:504'): "Move
      ;; forward to next end of sentence. With argument ARG, repeat. If
      ;; ARG is negative, move backward repeatedly to start of sentence.
      ;; Delegates its work to `forward-sentence-function'."
      ;;--------------------------------------------------------------
      (let ((arg (let ((a (and (pair? args) (car args)))) (if a a 1))))
        (forward-sentence-function arg)))

    (define (backward-sentence . args)
      ;; GNU Emacs's `backward-sentence' (`paragraphs.el:568'): "Move
      ;; backward to start of sentence. With ARG, do it ARG times."
      ;;--------------------------------------------------------------
      (let ((arg (let ((a (and (pair? args) (car args)))) (if a a 1))))
        (forward-sentence (- arg))))

    (define-command (kill-sentence arg)
      ;; GNU Emacs's `kill-sentence' (`paragraphs.el:576'): "Kill from
      ;; point to end of sentence. With ARG, repeat; negative ARG -N
      ;; means kill back to Nth start of sentence."
      "Kill from point to end of sentence.
With ARG, repeat; negative ARG -N means kill back to Nth start of
sentence."
      (interactive (list (uarg->integer 1 (current-prefix-arg))))
      (kill-region (point) (begin (forward-sentence arg) (point))))

    (define-command (backward-kill-sentence arg)
      ;; GNU Emacs's `backward-kill-sentence' (`paragraphs.el:583'):
      ;; "Kill back from point to start of sentence. With ARG, repeat, or
      ;; kill forward to Nth end of sentence if negative ARG -N."
      "Kill back from point to start of sentence.
With ARG, repeat, or kill forward to Nth end of sentence if
negative ARG -N."
      (interactive (list (uarg->integer 1 (current-prefix-arg))))
      (kill-region (point) (begin (backward-sentence arg) (point))))

    ;; The keys `bindings.el' binds them to. **M-k is `kill-sentence',
    ;; not `kill-paragraph'** - measured, `(key-binding "\\M-k")' is
    ;; `kill-sentence', and `kill-paragraph' is bound to nothing at all
    ;; in Emacs 31. This file bound M-k to `kill-paragraph' until
    ;; 2026-11-17, and M-C-k to `backward-kill-paragraph', which is
    ;; `kill-sexp`'s key (`lisp.scm' binds it).
    (define-key *default-keymap* (kbd "M-k") kill-sentence)
    (define-key *default-keymap* (kbd "C-x DEL") backward-kill-sentence)
    (define-key *default-keymap* (kbd "M-e") forward-sentence)
    (define-key *default-keymap* (kbd "M-a") backward-sentence)
    (define-key *default-keymap* (kbd "M-h") mark-paragraph)
    (define-key *default-keymap* (kbd "M-}") forward-paragraph)
    (define-key *default-keymap* (kbd "M-{") backward-paragraph)

    ))
