(define-library (schemacs editor fill)
  ;; This library mirrors GNU Emacs's `lisp/textmodes/fill.el': the
  ;; paragraph-filling engine - `fill-paragraph' (M-q), `fill-region',
  ;; `fill-region-as-paragraph', the adaptive fill prefix, the no-break
  ;; predicates, and the justification half.
  ;;
  ;; **The walks are the real ones.** They stand on `paragraphs.scm`'s
  ;; `forward-paragraph`/`sentence-end`, `indent.scm`'s margins and
  ;; `search.scm`'s regexps, all ported before this file; there is no
  ;; approximation of `paragraph-start` or `sentence-end` left anywhere
  ;; below it.
  ;;
  ;; **Departures, each named where it happens and collected here:**
  ;;
  ;;   * `fill-column` is a *buffer-local* in Emacs (a
  ;;     DEFVAR_PER_BUFFER) and this tree keeps it that way
  ;;     (`buffer-fill-column`), with one dynamic override parameter for
  ;;     the two places `fill.el` `let`-binds it - `unfill-paragraph` and
  ;;     `fill-region-as-paragraph-semlf`. A Scheme `let` cannot reach a
  ;;     per-buffer table several frames down, so the override is a
  ;;     parameter and the ordinary read is the buffer's own value.
  ;;   * `default-justification` is `:local t` in Emacs and a plain
  ;;     parameter here: nothing can set it per buffer yet.
  ;;   * `\c|` is Emacs's "break here" **character category**, and
  ;;     `char-category-set` is not ported - there is no category table
  ;;     (`charset.c`). The three places `fill.el` searches for it are
  ;;     therefore the plain `[ \t]` searches, and a CJK line is broken
  ;;     where a space is and nowhere else. `fill-find-break-point`'s
  ;;     table is empty for the same reason (`char-script-table`).
  ;;   * `invisible-p` (`xdisp.c`) is not ported, so
  ;;     `fill-nobreak-invisible` cannot see an `invisible` property and
  ;;     answers "visible" for everything. The variable is read; the
  ;;     question it asks has no reader here.
  ;;   * `with-buffer-unmodified-if-unchanged` is `subr-x.el`'s and is
  ;;     defined here: `fill-paragraph` is its only caller in the tree
  ;;     and the state it needs - `buffer-hash` (`fns.scm`) and the
  ;;     modified flags (`buffer.scm`) - is what this library imports.
  ;;
  ;; Not carried, each with what it waits for:
  ;;
  ;;   * `fill-region-as-paragraph-semlf` and `fill-paragraph-semlf` are
  ;;     carried; what they stand on, `forward-sentence`, is
  ;;     `paragraphs.scm`'s.
  ;;   * `use-hard-newlines`' *mode command* - the variable and every
  ;;     branch that reads it are here, but the mode needs `:extra-args`
  ;;     and `set-hard-newline-properties`, so no buffer can ever hold a
  ;;     `hard` newline and those branches are dead until it can.
  ;;
  ;; See LAYOUT-PLAN.txt for the rule this library is a step of.

  (import
    (scheme base)
    (scheme char)
    (only (guile) caddr string-index)
    (only (schemacs editor character) *tab-width*)
    (only (schemacs editor indentc) *indent-tabs-mode*)
    ;; the two character tables are `make-char-table`s - `chartab.scm`
    (only (schemacs editor chartab) make-char-table char-table-range
          set-char-table-range)
    (only (schemacs editor buffer)
          current-buffer bufferp get-buffer set-buffer
          buffer-fill-column set!buffer-fill-column
          buffer-read-only?
          buffer-modified-p restore-buffer-modified-p buffer-live-p
          *case-fold-search* *inhibit-read-only*
          mark-active transient-mark-mode
          fetch-char set-point buffer-beg buffer-z buffer-pt)
    (only (schemacs editor editfns)
          bobp bolp eobp eolp point point-marker point-min point-max goto-char
          save-excursion
          forward-line line-beginning-position line-end-position
          following-char preceding-char char-after char-before
          current-message
          delete-region delete-and-extract-region
          buffer-substring buffer-string
          insert insert-char insert-and-inherit
          insert-before-markers-and-inherit
          subst-char-in-region char-equal
          propertize
          region-beginning region-end
          save-restriction save-excursion narrow-to-region widen
          constrain-to-field
          message)
    (only (schemacs editor cmds)
          beginning-of-line end-of-line forward-char backward-char delete-char)
    (only (schemacs editor indent)
          indent-line-to indent-according-to-mode indent-region
          current-left-margin move-to-left-margin indent-to-left-margin
          *fill-prefix*)
    (only (schemacs editor indentc)
          current-column current-indentation indent-to move-to-column)
    (only (schemacs editor search)
          looking-at looking-back string-match match-beginning match-end
          match-string
          re-search-forward re-search-backward search-forward search-backward
          replace-match regexp-quote)
    (only (schemacs editor syntax)
          char-syntax skip-chars-forward skip-chars-backward
          skip-syntax-backward)
    (only (schemacs editor textprop)
          get-text-property put-text-property set-text-properties
          remove-text-properties remove-list-of-text-properties
          text-property-any text-property-not-all text-properties-at)
    (only (schemacs editor fns) compare-strings buffer-hash)
    (only (schemacs editor subr)
          kbd string-to-list replace-regexp-in-string
          run-hook-with-args-until-success)
    (only (schemacs editor character) string-width)
    (only (schemacs editor marker)
          copy-marker markerp marker-position set-marker)
    (only (schemacs editor paragraphs)
          *paragraph-start* *paragraph-separate* *paragraph-ignore-fill-prefix*
          *use-hard-newlines*
          *sentence-end* sentence-end *sentence-end-double-space*
          *sentence-end-without-period* *sentence-end-without-space*
          forward-paragraph backward-paragraph forward-sentence)
    (only (schemacs editor simple) delete-horizontal-space)
    (only (schemacs editor newcomment)
          comment-start comment-end comment-start-skip
          comment-search-forward comment-string-strip comment-normalize-vars)
    (only (schemacs editor minibuffer) minibufferp minibuffer-prompt-end)
    (only (schemacs editor custom) define-custom)
    (only (schemacs editor command) current-prefix-arg define-command)
    (only (schemacs editor keymap) define-key *default-keymap*)
    )

  (export
   ;; the variables
   *fill-column-override* fill-column
   *adaptive-fill-mode* *adaptive-fill-regexp* *adaptive-fill-first-line-regexp*
   *adaptive-fill-function* *fill-paragraph-function*
   *fill-paragraph-handle-comment* *fill-nobreak-predicate*
   *fill-nobreak-invisible* *colon-double-space*
   *fill-separate-heterogeneous-words-with-space*
   *fill-individual-varying-indent* *enable-kinsoku*
   *default-justification*
   *fill-region-as-paragraph-function*
   fill-forward-paragraph-function
   *fill-find-break-point-function-table*
   *fill-nospace-between-words-table*
   ;; the functions
   current-fill-column canonically-space-region
   fill-common-string-prefix fill-match-adaptive-prefix fill-context-prefix
   fill-single-word-nobreak-p fill-french-nobreak-p fill-polish-nobreak-p
   fill-single-char-nobreak-p fill-nobreak-p
   fill-find-break-point
   fill-delete-prefix fill-delete-newlines fill-move-to-break-point
   fill-text-properties-at fill-newline fill-indent-to-left-margin
   fill-region-as-paragraph-default fill-region-as-paragraph
   skip-line-prefix fill-minibuffer-function fill-forward-paragraph
   fill-paragraph unfill-paragraph fill-comment-paragraph fill-region
   current-justification set-justification
   set-justification-none set-justification-left set-justification-right
   set-justification-full set-justification-center
   justify-current-line unjustify-current-line unjustify-region
   fill-nonuniform-paragraphs fill-individual-paragraphs
   fill-individual-paragraphs-prefix fill-individual-paragraphs-citation
   fill-region-as-paragraph-semlf fill-paragraph-semlf
   beginning-of-line-text
   with-buffer-unmodified-if-unchanged
   )

  (begin

    (define (%pos p)
      ;; A position or a marker as a position. Emacs's arithmetic and its
      ;; searches accept either ("MARKERP (x)" is coerced by
      ;; `CHECK_FIXNUM_COERCE_MARKER'), and Scheme's do not, so every
      ;; comparison in this file that can see a marker goes through here.
      ;; `fix-position` (`editfns.scm') is the same rule for a single
      ;; argument; this one is the read-side spelling.
      ;;--------------------------------------------------------------
      (if (markerp p) (marker-position p) p))

    ;;----------------------------------------------------------------
    ;; The variables (`fill.el:39-141')
    ;;----------------------------------------------------------------

    (define-custom *colon-double-space* #f
      "Non-nil means put two spaces after a colon when filling."
      :type 'boolean
      :safe 'booleanp
      :group 'fill)

    (define-custom *fill-separate-heterogeneous-words-with-space* #f
      "Non-nil means to use a space to separate words of different kind.
The words are considered different when they have different scripts
or belong to different categories."
      :type 'boolean
      :safe 'booleanp
      :group 'fill)

    (define *fill-paragraph-function* (make-parameter #f))
    ;; ^ GNU Emacs's `fill-paragraph-function' (`fill.el:63'). A parameter
    ;; because `fill-paragraph' `let`-binds it around its own call.

    (define *fill-paragraph-handle-comment* (make-parameter #t))
    ;; ^ GNU Emacs's `fill-paragraph-handle-comment' (`fill.el:71'),
    ;; `let`-bound by `fill-paragraph' as it tries each strategy.

    (define-custom *enable-kinsoku* #t
      "Non-nil means to apply Kinsoku rules when filling.
Kinsoku rules are characters that cannot appear at the beginning or end
of a line, in Japanese typography."
      :type 'boolean
      :group 'fill)

    (define (fill-column)
      ;; The fill column of the current buffer: GNU Emacs's
      ;; `fill-column', a buffer-local DEFVAR_PER_BUFFER whose default is
      ;; 70 (`buffer.c:4898').
      ;;
      ;; **The dynamic override is this tree's spelling of Elisp's
      ;; `(let ((fill-column N)) ...)`.** Two places in `fill.el` rebind
      ;; it - `unfill-paragraph` (`:966') and
      ;; `fill-region-as-paragraph-semlf` (`:1743') - and the binding has
      ;; to reach `current-fill-column' several frames down, which a
      ;; Scheme `let` over a per-buffer table cannot do. `#f` means "no
      ;; override": the buffer's own value.
      ;;--------------------------------------------------------------
      (or (*fill-column-override*) (buffer-fill-column (current-buffer))))

    (define *fill-column-override* (make-parameter #f))
    ;; ^ see `fill-column` above.

    (define-custom *adaptive-fill-mode* #t
      "Non-nil means determine a paragraph's fill prefix from its text."
      :type 'boolean
      :safe 'booleanp
      :group 'fill)

    (define-custom *adaptive-fill-regexp* "[ \t]*\\([-–!|#%;>*·•‣⁃◦]+\\)?[ \t]*"
      "Regexp to match text at start of line that constitutes indentation.
If Adaptive Fill mode is enabled, a prefix matching this pattern
on the first and second lines of a paragraph is used as the
standard indentation for the whole paragraph.

If the paragraph has just one line, the indentation is taken from that
line, but in that case `adaptive-fill-first-line-regexp' also plays
a role."
      :type 'regexp
      :safe 'stringp
      :group 'fill)

    (define-custom *adaptive-fill-first-line-regexp* "\\`[ \t]*\\'"
      "Regexp specifying whether to set fill prefix from a one-line paragraph.
When `adaptive-fill-regexp' matches at the beginning of a paragraph
with only one line, then if the text matches this regexp, it is used
as the fill prefix.  Otherwise, the whitespace is replaced by spaces."
      :type 'regexp
      :safe 'stringp
      :group 'fill)

    (define-custom *adaptive-fill-function* (lambda () #f)
      "Function to call to choose a fill prefix for a paragraph.
The function is called with no argument, with point at the beginning of
the line to be filled, and should return either a string to use as the
fill prefix, or nil to use the value of `adaptive-fill-regexp'."
      :type 'function
      :group 'fill)

    (define-custom *fill-nobreak-predicate* '()
      "List of predicates for recognizing places not to break a line.
The predicates are called with no arguments, with point at the place to
be tested.  If it returns a non-nil value, fill commands do not break
the line there."
      :type 'hook
      :group 'fill)

    (define-custom *fill-nobreak-invisible* #f
      "Non-nil means that fill commands do not break lines in invisible text."
      :type 'boolean
      :group 'fill)

    (define fill-forward-paragraph-function forward-paragraph)
    ;; ^ GNU Emacs's `fill-forward-paragraph-function' (`fill.el:855').
    ;; A plain variable: nothing `let`-binds it, it is only read and
    ;; `setq`-ed. The self-assignment is the compiler's mutable marking -
    ;; see the `menu-bar-tests` note in AGENTS.md.
    (set! fill-forward-paragraph-function fill-forward-paragraph-function)

    (define *fill-find-break-point-function-table*
      (make-char-table 'nil))
    ;; ^ GNU Emacs's `fill-find-break-point-function-table'
    ;; (`fill.el:417'), "Char-table of special functions to find line
    ;; breaking point." Emacs fills it from `char-script-table' (HAN,
    ;; KANA, BOPOMOFO, CJK-MISC -> `kinsoku') and for the full- and
    ;; half-width forms; `char-script-table` and `kinsoku` are not
    ;; ported, so the table is empty and `fill-find-break-point` does
    ;; nothing - which is what Emacs does for text that has no entry.

    (define *fill-nospace-between-words-table*
      (make-char-table 'nil))
    ;; ^ GNU Emacs's `fill-nospace-between-words-table' (`fill.el:420'),
    ;; filled from the same script table. Empty here for the same reason.

    (define-custom *fill-individual-varying-indent* #f
      "Non-nil means fill paragraphs with varying indentation.
If non-nil, fill-individual-paragraphs considers a change in indentation
to start a new paragraph."
      :type 'boolean
      :group 'fill)

    (define-custom *default-justification* 'left
      "Method of justifying text not otherwise specified.
Possible values are `left', `right', `full', `center', or `none'.
The requested kind of justification is done whenever lines are filled.
The `justification' text-property can locally override this variable."
      :type '(choice (const left) (const right) (const full)
                     (const center) (const none))
      :safe 'symbolp
      :group 'fill)

    ;;----------------------------------------------------------------
    ;; `set-fill-prefix'
    ;;----------------------------------------------------------------

    (define-command (set-fill-prefix arg)
      ;; GNU Emacs's `set-fill-prefix' (`fill.el:81'): "Set the fill
      ;; prefix to the text from beginning-of-line up to the current
      ;; column, for paragraph filling. With no argument (or a negative
      ;; argument), set the fill-prefix to nil, so that no prefix is
      ;; assumed. With argument of 0, set the fill-prefix to nil and
      ;; move to the left margin."
      "Set the fill prefix to the text from beginning-of-line up to the current column, for paragraph filling.
With no argument (or a negative argument), set the fill-prefix to nil,
so that no prefix is assumed.
With argument of 0, set the fill-prefix to nil and move to the left margin."
      (interactive (list (current-prefix-arg)))
      (let ((n (cond ((not arg) -1)
                     ((pair? arg) (current-column))
                     ((integer? arg) arg)
                     (else -1))))
        (cond ((= n 0)
               (*fill-prefix* #f)
               (move-to-left-margin))
              ((<= n 0)
               (*fill-prefix* #f))
              (else
               (let ((left-margin-pos (save-excursion
                                        (move-to-left-margin 1 #f)
                                        (point))))
                 (if (> (point) left-margin-pos)
                     (begin
                       (*fill-prefix*
                        (buffer-substring left-margin-pos (point)))
                       ;; "If we have set the prefix to the empty string,
                       ;; set it to nil instead."
                       (if (equal? (*fill-prefix*) "")
                           (*fill-prefix* #f))))))))
      #f)

    ;;----------------------------------------------------------------
    ;; `current-fill-column'
    ;;----------------------------------------------------------------

    (define (current-fill-column)
      ;; GNU Emacs's `current-fill-column' (`fill.el:143'): "Return the
      ;; fill-column to use for this line. The fill-column to use for a
      ;; buffer is stored in the variable `fill-column', but can be
      ;; locally modified by the `right-margin' text property, which is
      ;; subtracted from `fill-column'.
      ;;
      ;; The fill column to use for a line is the first column at which
      ;; the column number equals or exceeds the local fill-column -
      ;; right-margin difference."
      ;;
      ;; The C's `fill-column`-is-nil branch (28's obsolete spelling, with
      ;; its warning and `most-positive-fixnum') is not carried: the value
      ;; here is a number by construction.
      ;;--------------------------------------------------------------
      (save-excursion
        (let* ((fill-column (fill-column))
               (here (line-beginning-position))
               (here-col 0)
               (eol (begin (end-of-line 1) (point))))
          ;; "Look separately at each region of line with a different
          ;; right-margin."
          (let loop ((here here) (here-col here-col))
            (let* ((margin (get-text-property here 'right-margin))
                   (fill-col (- fill-column (or margin 0)))
                   (change (text-property-not-all here eol 'right-margin
                                                  margin)))
              (if (and change
                       (begin
                         (goto-char (- change 1))
                         (let ((col (current-column)))
                           (if (< col fill-col)
                               (begin (set! here-col col) #t)
                               #f))))
                  (loop change here-col)
                  (max here-col fill-col)))))))

    ;;----------------------------------------------------------------
    ;; `canonically-space-region'
    ;;----------------------------------------------------------------

    (define-command (canonically-space-region beg end)
      ;; GNU Emacs's `canonically-space-region' (`fill.el:177'): "Remove
      ;; extra spaces between words in region. Leave one space between
      ;; words, two at end of sentences or after colons (depending on
      ;; values of `sentence-end-double-space', `colon-double-space', and
      ;; `sentence-end-without-period'). Remove indentation from each
      ;; line."
      ;;
      ;; "Ideally, we'd want to scan the text from the end, so that
      ;; changes to text don't affect the boundary, but the regexp we
      ;; match against does not match as eagerly when matching backward,
      ;; so we instead use a marker." - so END is a marker here, and every
      ;; comparison with it goes through `marker-position`, Scheme having
      ;; no marker arithmetic.
      ;;--------------------------------------------------------------
      "Remove extra spaces between words in region.
Leave one space between words, two at end of sentences or after colons
\(depending on values of `sentence-end-double-space', `colon-double-space',
and `sentence-end-without-period').
Remove indentation from each line."
      (interactive "*r")
      (let ((end (if (markerp end) end (copy-marker end #t)))
            (end-spc-re (string-append "\\(" (sentence-end) "\\) *\\|  +")))
        (save-excursion
          (goto-char beg)
          ;; "Nuke tabs; they get screwed up in a fill. This is quick,
          ;; but loses when a tab follows the end of a sentence. Actually,
          ;; it is difficult to tell that from \"Mr.\\tSmith\". Blame the
          ;; typist."
          (subst-char-in-region beg end #\tab #\space)
          (let loop ()
            (when (and (< (point) (marker-position end))
                       (re-search-forward end-spc-re (marker-position end) #t))
              (let ((m0b (match-beginning 0))
                    (m0e (match-end 0))
                    (m1e (match-end 1)))
                (delete-region
                 (cond
                  ;; "`sentence-end' matched and did not match all spaces.
                  ;; I.e. it only matched the number of spaces it needs:
                  ;; drop the rest."
                  ((and m1e (> m0e m1e)) m1e)
                  ;; "`sentence-end' matched but with nothing left. Either
                  ;; that means nothing should be removed, or it means
                  ;; it's the \"old-style\" sentence-end which matches all
                  ;; it can. Keep only 2 spaces."
                  (m1e
                   (min m0e
                        (+ (if (*sentence-end-double-space*) 2 1)
                           (save-excursion
                             (goto-char m0e)
                             (skip-chars-backward " ")
                             (point)))))
                  ;; "It's not an end of sentence."
                  (else
                   (+ m0b
                      ;; "Determine number of spaces to leave:"
                      (save-excursion
                        (skip-chars-backward " ]})\"'")
                        (cond ((and (*sentence-end-double-space*)
                                    (or (memv (preceding-char)
                                              (list #\. #\? #\!))
                                        (and (*sentence-end-without-period*)
                                             (char=? (char-syntax
                                                      (preceding-char))
                                                     #\w))))
                               2)
                              ((and *colon-double-space*
                                    (char=? (preceding-char) #\:))
                               2)
                              ((char-equal (preceding-char) #\newline) 0)
                              (else 1))))))
                 m0e))
              (loop))))))

    (define (fill-common-string-prefix s1 s2)
      ;; GNU Emacs's `fill-common-string-prefix' (`fill.el:229'):
      ;; "Return the longest common prefix of strings S1 and S2, or nil
      ;; if none."
      ;;--------------------------------------------------------------
      (let ((cmp (compare-strings s1 #f #f s2 #f #f)))
        (if (eq? cmp #t)
            s1
            (let ((cmp (- (abs cmp) 1)))
              (if (zero? cmp)
                  #f
                  (substring s1 0 cmp))))))

    (define (fill-match-adaptive-prefix)
      ;; GNU Emacs's `fill-match-adaptive-prefix' (`fill.el:238').
      ;;--------------------------------------------------------------
      (let ((str (or (and (*adaptive-fill-function*)
                          ((*adaptive-fill-function*)))
                     (and (*adaptive-fill-regexp*)
                          (looking-at (*adaptive-fill-regexp*))
                          (match-string 0)))))
        (if (>= (+ (current-left-margin) (string-length (or str "")))
                (current-fill-column))
            ;; "Death to insanely long prefixes."
            #f
            str)))

    (define (fill-context-prefix from to . rest)
      ;; GNU Emacs's `fill-context-prefix' (`fill.el:248'): "Compute a
      ;; fill prefix from the text between FROM and TO. This uses the
      ;; variables `adaptive-fill-regexp' and `adaptive-fill-function'
      ;; and `adaptive-fill-first-line-regexp'. `paragraph-start' also
      ;; plays a role; we reject a prefix based on a one-line paragraph
      ;; if that prefix would act as a paragraph-separator."
      ;;--------------------------------------------------------------
      (let ((first-line-regexp (or (and (pair? rest) (car rest))
                                   (*adaptive-fill-first-line-regexp*))))
        (save-excursion
          (goto-char from)
          (if (eolp) (forward-line 1))
          ;; "Move to the second line unless there is just one."
          (move-to-left-margin 1 #f)
          (let ((first-line-prefix (fill-match-adaptive-prefix)))
            (forward-line 1)
            (if (< (point) to)
                ;; "Non-nil if we are on the second line."
                (let ((second-line-prefix
                       (begin
                         (move-to-left-margin 1 #f)
                         (cond ((looking-at (*paragraph-start*)) #f)
                               (else (fill-match-adaptive-prefix))))))
                  ;; "If we get a fill prefix from the second line, make
                  ;; sure it or something compatible is on the first line
                  ;; too."
                  (when second-line-prefix
                    ;; "If the non-whitespace chars match the first line,
                    ;; just use it (this subsumes the 2 checks used
                    ;; previously). Used when first line is `/* ...' and
                    ;; second-line is ` * ...'."
                    (let ((tmp second-line-prefix)
                          (re "\\`")
                          (first-line-prefix (or first-line-prefix "")))
                      (let loop ()
                        (when (string-match "\\`[ \t]*\\([^ \t]+\\)" tmp)
                          (set! re (string-append
                                    re ".*"
                                    (regexp-quote (match-string 1 tmp))))
                          (set! tmp (substring tmp (match-end 0)))
                          (loop)))
                      (if (string-match re first-line-prefix)
                          second-line-prefix
                          ;; "Use the longest common substring of both
                          ;; prefixes, if there is one."
                          (fill-common-string-prefix first-line-prefix
                                                     second-line-prefix)))))
                ;; "If we get a fill prefix from a one-line paragraph,
                ;; maybe change it to whitespace, and check that it isn't
                ;; a paragraph starter."
                (if first-line-prefix
                    (let ((result
                           ;; "If first-line-prefix comes from the first
                           ;; line, see if it seems reasonable to use for
                           ;; all lines. If not, replace it with
                           ;; whitespace."
                           (if (or (and first-line-regexp
                                        (string-match first-line-regexp
                                                      first-line-prefix))
                                   (and (comment-start-skip)
                                        (string-match (comment-start-skip)
                                                      first-line-prefix)))
                               first-line-prefix
                               (make-string (string-width first-line-prefix)
                                            #\space))))
                      ;; "But either way, reject it if it indicates the
                      ;; start of a paragraph when text follows it."
                      (if (not (eq? 0 (string-match
                                       (*paragraph-start*)
                                       (string-append result "a"))))
                          result
                          #f))
                    #f))))))

    ;;----------------------------------------------------------------
    ;; The no-break predicates (`fill.el:322-415')
    ;;----------------------------------------------------------------

    (define (fill-single-word-nobreak-p)
      ;; GNU Emacs's `fill-single-word-nobreak-p' (`fill.el:322'): "Don't
      ;; break a line after the first or before the last word of a
      ;; sentence."
      ;;--------------------------------------------------------------
      (or (looking-at (string-append "[ \t]*\\sw+"
                                     "\\(?:" (sentence-end) "\\)[ \t]*$"))
          (save-excursion
            (skip-chars-backward " \t")
            (and (not (= (skip-syntax-backward "w") 0))
                 (not (= (skip-chars-backward " \t") 0))
                 (not (= (skip-chars-backward ".?!:") 0))
                 (looking-at (sentence-end))))))

    (define (fill-french-nobreak-p)
      ;; GNU Emacs's `fill-french-nobreak-p' (`fill.el:334'): "Return nil
      ;; if French style allows breaking the line at point."
      ;;--------------------------------------------------------------
      (or (looking-at "[ \t]*[])}»?!;:-]")
          (save-excursion
            (skip-chars-backward " \t")
            (if (bolp)
                #f
                (begin
                  (backward-char 1)
                  (or (looking-at "[([{«]")
                      ;; "Don't cut right after a single-letter word."
                      (and (memv (preceding-char) (list #\tab #\space))
                           (char=? (char-syntax (following-char)) #\w))))))))

    (define (fill-polish-nobreak-p)
      ;; GNU Emacs's `fill-polish-nobreak-p' (`fill.el:351'): "Return nil
      ;; if Polish style allows breaking the line at point."
      ;;--------------------------------------------------------------
      (save-excursion
        (skip-chars-backward " \t")
        (backward-char 2)
        (looking-at "[^[:alpha:]]\\cl")))

    (define (fill-single-char-nobreak-p)
      ;; GNU Emacs's `fill-single-char-nobreak-p' (`fill.el:363'):
      ;; "Return non-nil if a one-letter word is before point."
      ;;--------------------------------------------------------------
      (save-excursion
        (skip-chars-backward " \t")
        (backward-char 2)
        (looking-at "[[:space:]][[:alpha:]]")))

    (define (fill-nobreak-p)
      ;; GNU Emacs's `fill-nobreak-p' (`fill.el:386'): "Return nil if
      ;; breaking the line at point is allowed."
      ;;
      ;; **The hook's answer must be converted**: `run-hook-with-args-
      ;; until-success` answers `'()` when the list is empty, and an empty
      ;; list is *true* in Scheme where Elisp's nil is false. Written as
      ;; Emacs's `or` chain this returned `'()` for every ordinary space,
      ;; which made `fill-move-to-break-point` walk back to the first
      ;; space in the paragraph. `fill-nobreak-invisible`'s
      ;; `(invisible-p (point))` is not carried - see the header.
      ;;--------------------------------------------------------------
      (if (bolp)
          #f
          (let ((hook (run-hook-with-args-until-success
                       *fill-nobreak-predicate*)))
            (cond
             ;; "Don't break after a period followed by just one space.
             ;; Move back to the previous place to break."
             ((and (*sentence-end-double-space*)
                   (save-excursion
                     (skip-chars-backward " ")
                     (and (char=? (preceding-char) #\.)
                          ;; "There's something more after the space."
                          (looking-at " [^ \n]"))))
              #t)
             ;; "Don't split a line if the rest would look like a new
             ;; paragraph."
             ((and (not (*use-hard-newlines*))
                   (save-excursion
                     (skip-chars-forward " \t")
                     ;; "If this break point is at the end of the line,
                     ;; which can occur for auto-fill, don't consider the
                     ;; newline which follows as a reason to return t."
                     (and (not (eolp))
                          (looking-at (*paragraph-start*)))))
              #t)
             ((null? hook) #f)
             (else hook)))))

    (define (fill-find-break-point limit)
      ;; GNU Emacs's `fill-find-break-point' (`fill.el:441'): "Move point
      ;; to a proper line breaking position of the current line. Don't
      ;; move back past the buffer position LIMIT."
      ;;
      ;; The C takes the entry for the character after point, or failing
      ;; that the one before it, and calls it. `charset-after` is not
      ;; ported (there is no charset registry lookup in `charset.scm`,
      ;; only the metadata), and the table is empty, so the answer is the
      ;; C's own for a character with no entry: nothing.
      ;;--------------------------------------------------------------
      #f)

    ;;----------------------------------------------------------------
    ;; Deleting the prefix and the newlines
    ;;----------------------------------------------------------------

    (define (fill-delete-prefix from to prefix)
      ;; GNU Emacs's `fill-delete-prefix' (`fill.el:456'): "Delete the
      ;; fill prefix from every line except the first. The first line may
      ;; not even have a fill prefix. Point is moved to just past the
      ;; fill prefix on the first line."
      ;;--------------------------------------------------------------
      (let* ((fpre (if (and prefix (not (string-match "\\`[ \t]*\\'" prefix)))
                       (string-append "[ \t]*\\("
                                      (replace-regexp-in-string
                                       "[ \t]+" "[ \t]*"
                                       (regexp-quote prefix))
                                      "\\)?[ \t]*")
                       "[ \t]*")))
        (goto-char from)
        (forward-line 1)
        (let loop ()
          (when (< (point) (%pos to))
            (if (looking-at fpre)
                (delete-region (point) (match-end 0)))
            (forward-line 1)
            (loop)))
        (goto-char from)
        (if (looking-at fpre)
            (goto-char (match-end 0)))
        (point)))

    (define (fill-delete-newlines from to justify nosqueeze squeeze-after)
      ;; GNU Emacs's `fill-delete-newlines' (`fill.el:488'): the newlines
      ;; inside the paragraph become single spaces, after the end of a
      ;; sentence gets its extra space.
      ;;--------------------------------------------------------------
      (goto-char from)
      ;; "Make sure sentences ending at end of line get an extra space.
      ;; loses on split abbrevs (\"Mr.\\nSmith\")"
      (let* ((eol-double-space-re
              (cond ((not *colon-double-space*)
                     (string-append (sentence-end) "$"))
                    ;; "Try to add the : inside the `sentence-end' regexp."
                    ((string-match "\\[[^][]*\\(\\.\\)[^][]*\\]" (sentence-end))
                     (string-append
                      (replace-match ".:" #f #f (sentence-end) 1) "$"))
                    ;; "Can't find the right spot to insert the colon."
                    (else "[.?!:][])}\"']*$")))
             (sentence-end-without-space-list
              (string-to-list (*sentence-end-without-space*))))
        (let loop ()
          (when (re-search-forward eol-double-space-re (%pos to) #t)
            (or (>= (point) (%pos to))
                (memv (char-before) (list #\tab #\space))
                (memv (char-after (match-beginning 0))
                      sentence-end-without-space-list)
                (insert-and-inherit #\space))
            (loop))))

      (goto-char from)
      ;; "Delete unnecessary newlines surrounded by words" - the
      ;; `char-category-set' half of the C, which needs a category table
      ;; there is not one of here. Emacs deletes nothing between Latin
      ;; words, so for text this editor can see the result is the same.
      (goto-char from)
      (skip-chars-forward " \t")
      ;; "Then change all newlines to spaces."
      (subst-char-in-region from (%pos to) #\newline #\space)
      (if (and nosqueeze (not (eq? justify 'full)))
          #f
          (begin
            (canonically-space-region (or squeeze-after (point)) (%pos to))
            ;; "Remove trailing whitespace. Maybe
            ;; canonically-space-region should do that."
            (goto-char (%pos to))
            (delete-char (- (skip-chars-backward " \t")))))
      (goto-char from))

    (define (fill-move-to-break-point linebeg)
      ;; GNU Emacs's `fill-move-to-break-point' (`fill.el:544'): "Move to
      ;; the position where the line should be broken. The break position
      ;; will be always after LINEBEG and generally before point."
      ;;
      ;; **`\c|` is a character category and is not carried** - see the
      ;; header - so the C's `"[ \t]\\|\\c|.\\|.\\c|"` is `"[ \t]"` and
      ;; `"\\c|"` below is never found. For text with no category-`|`
      ;; character the two agree.
      ;;--------------------------------------------------------------
      ;; "If the fill column is before linebeg, move to linebeg."
      (if (> linebeg (point)) (goto-char linebeg))
      ;; The C's `while` body is the `when`, so the loop repeats **only
      ;; when `fill-nobreak-p` says the place is no good** - written as
      ;; an unconditional `loop` it re-finds the same space for ever.
      ;; **`rejected` is this tree's spelling of the C's final
      ;; `(>= linebeg (point))`.** In the C, a candidate the predicates
      ;; refuse sends point back to the bound and the search then fails,
      ;; which leaves point at LINEBEG; here `skip-chars-backward` stops
      ;; at the first non-space, so point can end a little past it - and
      ;; the fallback ("keep at least one word, walking to the line end")
      ;; would not be taken. Measured against Emacs 31.1 on "One. Two. ..."
      ;; at fill-column 70: Emacs walks to the line end and breaks
      ;; nothing, and taking the flag reproduces that exactly.
      (let ((rejected #f))
        (let loop ()
          (when (re-search-backward "[ \t]" linebeg #t)
            ;; "In case of space, we place the point at next to the point
            ;; where the break occurs actually, because we don't want to
            ;; change the following logic of original Emacs."
            (forward-char 1)
            (if (fill-nobreak-p)
                (begin
                  (set! rejected #t)
                  (skip-chars-backward " \t" linebeg)
                  (loop))
                (set! rejected #f))))
        ;; "Move back over the single space between the words."
        (skip-chars-backward " \t")

      ;; "If the left margin and fill prefix by themselves pass the
      ;; fill-column. or if they are zero but we have no room for even
      ;; one word, keep at least one word or a character which has
      ;; category `|' anyway."
        (if (or rejected (>= linebeg (point)))
          ;; "Ok, skip at least one word or one \c| character. Meanwhile,
          ;; don't stop at a period followed by one space."
          (let ((to (line-end-position))
                (first #t))
            (goto-char linebeg)
            (let loop ((first first))
              (when (and (< (point) to) (or first (fill-nobreak-p)))
                ;; "Find a breakable point while ignoring the following
                ;; spaces." The C has a `\c|` branch on each side of
                ;; this - "at a character with category `|'" - and this
                ;; tree has no category table, so both are omitted rather
                ;; than asked and answered false (the regexp engine
                ;; rejects `\c` outright). See the header.
                (skip-chars-forward " \t")
                (let ((pos (save-excursion
                             (skip-chars-forward "^ \n\t")
                             (point))))
                  (goto-char pos))
                (loop #f))))
          ;; "If we are going to break the line after or before a
          ;; non-ascii character, we may have to run a special function
          ;; for the charset of the character" - `charset-after` is not
          ;; ported, and the table is empty, so the call would do nothing;
          ;; the condition is kept as "some character could have an
          ;; entry", which for an empty table is never.
          #f)))

    ;; "Like text-properties-at but don't include `composition' property."
    (define (fill-text-properties-at pos)
      ;; GNU Emacs's `fill-text-properties-at' (`fill.el:604').
      ;;--------------------------------------------------------------
      (let ((l (text-properties-at pos))
            (prop-list '()))
        (let loop ((l l))
          (when (pair? l)
            (if (not (eq? (car l) 'composition))
                (set! prop-list
                      (cons (car l) (cons (cadr l) prop-list))))
            (loop (cddr l))))
        prop-list))

    (define *fill-indent-according-to-mode* #f)
    ;; ^ GNU Emacs's `fill-indent-according-to-mode' (`fill.el:138'), a
    ;; plain defvar that only `setq`-ed.
    (set! *fill-indent-according-to-mode* *fill-indent-according-to-mode*)

    (define (fill-newline)
      ;; GNU Emacs's `fill-newline' (`fill.el:614'): "Replace whitespace
      ;; here with one newline, then indent to left margin."
      ;;--------------------------------------------------------------
      (skip-chars-backward " \t")
      (insert #\newline)
      ;; "Give newline the properties of the space(s) it replaces"
      (set-text-properties (- (point) 1) (point)
                           (fill-text-properties-at (point)))
      ;; The C's second conjunct is `(match-end 2)' on the `\c|' half of
      ;; its regexp and `(aref (char-category-set ...) ?|)' - neither is
      ;; available, and both ask "is this a no-space script". See the
      ;; header.
      (if (and (looking-at "\\( [ \t]*\\)")
               (aref-category-break-p (or (char-before (- (point) 1))
                                          #\nul)))
          ;; "When refilling later on, this newline would normally not be
          ;; replaced by a space, so we need to mark it specially to
          ;; re-install the space when we unfill."
          (put-text-property (- (point) 1) (point) 'fill-space
                             (match-string 1)))
      ;; "If we don't want breaks in invisible text, don't insert an
      ;; invisible newline." - `invisible-p` is not ported; the
      ;; `remove-text-properties` below is the C's line and is harmless
      ;; without it.
      (if *fill-nobreak-invisible*
          (remove-text-properties (- (point) 1) (point) '(invisible #t)))
      (if (or (*fill-prefix*)
              (not *fill-indent-according-to-mode*))
          (fill-indent-to-left-margin)
          (indent-according-to-mode))
      ;; "Insert the fill prefix after indentation."
      (and (*fill-prefix*) (not (equal? (*fill-prefix*) ""))
           ;; "Markers that were after the whitespace are now at point:
           ;; insert before them so they don't get stuck before the
           ;; prefix."
           (insert-before-markers-and-inherit (*fill-prefix*))))

    (define (aref-category-break-p character)
      ;; The C's `(aref (char-category-set C) ?|)' - the "this character
      ;; carries no space before or after it" question, which a category
      ;; table answers and this tree has none of. False for every
      ;; character, which is the answer for Latin text.
      ;;--------------------------------------------------------------
      #f)

    (define (fill-indent-to-left-margin)
      ;; GNU Emacs's `fill-indent-to-left-margin' (`fill.el:644'):
      ;; "Indent current line to the column given by
      ;; `current-left-margin'."
      ;;--------------------------------------------------------------
      (let ((beg (point)))
        (indent-line-to (current-left-margin))
        (put-text-property beg (point) 'face 'default)))


    ;;----------------------------------------------------------------
    ;; `fill-region-as-paragraph'
    ;;----------------------------------------------------------------

    (define-command (fill-region-as-paragraph-default from to
                                                      . rest)
      ;; GNU Emacs's `fill-region-as-paragraph-default' (`fill.el:650'):
      ;; "Fill the region as if it were a single paragraph. This command
      ;; removes any paragraph breaks in the region and extra newlines at
      ;; the end, and indents and fills lines between the margins given
      ;; by the `current-left-margin' and `current-fill-column'
      ;; functions. ... It leaves point at the beginning of the line
      ;; following the region.
      ;;
      ;; Return the `fill-prefix' used for filling."
      ;;
      ;; **`(let ((fill-prefix fill-prefix)) ...)` is
      ;; `parameterize`** - the one place `fill.el` rebinds it around a
      ;; paragraph, and a Scheme `let` over a parameter's name would bind
      ;; nothing.
      ;;--------------------------------------------------------------
      "Fill the region as if it were a single paragraph.
This command removes any paragraph breaks in the region and extra newlines at
the end, and indents and fills lines between the margins given by the
`current-left-margin' and `current-fill-column' functions.  (In most cases,
the variable `fill-column' controls the width.)
It leaves point at the beginning of the line following the region.

Return the `fill-prefix' used for filling.

If `sentence-end-double-space' is non-nil, then period followed by one
space does not end a sentence, so don't break a line there."
      (interactive (list (region-beginning) (region-end)
                         (if (current-prefix-arg) 'full #f)))
      (let ((justify (and (pair? rest) (car rest)))
            (nosqueeze (and (pair? rest) (pair? (cdr rest)) (cadr rest)))
            (squeeze-after (and (pair? rest) (pair? (cdr rest))
                                (pair? (cddr rest)) (caddr rest))))
        (if (not (memv justify (list #t #f 'none 'full 'center 'left 'right)))
            (set! justify 'full))
        ;; "Make sure "to" is the endpoint."
        (goto-char (min from to))
        (let ((to (max from to)))
          ;; "Ignore blank lines at beginning of region."
          (skip-chars-forward " \t\n")
          (let ((from-plus-indent (point))
                (oneleft #f))
            (beginning-of-line 1)
            ;; "We used to round up to whole line, but that prevents us
            ;; from correctly handling filling of mixed code-and-comment
            ;; where we do want to fill the comment but not the code. So
            ;; only use (point) if it's further than `from', which means
            ;; that `from' is followed by some number of empty lines."
            (set! from (max (point) from))
            ;; "Delete all but one soft newline at end of region. And
            ;; leave TO before that one."
            (goto-char to)
            (let loop ()
              (when (and (> (point) from)
                         (char=? #\newline (char-after (- (point) 1))))
                (if (and oneleft
                         (not (and (*use-hard-newlines*)
                                   (get-text-property (- (point) 1) 'hard))))
                    (delete-char -1)
                    (begin
                      (backward-char 1)
                      (set! oneleft #t)))
                (loop)))
            (let ((to (copy-marker (point) #t)))
              (goto-char from-plus-indent)
              (if (not (> (marker-position to) (point)))
                  ;; "There is no paragraph, only whitespace: exit now."
                  (begin (set-marker to #f) #f)
                  (begin
                    (or justify (set! justify (current-justification)))
                    ;; "Don't let Adaptive Fill mode alter the fill prefix
                    ;; permanently."
                    (parameterize ((*fill-prefix* (*fill-prefix*)))
                      ;; "Figure out how this paragraph is indented, if
                      ;; desired."
                      (when (and (*adaptive-fill-mode*)
                                 (or (not (*fill-prefix*))
                                     (string=? (*fill-prefix*) "")))
                        (*fill-prefix* (fill-context-prefix from (marker-position to)))
                        ;; "Ignore a white-space only fill-prefix if we
                        ;; indent-according-to-mode."
                        (when (and (*fill-prefix*)
                                   *fill-indent-according-to-mode*
                                   (string-match "\\`[ \t]*\\'"
                                                 (*fill-prefix*)))
                          (*fill-prefix* #f)))
                      (goto-char from)
                      (beginning-of-line 1)
                      (if (not justify)
                          ;; "Filling disabled: just check indentation."
                          (begin
                            (goto-char from)
                            (let loop ()
                              (when (< (point) to)
                                (if (and (not (eolp))
                                         (< (current-indentation)
                                            (current-left-margin)))
                                    (fill-indent-to-left-margin))
                                (forward-line 1)
                                (loop))))
                          (begin
                            (if (*use-hard-newlines*)
                                (remove-list-of-text-properties from to '(hard)))
                            ;; "Make sure first line is indented (at
                            ;; least) to left margin..."
                            (if (or (memv justify '(right center))
                                    (< (current-indentation)
                                       (current-left-margin)))
                                (fill-indent-to-left-margin))
                            ;; "Delete the fill-prefix from every line."
                            (fill-delete-prefix from to (*fill-prefix*))
                            (set! from (point))
                            ;; "FROM, and point, are now before the text
                            ;; to fill, but after any fill prefix on the
                            ;; first line."
                            (fill-delete-newlines from to justify nosqueeze
                                                  squeeze-after)
                            ;; "This is the actual filling loop."
                            (goto-char from)
                            (let loop ((linebeg #f))
                              (when (< (point) (marker-position to))
                                (let ((linebeg (point)))
                                  (move-to-column (current-fill-column))
                                  (if (if (and (< (point) (marker-position to))
                                               (< linebeg (marker-position to)))
                                          (begin
                                            ;; "Find the position where
                                            ;; we'll break the line. Use
                                            ;; an immediately following
                                            ;; space, if any. However,
                                            ;; note that `move-to-column'
                                            ;; may overshoot if there are
                                            ;; wide characters (Bug#3234)."
                                            (if (not (> (current-column)
                                                        (current-fill-column)))
                                                (forward-char 1))
                                            (fill-move-to-break-point linebeg)
                                            ;; "Check again to see if we
                                            ;; got to the end of the
                                            ;; paragraph."
                                            (skip-chars-forward " \t")
                                            (< (point) (marker-position to)))
                                          #f)
                                      ;; "Found a place to cut."
                                      (begin
                                        (fill-newline)
                                        (when justify
                                          ;; "Justify the line just
                                          ;; ended, if desired."
                                          (save-excursion
                                            (forward-line -1)
                                            (justify-current-line justify #f #t)))
                                        (loop linebeg))
                                      (begin
                                        (goto-char to)
                                        ;; "Justify this last line, if
                                        ;; desired."
                                        (if justify
                                            (justify-current-line justify #t #t))
                                        #f))))))))
                      ;; "Leave point after final newline."
                      (goto-char to)
                      (if (not (eobp)) (forward-char 1))
                      (set-marker to #f)
                      ;; "Return the fill-prefix we used."
                      (*fill-prefix*))))))))

    (define *fill-region-as-paragraph-function*
      (make-parameter fill-region-as-paragraph-default))
    ;; ^ GNU Emacs's `fill-region-as-paragraph-function' (`fill.el:807').
    ;; A parameter because `fill-paragraph-semlf' `let`-binds it.

    (define-command (fill-region-as-paragraph from to . rest)
      ;; GNU Emacs's `fill-region-as-paragraph' (`fill.el:812'): "Fill
      ;; the region as if it were a single paragraph. The behavior of
      ;; this command is controlled by the variable
      ;; `fill-region-as-paragraph-function', with the default
      ;; implementation being `fill-region-as-paragraph-default'."
      ;;--------------------------------------------------------------
      "Fill the region as if it were a single paragraph.
The behavior of this command is controlled by the variable
`fill-region-as-paragraph-function', with the default implementation
being `fill-region-as-paragraph-default'.

The arguments FROM and TO define the boundaries of the region."
      (interactive (list (region-beginning) (region-end)
                         (if (current-prefix-arg) 'full #f)))
      ((*fill-region-as-paragraph-function*) from to
                                            (and (pair? rest) (car rest))
                                            (and (pair? rest) (pair? (cdr rest))
                                                 (cadr rest))
                                            (and (pair? rest) (pair? (cdr rest))
                                                 (pair? (cddr rest))
                                                 (caddr rest))))

    (define (skip-line-prefix prefix)
      ;; GNU Emacs's `skip-line-prefix' (`fill.el:840', a `defsubst`):
      ;; "If point is inside the string PREFIX at the beginning of line,
      ;; move past it."
      ;;--------------------------------------------------------------
      (when (and prefix
                 (< (- (point) (line-beginning-position)) (string-length prefix))
                 (save-excursion
                   (beginning-of-line 1)
                   (looking-at (regexp-quote prefix))))
        (goto-char (match-end 0))))

    (define (fill-minibuffer-function arg)
      ;; GNU Emacs's `fill-minibuffer-function' (`fill.el:849'): "Fill a
      ;; paragraph in the minibuffer, ignoring the prompt."
      ;;--------------------------------------------------------------
      (save-restriction
        (narrow-to-region (minibuffer-prompt-end) (point-max))
        (fill-paragraph arg #f)))

    (define (fill-forward-paragraph arg)
      ;; GNU Emacs's `fill-forward-paragraph' (`fill.el:861').
      ;;--------------------------------------------------------------
      (fill-forward-paragraph-function arg))

    (define-command (fill-paragraph . rest)
      ;; GNU Emacs's `fill-paragraph' (`fill.el:864'): "Fill paragraph at
      ;; or after point. If JUSTIFY is non-nil (interactively, with
      ;; prefix argument), justify as well. ... The REGION argument is
      ;; non-nil if called interactively; in that case, if Transient Mark
      ;; mode is enabled and the mark is active, call `fill-region' to
      ;; fill each of the paragraphs in the active region, instead of
      ;; just filling the current paragraph."
      ;;
      ;; The four strategies are Emacs's `or` chain, in the C's order.
      ;;--------------------------------------------------------------
      "Fill paragraph at or after point.

If JUSTIFY is non-nil (interactively, with prefix argument), justify as well.
If `sentence-end-double-space' is non-nil, then period followed by one
space does not end a sentence, so don't break a line there.
The variable `fill-column' controls the width for filling.

If `fill-paragraph-function' is non-nil, we call it (passing our
argument to it), and if it returns non-nil, we simply return its value.

If `fill-paragraph-function' is nil, return the `fill-prefix' used for filling."
      (interactive (list (if (current-prefix-arg) 'full #f) #t))
      (let ((justify (and (pair? rest) (car rest)))
            (region (and (pair? rest) (pair? (cdr rest)) (cadr rest))))
        (with-buffer-unmodified-if-unchanged
         (or
          ;; "1. Fill the region if it is active when called
          ;; interactively."
          (and region (transient-mark-mode) (mark-active)
               (not (eq? (region-beginning) (region-end)))
               (or (fill-region (region-beginning) (region-end) justify) #t))
          ;; "2. Try fill-paragraph-function."
          (and (not (eq? (*fill-paragraph-function*) #t))
               (or (*fill-paragraph-function*)
                   (and (minibufferp) (= 1 (point-min))))
               (let ((function (or (*fill-paragraph-function*)
                                   ;; "In the minibuffer, don't count the
                                   ;; width of the prompt."
                                   fill-minibuffer-function)))
                     ;; "If fill-paragraph-function is set, it probably
                     ;; takes care of comments and stuff. If not, it will
                     ;; have to set fill-paragraph-handle-comment back to
                     ;; t explicitly or return nil." The C's two bindings
                     ;; are the `parameterize` below, which is what makes
                     ;; this tree's spelling of them the same thing.
                 (parameterize ((*fill-paragraph-handle-comment* #f)
                                (*fill-paragraph-function* #t))
                   (function justify))))
          ;; "3. Try our syntax-aware filling code."
          (and (*fill-paragraph-handle-comment*)
               ;; "Our code only handles \n-terminated comments right now."
               (comment-start) (equal? (comment-end) "")
               (parameterize ((*fill-paragraph-handle-comment* #f))
                 (fill-comment-paragraph justify)))
          ;; "4. If it all fails, default to the good ol' text paragraph
          ;; filling."
          (let ((before (point))
                (paragraph-start-orig (*paragraph-start*))
                ;; "Fill prefix used for filling the paragraph."
                (fill-pfx #f))
            ;; "Try to prevent code sections and comment sections from
            ;; being filled together."
            (parameterize ((*paragraph-start*
                            (if (and (*fill-paragraph-handle-comment*)
                                     (comment-start-skip))
                                (string-append
                                 (*paragraph-start*) "\\\\|[ \t]*\\(?:"
                                 (comment-start-skip) "\\)")
                                (*paragraph-start*))))
              (save-excursion
                ;; "To make sure the return value of forward-paragraph is
                ;; meaningful, we have to start from the beginning of
                ;; line, otherwise skipping past the last few chars of a
                ;; paragraph-separator would count as a paragraph (and
                ;; not skipping any chars at EOB would not count as a
                ;; paragraph even if it is)."
                (move-to-left-margin 1 #f)
                (if (not (zero? (fill-forward-paragraph 1)))
                    ;; "There's no paragraph at or after point: give up."
                    (set! fill-pfx "")
                    (let* ((end (point))
                           (beg (begin (fill-forward-paragraph -1) (point))))
                      ;; "If the paragraph starts with a comment line
                      ;; preceding point on a non-comment line, skip such
                      ;; comment lines, so they are not filled together
                      ;; (bug#80449)."
                      (when (and (*fill-paragraph-handle-comment*)
                                 (comment-start-skip)
                                 (< beg before))
                        (save-excursion
                          (goto-char beg)
                          (when (looking-at paragraph-start-orig)
                            (goto-char (+ 1 (match-end 0))))
                          (when (looking-at (comment-start-skip))
                            (forward-line 1)
                            (set! beg (point)))))
                      (goto-char before)
                      (set! fill-pfx
                            (if (*use-hard-newlines*)
                                ;; "Can't use fill-region-as-paragraph,
                                ;; since this paragraph may still contain
                                ;; hard newlines. See fill-region."
                                (fill-region beg end justify #f #f)
                                (fill-region-as-paragraph beg end
                                                          justify)))))))
            fill-pfx)))))

    (define-command (unfill-paragraph arg . rest)
      ;; GNU Emacs's `unfill-paragraph' (`fill.el:959'): "Join lines of
      ;; this paragraph and fix up whitespace at joins."
      ;;
      ;; The C's `(let ((fill-column most-positive-fixnum)) ...)` is the
      ;; override parameter - the only way a dynamic rebinding of a
      ;; buffer-local reaches `current-fill-column` here.
      ;;--------------------------------------------------------------
      "Join lines of this paragraph and fix up whitespace at joins.
Interactively, if the region is active, join lines of each paragraph in
the region.  A numeric prefix argument means join the lines of the
following ARG paragraphs.  In this case an active region is ignored.

With an active region and no prefix argument this is roughly the same as
`delete-indentation' with that active region, except that this command
only joins lines within paragraphs, preserving the paragraphs
themselves."
      (interactive (list (current-prefix-arg)
                         (region-beginning) (region-end)))
      (let ((beg (and (pair? rest) (car rest)))
            (end (and (pair? rest) (pair? (cdr rest)) (cadr rest))))
        (when (or arg (not beg))
          (let ((arg (cond ((pair? arg) (car arg))
                           ((integer? arg) arg)
                           (else 1))))
            (when (zero? arg)
              (error "Invalid numeric argument to `unfill-paragraph'"))
            (save-excursion
              (fill-forward-paragraph 1)
              (fill-forward-paragraph -1)
              (set! beg (point))
              (fill-forward-paragraph arg)
              (set! end (point)))))
        ;; Emacs's `(let ((fill-column most-positive-fixnum)) (fill-region
        ;; beg end))'.
        (parameterize ((*fill-column-override* 4611686018427387903))
          (fill-region beg end))))


    ;;----------------------------------------------------------------
    ;; `fill-comment-paragraph'
    ;;----------------------------------------------------------------

    (define (fill-comment-paragraph . rest)
      ;; GNU Emacs's `fill-comment-paragraph' (`fill.el:1002'): "Fill
      ;; current comment. If we're not in a comment, just return nil so
      ;; that the caller can take care of filling. JUSTIFY is used as in
      ;; `fill-paragraph'."
      ;;--------------------------------------------------------------
      (let ((justify (and (pair? rest) (car rest))))
        (comment-normalize-vars)
        ;; "Non-nil if it contains code and a comment."
        (let ((has-code-and-comment #f)
              (comstart #f)
              (comin #f))
          ;; "Figure out what kind of comment we are looking at."
          (save-excursion
            (beginning-of-line 1)
            (let ((cs (comment-search-forward (line-end-position) #t)))
              (when cs
                (set! comstart cs)
                (set! comin (point))
                (goto-char comstart)
                (skip-chars-backward " \t")
                (set! has-code-and-comment (not (bolp))))))
          (if (not (and comstart
                        ;; "Make sure the comment-start mark we found is
                        ;; accepted by comment-start-skip. If not, all bets
                        ;; are off, and we'd better not mess with it."
                        (string-match (comment-start-skip)
                                      (buffer-substring comstart comin))))
              ;; "Return nil, so the normal filling will take place."
              #f
              ;; "Narrow to include only the comment, and then fill the
              ;; region."
              (let* ((commark (comment-string-strip
                               (buffer-substring comstart comin) #f #t))
                     (comment-re
                      ;; "A regexp more specialized than
                      ;; comment-start-skip, that only matches the current
                      ;; commark rather than any valid commark."
                      (if (string-match (comment-start-skip)
                                        (string-append "\0" commark "a"))
                          (string-append "[ \t]*" (regexp-quote commark)
                                         ;; "Make sure we only match comments
                                         ;; that use the exact same comment
                                         ;; marker."
                                         "[^" (substring commark
                                                         (- (string-length commark) 1))
                                         "]")
                          (string-append "[ \t]*\\(?:" (comment-start-skip)
                                         "\\)")))
                     ;; "Compute a fill prefix."
                     (comment-fill-prefix
                      (save-excursion
                        (goto-char comstart)
                        (if has-code-and-comment
                            (string-append
                             (if (not (*indent-tabs-mode*))
                                 (make-string (current-column) #\space)
                                 (string-append
                                  (make-string (quotient (current-column)
                                                         (*tab-width*))
                                               #\tab)
                                  (make-string (remainder (current-column)
                                                          (*tab-width*))
                                               #\space)))
                             (buffer-substring (point) comin))
                            (buffer-substring (line-beginning-position) comin))))
                     (beg #f)
                     (end #f))
                (let ((result
                       (save-excursion
                         (save-restriction
                           (beginning-of-line 1)
                           (narrow-to-region
                            ;; "Find the first line we should include in
                            ;; the region to fill."
                            (if has-code-and-comment
                                (line-beginning-position)
                                (save-excursion
                                  (let skip ()
                                    (when (and (zero? (forward-line -1))
                                               (looking-at comment-re))
                                      (skip)))
                                  ;; "We may have gone too far. Go forward
                                  ;; again."
                                  (line-beginning-position
                                   (if (begin
                                         (goto-char
                                          (or (comment-search-forward
                                               (line-end-position) #t)
                                              (point)))
                                         (looking-at comment-re))
                                       (begin (set! comstart (point)) 1)
                                       (begin (set! comstart (point)) 2)))))
                            ;; "Find the beginning of the first line past
                            ;; the region to fill."
                            (save-excursion
                              (let skip ()
                                (when (begin (forward-line 1)
                                             (looking-at comment-re))
                                  (skip)))
                              (point)))
                           ;; "Obey paragraph starters and boundaries
                           ;; within comments."
                           (parameterize
                               ((*paragraph-separate*
                                 (string-append
                                  (*paragraph-separate*) "\\|[ \t]*\\(?:"
                                  (or (comment-start-skip) "") "\\)\\(?:"
                                  (*paragraph-separate*) "\\)"))
                                (*paragraph-start*
                                 (string-append
                                  (*paragraph-start*) "\\|[ \t]*\\(?:"
                                  (or (comment-start-skip) "") "\\)\\(?:"
                                  (*paragraph-start*) "\\)")))
                             ;; "We now use comment-re to 'manually' make
                             ;; sure we treat comment-marker changes as
                             ;; paragraph boundaries."
                             (let ((after-line (and has-code-and-comment
                                                    (line-beginning-position 2))))
                               (set! end (begin (forward-paragraph 1) (point)))
                               ;; "If this comment starts on a line with
                               ;; code, include that line in the filling."
                               (set! beg (begin
                                           (backward-paragraph 1)
                                           (if (eq? (point) after-line)
                                               (forward-line -1))
                                           (point)))))
                           ;; "Find the fill-prefix to use."
                           (cond ((*fill-prefix*) #f) ; "Use the
                                                      ; user-provided fill
                                                      ; prefix."
                                 ((and (*adaptive-fill-mode*)
                                       (begin
                                         (*fill-prefix*
                                          (fill-context-prefix beg end))
                                         (string-match (comment-start-skip)
                                                       (*fill-prefix*))))
                                  #f)
                                 (else (*fill-prefix* comment-fill-prefix)))
                           ;; "Don't fill with narrowing."
                           (or (fill-region-as-paragraph
                                (max comstart beg) end justify #f
                                ;; "Don't canonicalize spaces within the
                                ;; code just before the comment."
                                (save-excursion
                                  (goto-char beg)
                                  (if (looking-at (*fill-prefix*))
                                      #f
                                      (re-search-forward (comment-start-skip)))))
                               ;; "Make sure we don't return nil."
                               #t)))))
                  result))))))

    ;;----------------------------------------------------------------
    ;; `fill-region'
    ;;----------------------------------------------------------------

    (define-command (fill-region from to . rest)
      ;; GNU Emacs's `fill-region' (`fill.el:1135'): "Fill each of the
      ;; paragraphs in the region."
      ;;--------------------------------------------------------------
      "Fill each of the paragraphs in the region.
A prefix arg means justify as well.
The `fill-column' variable controls the width.

Noninteractively, the third argument JUSTIFY specifies which
kind of justification to do: `full', `left', `right', `center',
or `none' (equivalent to nil).  A value of t means handle each
paragraph as specified by its text properties.

The fourth arg NOSQUEEZE non-nil means to leave whitespace other
than line breaks untouched, and fifth arg TO-EOP non-nil means
to keep filling to the end of the paragraph (or next hard newline,
if variable `use-hard-newlines' is on).

Return the `fill-prefix' used for filling the last paragraph.

If `sentence-end-double-space' is non-nil, then period followed by one
space does not end a sentence, so don't break a line there."
      (interactive (list (region-beginning) (region-end)
                         (if (current-prefix-arg) 'full #f)))
      (let ((justify (and (pair? rest) (car rest)))
            (nosqueeze (and (pair? rest) (pair? (cdr rest)) (cadr rest)))
            (to-eop (and (pair? rest) (pair? (cdr rest)) (pair? (cddr rest))
                         (caddr rest))))
        (if (not (memv justify (list #t #f 'none 'full 'center 'left 'right)))
            (set! justify 'full))
        (let ((start-point (point-marker)))
          (goto-char (max from to))
          (when to-eop
            (skip-chars-backward "\n")
            (fill-forward-paragraph 1))
          (let ((max (copy-marker (point) #t))
                (fill-pfx #f))
            (let ((beg (min from to)))
              (goto-char beg)
              (beginning-of-line 1)
              (let loop ((beg beg) (fill-pfx #f))
                (if (< (point) (marker-position max))
                    (let ((initial (point))
                          (end #f))
                      ;; "If using hard newlines, break at every one for
                      ;; filling purposes rather than using paragraph
                      ;; breaks."
                      (if (*use-hard-newlines*)
                          (begin
                            (let skip ()
                              (let ((e (text-property-any (point) (marker-position max) 'hard #t)))
                                (set! end e)
                                (when (and e
                                           (not (char=? #\newline (char-after e)))
                                           (not (>= e (marker-position max))))
                                  (goto-char (+ 1 e))
                                  (skip))))
                            (set! end (if end (min (marker-position max) (+ 1 end))
                                           (marker-position max)))
                            (goto-char initial))
                          (begin
                            (fill-forward-paragraph 1)
                            (set! end (min (marker-position max) (point)))
                            (fill-forward-paragraph -1)))
                      (if (< (point) beg)
                          (goto-char beg))
                      (if (and (>= (point) initial) (< (point) end))
                          (loop beg (fill-region-as-paragraph
                                     (point) end justify nosqueeze))
                          (begin (goto-char end)
                                 (loop beg fill-pfx))))
                    (begin
                      (goto-char start-point)
                      (set-marker start-point #f)
                      fill-pfx))))))))

    ;;----------------------------------------------------------------
    ;; The justification half (`fill.el:1200-1510')
    ;;----------------------------------------------------------------

    (define (current-justification)
      ;; GNU Emacs's `current-justification' (`fill.el:1217'): "How
      ;; should we justify this line? This returns the value of the
      ;; text-property `justification', or the variable
      ;; `default-justification' if there is no text-property. However,
      ;; it returns nil rather than `none' to mean \"don't justify\"."
      ;;--------------------------------------------------------------
      (let ((j (or (get-text-property
                    ;; "Make sure we're looking at paragraph body."
                    (save-excursion
                      (skip-chars-forward " \t")
                      (if (and (eobp) (not (bobp)))
                          (- (point) 1)
                          (point)))
                    'justification)
                   (*default-justification*))))
        (if (eq? 'none j) #f j)))

    (define-command (set-justification begin end style . rest)
      ;; GNU Emacs's `set-justification' (`fill.el:1233'): "Set the
      ;; region's justification style to STYLE."
      ;;--------------------------------------------------------------
      "Set the region's justification style to STYLE.
This commands prompts for the kind of justification to use.
See `default-justification' for the possible values and their meaning."
      (interactive (list (if (mark-active) (region-beginning) (point))
                         (if (mark-active) (region-end) (point))
                         (intern (let ((s (completing-read
                                           "Set justification to: "
                                           '(("left") ("right") ("full")
                                             ("center") ("none"))
                                           #f #t)))
                                   (if (equal? s "") (error ""))
                                   s))
                         #t))
      (let ((whole-par (and (pair? rest) (car rest))))
        (save-excursion
          (save-restriction
            (when whole-par
              (parameterize ((*paragraph-start*
                              (if (*use-hard-newlines*) "." (*paragraph-start*)))
                             (*paragraph-ignore-fill-prefix*
                              (if (*use-hard-newlines*) #t
                                  (*paragraph-ignore-fill-prefix*))))
                (goto-char begin)
                (let skip ()
                  (when (and (bolp) (not (eobp)))
                    (forward-char 1)
                    (skip)))
                (backward-paragraph 1)
                (set! begin (point))
                (goto-char end)
                (skip-chars-backward " \t\n" begin)
                (forward-paragraph 1)
                (set! end (point))))
            (narrow-to-region (point-min) end)
            (unjustify-region begin (point-max))
            (put-text-property begin (point-max) 'justification style)
            (fill-region begin (point-max) #f #t)))))

    (define-command (set-justification-none b e)
      "Disable automatic filling for paragraphs in the region.
If the mark is not active, this applies to the current paragraph."
      (interactive (list (if (mark-active) (region-beginning) (point))
                         (if (mark-active) (region-end) (point))))
      (set-justification b e 'none #t))

    (define-command (set-justification-left b e)
      "Make paragraphs in the region left-justified.
This means lines are flush (lined up) at the left margin and ragged
on the right.
This is usually the default, but see the variable `default-justification'.
If the mark is not active, this applies to the current paragraph."
      (interactive (list (if (mark-active) (region-beginning) (point))
                         (if (mark-active) (region-end) (point))))
      (set-justification b e 'left #t))

    (define-command (set-justification-right b e)
      "Make paragraphs in the region right-justified.
This means lines are flush (lined up) at the right margin and ragged
on the left.
If the mark is not active, this applies to the current paragraph."
      (interactive (list (if (mark-active) (region-beginning) (point))
                         (if (mark-active) (region-end) (point))))
      (set-justification b e 'right #t))

    (define-command (set-justification-full b e)
      "Make paragraphs in the region fully justified.
This makes lines be lined up on both margins by inserting spaces between words.
If the mark is not active, this applies to the current paragraph."
      (interactive (list (if (mark-active) (region-beginning) (point))
                         (if (mark-active) (region-end) (point))))
      (set-justification b e 'full #t))

    (define-command (set-justification-center b e)
      "Make paragraphs in the region centered.
If the mark is not active, this applies to the current paragraph."
      (interactive (list (if (mark-active) (region-beginning) (point))
                         (if (mark-active) (region-end) (point))))
      (set-justification b e 'center #t))

    (define (justify-current-line . rest)
      ;; GNU Emacs's `justify-current-line' (`fill.el:1337'): "Do some
      ;; kind of justification on this line."
      ;;
      ;; "A line has up to six parts: [Indent-1][FP][Indent-2][text]
      ;; [trailing whitespace][newline]" - the comment block above the C
      ;; is the account of them, and the arithmetic below is its.
      ;;
      ;; Elisp's `if` takes `(if COND THEN ELSE...)' and Scheme's takes
      ;; one ELSE, so every arm of the C's `if` that carries several
      ;; forms is a `begin` here.
      ;;--------------------------------------------------------------
      (let ((how (and (pair? rest) (car rest)))
            (eop (and (pair? rest) (pair? (cdr rest)) (cadr rest)))
            (nosqueeze (and (pair? rest) (pair? (cdr rest))
                            (pair? (cddr rest)) (caddr rest))))
        (if (eq? how #t)
            (set! how (or (current-justification) 'none))
            (if (not how)
                (set! how 'full)
                (or (memv how '(none left right center))
                    (set! how 'full))))
        (if (memv how '(none left))
            #f
            (let ((fc (current-fill-column))
                  (pos (point-marker))
                  (fp-end #f)
                  (beg #f)
                  (end #f)
                  (indent #f)
                  (endcol #f)
                  (ncols #f)
                  (nspaces 0)
                  (curr-fracspace 0)
                  (count #f))
              (end-of-line 1)
              ;; "Check if this is the last line of the paragraph."
              (if (and (*use-hard-newlines*) (not eop)
                       (get-text-property (point) 'hard))
                  (set! eop #t))
              (skip-chars-backward " \t")
              (if (or (bolp)
                      (and (memv how '(full right))
                           (= (current-column) fc)))
                  ;; "Quick exit if it appears to be properly justified
                  ;; already or there is no text."
                  #f
                  (begin
                    (set! end (point))
                    (beginning-of-line 1)
                    (skip-chars-forward " \t")
                    (if (and (*fill-prefix*)
                             (not (string=? (*fill-prefix*) ""))
                             (equal? (*fill-prefix*)
                                     (buffer-substring
                                      (point)
                                      (min (point-max)
                                           (+ (string-length (*fill-prefix*))
                                              (point))))))
                        (forward-char (string-length (*fill-prefix*)))
                        (if (and (*adaptive-fill-mode*)
                                 (looking-at (*adaptive-fill-regexp*)))
                            (goto-char (match-end 0))))
                    (set! fp-end (point))
                    (skip-chars-forward " \t")
                    (set! indent (current-column))
                    (set! beg (point))
                    (goto-char end)
                    (set! endcol (current-column))
                    (cond
                     ((eq? 'right how)
                      (set! ncols (- fc endcol))
                      (if (< ncols 0)
                          (delete-region
                           (begin
                             (goto-char fp-end)
                             (if (< (current-column) (+ indent ncols))
                                 (move-to-column (+ indent ncols) #t))
                             (point))
                           (begin (move-to-column indent) (point)))
                          (begin
                            (goto-char beg)
                            (indent-to (+ indent ncols))
                            (if (= beg (marker-position pos))
                                (set-marker pos (point))))))
                     ((eq? 'center how)
                      (set! ncols (+ (current-left-margin)
                                     (quotient (- fc (current-left-margin)
                                                  (- endcol indent))
                                               2)))
                      (if (< ncols indent)
                          (delete-region
                           (begin
                             (goto-char fp-end)
                             (if (< (current-column) ncols)
                                 (move-to-column ncols #t))
                             (point))
                           (begin (move-to-column indent) (point)))
                          (begin
                            (goto-char beg)
                            (indent-to ncols)
                            (if (= beg (marker-position pos))
                                (set-marker pos (point))))))
                     ((eq? 'full how)
                      (save-restriction
                        (narrow-to-region beg end)
                        (or nosqueeze
                            (canonically-space-region beg end))
                        (goto-char (point-max))
                        (let count-spaces ()
                          (when (search-backward " " #f #t)
                            (set! nspaces (+ nspaces 1))
                            (skip-chars-backward " ")
                            (count-spaces)))
                        (set! ncols (- fc endcol))
                        (when (and (> ncols 0) (> nspaces 0) (not eop))
                          (set! curr-fracspace (+ ncols (quotient nspaces 2)))
                          (set! count nspaces)
                          (let loop ()
                            (when (> count 0)
                              (skip-chars-forward " ")
                              (insert-char #\space
                                           (quotient curr-fracspace nspaces) #t)
                              (search-forward " " #f #t)
                              (set! count (- count 1))
                              (set! curr-fracspace
                                    (+ (remainder curr-fracspace nspaces) ncols))
                              (loop))))))
                     (else (error "Unknown justification value")))
                    (goto-char pos)
                    (set-marker pos #f)))
              #f))))

    (define (unjustify-current-line)
      ;; GNU Emacs's `unjustify-current-line' (`fill.el:1469'): "Remove
      ;; justification whitespace from current line."
      ;;--------------------------------------------------------------
      (let ((justify (current-justification)))
        (cond ((eq? 'left justify) #f)
              ((not justify) #f)
              ((eq? 'full justify)     ; "full justify: remove extra spaces"
               (beginning-of-line-text)
               (canonically-space-region (point) (line-end-position)))
              ((memv justify '(center right))
               (save-excursion
                 (move-to-left-margin #f #t)
                 ;; "Position ourselves after any fill-prefix."
                 (if (and (*fill-prefix*)
                          (not (string=? (*fill-prefix*) ""))
                          (equal? (*fill-prefix*)
                                  (buffer-substring
                                   (point)
                                   (min (point-max)
                                        (+ (string-length (*fill-prefix*))
                                           (point))))))
                     (forward-char (string-length (*fill-prefix*))))
                 (delete-region (point) (begin (skip-chars-forward " \t")
                                               (point))))))))

    (define (unjustify-region . rest)
      ;; GNU Emacs's `unjustify-region' (`fill.el:1494'): "Remove
      ;; justification whitespace from region."
      ;;--------------------------------------------------------------
      (let ((begin (and (pair? rest) (car rest)))
            (end (and (pair? rest) (pair? (cdr rest)) (cadr rest))))
        (save-excursion
          (save-restriction
            (if end (narrow-to-region (point-min) end))
            (goto-char (or begin (point-min)))
            (let loop ()
              (when (not (eobp))
                (unjustify-current-line)
                (forward-line 1)
                (loop)))))))

    (define (beginning-of-line-text . rest)
      ;; GNU Emacs's `beginning-of-line-text' (`indent.el:519'): "Move to
      ;; the beginning of the text on this line."
      ;;
      ;; **`indent.el`'s, and it lives here**: its last step asks
      ;; `current-justification`, which is this file's, and `indent.scm`
      ;; sits below this one - the same downward/upward cut as
      ;; `back-to-indentation`.
      ;;--------------------------------------------------------------
      (let ((n (and (pair? rest) (car rest))))
        (beginning-of-line (if n n 1))
        (skip-chars-forward " \t")
        ;; "Skip over fill-prefix."
        (if (and (*fill-prefix*)
                 (not (string=? (*fill-prefix*) "")))
            (if (equal? (*fill-prefix*)
                        (buffer-substring
                         (point)
                         (min (point-max) (+ (string-length (*fill-prefix*))
                                             (point)))))
                (forward-char (string-length (*fill-prefix*))))
            (if (and (*adaptive-fill-mode*) (*adaptive-fill-regexp*)
                     (looking-at (*adaptive-fill-regexp*)))
                (goto-char (match-end 0))))
        ;; "Skip centering or flushright indentation"
        (if (memv (current-justification) '(center right))
            (skip-chars-forward " \t"))
        #f))

    ;;----------------------------------------------------------------
    ;; `fill-individual-paragraphs'
    ;;----------------------------------------------------------------

    (define-command (fill-nonuniform-paragraphs min max . rest)
      ;; GNU Emacs's `fill-nonuniform-paragraphs' (`fill.el:1509'): "Fill
      ;; paragraphs within the region, allowing varying indentation within
      ;; each."
      ;;--------------------------------------------------------------
      "Fill paragraphs within the region, allowing varying indentation within each.
This command divides the region into \"paragraphs\",
only at paragraph-separator lines, then fills each paragraph
using as the fill prefix the smallest indentation of any line
in the paragraph.

When calling from a program, pass range to fill as first two arguments."
      (interactive (list (region-beginning) (region-end)
                         (if (current-prefix-arg) 'full #f)))
      (parameterize ((*fill-individual-varying-indent* #t))
        (fill-individual-paragraphs min max
                                    (and (pair? rest) (car rest))
                                    (and (pair? rest) (pair? (cdr rest))
                                         (cadr rest)))))

    (define-command (fill-individual-paragraphs min max . rest)
      ;; GNU Emacs's `fill-individual-paragraphs' (`fill.el:1531'): "Fill
      ;; paragraphs of uniform indentation within the region."
      ;;--------------------------------------------------------------
      "Fill paragraphs of uniform indentation within the region.
This command divides the region into \"paragraphs\",
treating every change in indentation level or prefix as a paragraph boundary,
then fills each paragraph using its indentation level as the fill prefix.

There is one special case where a change in indentation does not start
a new paragraph.  This is for text of this form:

   foo>    This line with extra indentation starts
   foo> a paragraph that continues on more lines.

These lines are filled together.

When calling from a program, pass the range to fill
as the first two arguments."
      (interactive (list (region-beginning) (region-end)
                         (if (current-prefix-arg) 'full #f)))
      (let ((justify (and (pair? rest) (car rest)))
            (citation-regexp (and (pair? rest) (pair? (cdr rest))
                                  (cadr rest))))
        (save-restriction
          (save-excursion
            (goto-char min)
            (beginning-of-line 1)
            (narrow-to-region (point) max)
            (if citation-regexp
                (let loop ()
                  (when (and (not (eobp))
                             (or (looking-at "[ \t]*[^ \t\n]+:")
                                 (looking-at "[ \t]*$")))
                    (if (looking-at "[ \t]*[^ \t\n]+:")
                        (search-forward "\n\n" #f 'move)
                        (forward-line 1))
                    (loop))))
            (narrow-to-region (point) max)
            ;; "Loop over paragraphs."
            (let loop ()
              (when (begin
                      ;; "Skip over all paragraph-separating lines so as
                      ;; to not include them in any paragraph."
                      (let skip ()
                        (when (and (not (eobp))
                                   (begin (move-to-left-margin 1 #f)
                                          (and (not (eobp))
                                               (looking-at (*paragraph-separate*)))))
                          (forward-line 1)
                          (skip)))
                      (skip-chars-forward " \t\n")
                      (not (eobp)))
                (move-to-left-margin 1 #f)
                (let ((start (point))
                      (fill-prefix #f)
                      (fill-prefix-regexp #f))
                  ;; "Find end of paragraph, and compute the smallest
                  ;; fill-prefix that fits all the lines in this
                  ;; paragraph."
                  (let inner ()
                    (when (begin
                            ;; "Update the fill-prefix on the first line
                            ;; and whenever the prefix good so far is too
                            ;; long."
                            (if (not (and fill-prefix
                                          (looking-at fill-prefix-regexp)))
                                (begin
                                  (set! fill-prefix
                                        (fill-individual-paragraphs-prefix
                                         citation-regexp))
                                  (set! fill-prefix-regexp
                                        (regexp-quote fill-prefix))))
                            (forward-line 1)
                            (if (bolp)
                                ;; "If forward-line went past a newline,
                                ;; move further to the left margin."
                                (move-to-left-margin 1 #f))
                            ;; "Now stop the loop if end of paragraph."
                            (and (not (eobp))
                                 (if *fill-individual-varying-indent*
                                     ;; "If this line is a separator line,
                                     ;; with or without prefix, end the
                                     ;; paragraph."
                                     (and
                                      (not (looking-at (*paragraph-separate*)))
                                      (save-excursion
                                        (not (and (looking-at
                                                   fill-prefix-regexp)
                                                  (begin
                                                    (forward-char
                                                     (string-length fill-prefix))
                                                    (looking-at
                                                     (*paragraph-separate*)))))))
                                     ;; "If this line has more or less indent
                                     ;; than the fill prefix wants, end the
                                     ;; paragraph."
                                     (and (looking-at fill-prefix-regexp)
                                          ;; "If fill prefix is shorter than
                                          ;; a new fill prefix computed here,
                                          ;; end paragraph."
                                          (let ((this-line-fill-prefix
                                                 (fill-individual-paragraphs-prefix
                                                  citation-regexp)))
                                            (>= (string-length fill-prefix)
                                                (string-length
                                                 this-line-fill-prefix)))
                                          (save-excursion
                                            (not (begin
                                                   (forward-char
                                                    (string-length fill-prefix))
                                                   (or (looking-at "[ \t]")
                                                       (looking-at
                                                        (*paragraph-separate*))
                                                       (looking-at
                                                        (*paragraph-start*))))))
                                          (not (and (equal? fill-prefix "")
                                                    citation-regexp
                                                    (looking-at
                                                     citation-regexp)))))))
                      (inner)))
                  ;; "Fill this paragraph, but don't add a newline at the
                  ;; end."
                  (let ((had-newline (bolp)))
                    (fill-region-as-paragraph start (point) justify)
                    (if (and (bolp) (not had-newline))
                        (delete-char -1))))
                ;; **The recursion is the `while`'s body**: written as a
                ;; sibling of the `when` it loops for ever whether or not
                ;; the paragraph loop is done, which is what this did
                ;; before it was caught.
                (loop)))))))

    (define (fill-individual-paragraphs-prefix citation-regexp)
      ;; GNU Emacs's `fill-individual-paragraphs-prefix'
      ;; (`fill.el:1638').
      ;;--------------------------------------------------------------
      (let* ((just-one-line-prefix
              ;; "Accept any prefix rather than just the ones matched by
              ;; `adaptive-fill-first-line-regexp'."
              (parameterize ((*adaptive-fill-first-line-regexp* ".*"))
                (fill-context-prefix (point) (line-beginning-position 2))))
             (two-lines-prefix
              (fill-context-prefix (point) (line-beginning-position 3))))
        (if (not just-one-line-prefix)
            (buffer-substring
             (point) (save-excursion (skip-chars-forward " \t") (point)))
            ;; "See if the citation part of JUST-ONE-LINE-PREFIX is the
            ;; same as that of TWO-LINES-PREFIX, except perhaps with
            ;; longer whitespace."
            (if (and just-one-line-prefix two-lines-prefix
                     (let* ((one-line-citation-part
                             (fill-individual-paragraphs-citation
                              just-one-line-prefix citation-regexp))
                            (two-lines-citation-part
                             (fill-individual-paragraphs-citation
                              two-lines-prefix citation-regexp))
                            (adjusted-two-lines-citation-part
                             (substring two-lines-citation-part 0
                                        (string-match
                                         "[ \t]*\\'"
                                         two-lines-citation-part))))
                       (and
                        (string-match (string-append
                                       "\\`"
                                       (regexp-quote
                                        adjusted-two-lines-citation-part)
                                       "[ \t]*\\'")
                                      one-line-citation-part)
                        (>= (string-width one-line-citation-part)
                            (string-width two-lines-citation-part)))))
                two-lines-prefix
                just-one-line-prefix))))

    (define (fill-individual-paragraphs-citation string citation-regexp)
      ;; GNU Emacs's `fill-individual-paragraphs-citation'
      ;; (`fill.el:1674').
      ;;--------------------------------------------------------------
      (if citation-regexp
          (if (string-match citation-regexp string)
              (match-string 0 string)
              "")
          string))

    ;;----------------------------------------------------------------
    ;; Semantic linefeeds (`fill.el:1681', `:1745') - Emacs 31's
    ;; -----------------------------------------------------------------

    (define-command (fill-region-as-paragraph-semlf from to . rest)
      ;; GNU Emacs's `fill-region-as-paragraph-semlf' (`fill.el:1681'):
      ;; "Fill the region using semantic linefeeds as if it were a single
      ;; paragraph."
      ;;--------------------------------------------------------------
      "Fill the region using semantic linefeeds as if it were a single paragraph.
This command removes any paragraph breaks in the region and extra newlines
at the end, and fills lines within the region.  Text is refilled putting a
newline character after each sentence, calling `forward-sentence' to find
the ends of sentences."
      (interactive (list (region-beginning) (region-end)
                         (if (current-prefix-arg) 'full #f)))
      (let ((justify (and (pair? rest) (car rest)))
            (nosqueeze (and (pair? rest) (pair? (cdr rest)) (cadr rest)))
            (squeeze-after (and (pair? rest) (pair? (cdr rest))
                                (pair? (cddr rest)) (caddr rest))))
        (let* ((from (min from to))
               (to (copy-marker (max from to) #t))
               (pfx #f))
          (goto-char from)
          (let ((pfx (or (parameterize ((*fill-column-override*
                                         4611686018427387903))
                           (save-excursion
                             (fill-region-as-paragraph-default
                              (point) to #f nosqueeze squeeze-after)))
                         "")))
            (let loop ()
              (when (< (point) to)
                (let ((fill-to (copy-marker
                                (min to
                                     (save-excursion
                                       (forward-sentence 1)
                                       (point)))
                                #t)))
                  (parameterize ((*fill-prefix* pfx))
                    (fill-region-as-paragraph-default (point) fill-to justify #t))
                  (goto-char fill-to))
                (when (and (> (point) (line-beginning-position))
                           (< (point) (line-end-position))
                           (< (point) to))
                  (delete-horizontal-space #f)
                  (insert "\n")
                  (insert pfx))
                (loop)))
            pfx))))

    (define-command (fill-paragraph-semlf . rest)
      ;; GNU Emacs's `fill-paragraph-semlf' (`fill.el:1745'): "Fill
      ;; paragraph at or after point using semantic linefeeds."
      ;;--------------------------------------------------------------
      "Fill paragraph at or after point using semantic linefeeds.
Refill text putting a newline character after each sentence.

If JUSTIFY is non-nil (interactively, with prefix argument), justify as
well.  The REGION argument is non-nil if called interactively; in that
case, if Transient Mark mode is enabled and the mark is active, fill the
active region.

See `fill-paragraph' and `fill-region-as-paragraph-semlf' for more
details."
      (interactive (list (if (current-prefix-arg) 'full #f) #t))
      (let ((justify (and (pair? rest) (car rest)))
            (region (and (pair? rest) (pair? (cdr rest)) (cadr rest))))
        (parameterize ((*fill-region-as-paragraph-function*
                        fill-region-as-paragraph-semlf))
          (fill-paragraph justify region))))

    ;;----------------------------------------------------------------
    ;; `with-buffer-unmodified-if-unchanged' (`subr-x.el:678')
    ;;----------------------------------------------------------------

    (define-syntax with-buffer-unmodified-if-unchanged
      ;; GNU Emacs's `with-buffer-unmodified-if-unchanged'
      ;; (`subr-x.el:678'): "Like `progn', but change buffer-modified
      ;; status only if buffer text changes. If the buffer was unmodified
      ;; before execution of BODY, and buffer text after execution of BODY
      ;; is identical to what it was before, ensure that buffer is still
      ;; marked unmodified afterwards."
      ;;
      ;; **`subr-x.el`'s, and it is here** because `fill-paragraph` is its
      ;; only caller in this tree and the two things it needs -
      ;; `buffer-hash` (`fns.scm`) and the modified state (`buffer.scm`) -
      ;; are what this library already imports.
      ;;
      ;; The C hashes the buffer's raw text with SHA-1; `buffer-hash` here
      ;; hashes the code points (see its docstring for why SHA-1 is not
      ;; the one), which is the same contract: equal text, equal hash.
      ;;--------------------------------------------------------------
      (syntax-rules ()
        ((_ body ...)
         (let ((hash (and (not (buffer-modified-p)) (buffer-hash)))
               (buffer (current-buffer)))
           (let ((result (begin body ...)))
             ;; "If we didn't change anything in the buffer (and the buffer
             ;; was previously unmodified), then flip the modification
             ;; status back to 'unchanged'."
             (when (and hash (buffer-live-p buffer))
               (set-buffer buffer)
               (when (and (buffer-modified-p)
                          (equal? hash (buffer-hash)))
                 (restore-buffer-modified-p #f)))
             result)))))

    ;;----------------------------------------------------------------
    ;; The keys
    ;;----------------------------------------------------------------

    ;; **M-q, and only M-q.** Measured: in a fundamental-mode buffer
    ;; `(key-binding "\M-q")' is `fill-paragraph', and `fill-region'
    ;; answers nil to `where-is-internal' - it is M-x only. (In a
    ;; prog-mode buffer M-q is `prog-fill-reindent-defun', which is
    ;; `prog-mode.scm`'s to bind.)
    (define-key *default-keymap* (kbd "M-q") fill-paragraph)

    ))
