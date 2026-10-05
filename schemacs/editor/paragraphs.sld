(define-library (schemacs editor paragraphs)
  ;; This library mirrors GNU Emacs's `textmodes/paragraphs.el': the
  ;; paragraph motions and the kills that act on them -
  ;; `forward-paragraph', `backward-paragraph', `kill-paragraph' (M-k)
  ;; and `backward-kill-paragraph' (M-C-k).
  ;;
  ;; The motions work off `paragraph-start' and `paragraph-separate',
  ;; regexps whose DEFAULT values are blank-line patterns -
  ;; "\f\\|[ \t]*$" and "[ \t\f]*$" - and the walks here test that
  ;; meaning directly, line by line, there being no regexp engine yet.
  ;; The variables, the `fill-prefix' branches, `use-hard-newlines'
  ;; and `move-to-left-margin' are what the regexp walk of the
  ;; original carries; when a regexp comes, this file's walks become
  ;; that walk.
  ;;
  ;; See LAYOUT-PLAN.txt for the rule this library is a step of.

  (import
    ;; `kbd' - see `character.sld''s export note for why it is there
    (only (schemacs editor character) kbd)
    (scheme base)
    (only (schemacs editor engine)
          text-editor-char-count text-editor-get-char-index
          text-editor-get-cursor text-editor-get-start-of-line
          text-editor-get-end-of-line text-editor-set-cursor)
    (only (schemacs editor editfns) goto-char save-excursion forward-line)
    ;; the line ends and the blank-line question are simple.sld's -
    ;; `paragraph-separate''s default is a blank line.
    (only (schemacs editor simple)
          %blank-line? beginning-of-line end-of-line kill-region
          mark set-mark push-mark)
    (only (schemacs editor frame) current-editor)
    ;; the mark-active and transient-mark-mode of the extend branch are
    ;; `buffer.c''s variables, beside `*last-command*' which is
    ;; simple.sld's (the command loop binds it there)
    (only (schemacs editor buffer)
          current-buffer mark-active transient-mark-mode)
    (only (schemacs editor simple) *last-command*)
    (only (schemacs editor command) current-prefix-arg define-command
          uarg->integer)
    (only (schemacs editor keymap) define-key *default-keymap*)
    (only (scheme write) display)
    (only (guile) newline)
    )

  (export
   forward-paragraph
   backward-paragraph
   kill-paragraph
   backward-kill-paragraph
   mark-paragraph
   )

  (begin

    (define (%char-at ed index)
      ;; The character at INDEX, or #f: simple.sld's, for the walking
      ;; below.
      ;;--------------------------------------------------------------
      (text-editor-get-char-index ed index))

    (define (%paragraph-start-line? ed)
      ;; A line whose first character is a formfeed - the "\f\\|"
      ;; branch of the default `paragraph-start' - beside the blank
      ;; line the rest of it says. The cursor must be ON the line.
      ;;--------------------------------------------------------------
      (or (memv (%char-at ed (text-editor-get-start-of-line ed))
                (list (integer->char 12)))
          (%blank-line? ed)))

(define (%forward-line ed)
      ;; The public `forward-line' against ED - the Emacs-named one
      ;; answers against `(current-buffer)', and the walks here are
      ;; called with the walk's editor. The answer of interest to the
      ;; walks is whether the line moved at all.
      ;;--------------------------------------------------------------
      (let ((before (text-editor-get-cursor ed))
            (after (forward-line 1)))
        0))

(define (%backward-line ed)
      ;; The backward mirror, the same way.
      ;;--------------------------------------------------------------
      (let ((start (text-editor-get-start-of-line ed)))
        (if (> start 0)
            (begin
              (text-editor-set-cursor ed (- start 1))
              (text-editor-set-cursor
               ed (text-editor-get-start-of-line ed))
              0)
            1)))

    (define (forward-paragraph . args)
      ;; GNU Emacs's `forward-paragraph' (paragraphs.el:224): "Move
      ;; forward to end of paragraph." The walk is the C's positive
      ;; branch with the default patterns: over the separator lines,
      ;; one line into the paragraph, then line by line to the first
      ;; paragraph-start line, whose start is where point lands - or
      ;; the end of the buffer. A negative argument moves backward,
      ;; which is `backward-paragraph''s walk. The answer is the count
      ;; of paragraphs left undone, as the C returns.
      ;;--------------------------------------------------------------
      (let* ((n (if (pair? args) (car args) 1))
             (ed (current-buffer)))
        (if (< n 0)
            (backward-paragraph (- n))
            (let loop ((left n))
              (if (and (> left 0)
                       (< (text-editor-get-cursor ed)
                          (text-editor-char-count ed)))
                  (begin
                    ;; over the separator lines
                    (let skip ()
                      (when (and (%paragraph-start-line? ed)
                                 (= 0 (%forward-line ed)))
                        (skip)))
                    ;; one line into the paragraph
                    (%forward-line ed)
                    ;; to the paragraph's end: the first
                    ;; paragraph-start line, or the end
                    (let find ()
                      (cond
                       ((>= (text-editor-get-cursor ed)
                            (text-editor-char-count ed)) #f)
                       ((%paragraph-start-line? ed) #f)
                       (else (%forward-line ed) (find))))
                    (loop (- left 1)))
                  left)))))

    (define (backward-paragraph . args)
      ;; GNU Emacs's `backward-paragraph' (paragraphs.el:366): "Move
      ;; backward to start of paragraph." The walk's mirror with the
      ;; default patterns: back over separator lines, then line by
      ;; line up while the line ABOVE is not blank - the paragraph's
      ;; first line is where that stops - or to the beginning of the
      ;; buffer.
      ;;--------------------------------------------------------------
      (let* ((n (if (pair? args) (car args) 1))
             (ed (current-buffer)))
        (if (< n 0)
            (forward-paragraph (- n))
            (let loop ((left n))
              (if (and (> left 0)
                       (> (text-editor-get-cursor ed) 0))
                  (begin
                    ;; back over separator lines, which includes the
                    ;; blank line this walk may start on
                    (let skip ()
                      (when (and (%paragraph-start-line? ed)
                                 (= 0 (%backward-line ed)))
                        (skip)))
                    ;; up while the line above this one is not blank
                    (let find ()
                      (if (<= (text-editor-get-start-of-line ed) 0)
                          #f
                          (let ((above (begin
                                         (text-editor-set-cursor
                                          ed (- (text-editor-get-start-of-line ed)
                                                1))
                                         (text-editor-set-cursor
                                          ed (text-editor-get-start-of-line ed))
                                         (text-editor-get-cursor ed))))
                            (text-editor-set-cursor ed above)
                            (unless (%blank-line? ed)
                              (find)))))
                    (loop (- left 1)))
                  left)))))

    (define-command (kill-paragraph arg)
      ;; GNU Emacs's `kill-paragraph' (paragraphs.el:412): "Kill
      ;; forward to end of paragraph. With ARG N, kill forward to Nth
      ;; end of paragraph; negative ARG -N means kill backward to Nth
      ;; start of paragraph."
      "Kill forward to end of paragraph."
      (interactive (list (uarg->integer 1 (current-prefix-arg))))
      (let* ((ed (current-buffer))
             (here (text-editor-get-cursor ed)))
        ;; Emacs's `(progn (forward-paragraph arg) (point))': the motion
        ;; moves point, and it is point AFTER it that the kill runs to -
        ;; the motion's own answer is the count left undone, which is
        ;; not the position.
        (if (< arg 0)
            (backward-paragraph (- arg))
            (forward-paragraph arg))
        (let ((there (text-editor-get-cursor ed)))
          (kill-region (+ 1 (min here there))
                       (+ 1 (max here there))))))

    (define-command (backward-kill-paragraph arg)
      ;; GNU Emacs's `backward-kill-paragraph' (paragraphs.el:420):
      ;; "Kill back to start of paragraph."
      "Kill back to start of paragraph."
      (interactive (list (uarg->integer 1 (current-prefix-arg))))
      (kill-paragraph (- arg)))

    (define-command (mark-paragraph arg allow-extend)
      ;; GNU Emacs's `mark-paragraph' (paragraphs.el:382): "Put point at
      ;; beginning of this paragraph, mark at end." With ARG, mark ARG
      ;; paragraphs; repeated, or with the mark active, extend by ARG
      ;; more. The two parameters are the C's `"p\np"' interactive
      ;; spec's - the count, and ALLOW-EXTEND, which interactively is
      ;; true. The extend branch works on the mark, which here is the
      ;; engine's zero-based index - the position `mark' answers - so
      ;; the conversion to `goto-char''s one-based positions happens
      ;; once.
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
      (if (and allow-extend
               (or (eq? (*last-command*) mark-paragraph)
                   (and (transient-mark-mode) (mark-active))))
          ;; extend: the mark is where the last one ended
          (let ((here (mark #t)))
            (goto-char (+ 1 here))
            (forward-paragraph arg)
            (set-mark (text-editor-get-cursor (current-buffer))))
          (begin
            (forward-paragraph arg)
            (push-mark #f #t #t)
            (backward-paragraph arg)))
      #f)

    ;; The keys GNU Emacs binds them to, beside the commands as the
    ;; other libraries state theirs.
    (define-key *default-keymap* (kbd "M-k") kill-paragraph)
    (define-key *default-keymap* (kbd "M-C-k")
      backward-kill-paragraph)
    (define-key *default-keymap* (kbd "M-h") mark-paragraph)

    ))
