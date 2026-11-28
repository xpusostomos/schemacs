(define-library (schemacs pages)
  ;; This library mirrors GNU Emacs's `lisp/textmodes/page.el' (the
  ;; library the C calls `pages.el'): the page-oriented movement - a
  ;; "page" being a stretch of text between form feeds, which is what
  ;; `page-delimiter' matches.
  ;;
  ;; `backward-page' is what Dired's log asks for, to find the start of
  ;; the group of errors it is about to describe (`dired-log');
  ;; `forward-page' is what `backward-page' is written in terms of, and
  ;; the pair is ported together. `narrow-to-page' (`C-x n p') is here
  ;; now that narrowing is. **Not carried**: `mark-page', `count-lines-page'
  ;; (its line-counting half is `page--count-lines-page', which is
  ;; portable now that `simple.el''s `count-lines' is - what is left is
  ;; `ngettext', the C library's plural selection, and this tree has no
  ;; message catalogs for it to select from), `C-x [ / C-x ]'
  ;; (`forward-page'/`backward-page' as commands - this tree has no
  ;; binding for them and Emacs gets them from bindings.el).

  (import
    (scheme base)
    (only (schemacs editfns)
          bobp bolp eobp eolp forward-line goto-char point point-max point-min
          save-excursion narrow-to-region widen)
    (only (schemacs command) define-command current-prefix-arg
          uarg->integer)
    (only (schemacs keymap) define-key *default-keymap*)
    (only (schemacs character) kbd)
    (only (schemacs search)
          looking-at match-beginning match-end re-search-backward
          re-search-forward set-match-data)
    ;; `forward-char' is `cmds.c''s `Fforward_char', which this tree keeps
    ;; in `simple.sld' beside the rest of the movement commands.
    (only (schemacs simple) forward-char)
    (only (schemacs cmds) beginning-of-line)
    ;; `page-delimiter` is `paragraphs.el:213`'s defcustom; page.el only
    ;; reads it. It lives in `paragraphs.scm` and is re-exported here, so
    ;; this library's readers do not move.
    (only (schemacs textmodes paragraphs) *page-delimiter*
          page-delimiter set!page-delimiter)
    (only (schemacs intervals) put))

  (export *page-delimiter* page-delimiter set!page-delimiter
          backward-page forward-page narrow-to-page)

  (begin

    (define (forward-page . rest)
      ;; GNU Emacs's `forward-page' (page.el:31): "Move forward to page
      ;; boundary. With arg, repeat, or go back if negative. A page
      ;; boundary is any line whose beginning matches the regexp
      ;; `page-delimiter'."
      ;;--------------------------------------------------------------
      (let ((count (or (and (pair? rest) (car rest)) 1)))
        ;; "while (and (> count 0) (not (eobp)))"
        (let loop ((count count))
          (when (and (> count 0) (not (eobp)))
            (if (and (looking-at (page-delimiter))
                     (> (match-end 0) (point)))
                ;; "If we're standing at the page delimiter, then just
                ;; skip to the end of it. (But only if it's not a
                ;; zero-length delimiter, because then we wouldn't have
                ;; forward progress.)"
                (goto-char (match-end 0))
                ;; "In case the page-delimiter matches the null string,
                ;; don't find a match without moving."
                (begin
                  (when (bolp) (forward-char 1))
                  (unless (re-search-forward (page-delimiter) #f #t)
                    (goto-char (point-max)))))
            (loop (- count 1))))
        ;; "while (and (< count 0) (not (bobp)))"
        (let loop ((count count))
          (when (and (< count 0) (not (bobp)))
            ;; The `(and (save-excursion (re-search-backward ...))
            ;; (= (match-end 0) (point)) (goto-char (match-beginning 0)))'
            ;; of the C: `save-excursion' keeps point but *not* the match
            ;; data, which is what the `match-end' here reads.
            (let ((found (save-excursion
                           (re-search-backward (page-delimiter) #f #t))))
              (when (and found (= (match-end 0) (point)))
                (goto-char (match-beginning 0))))
            (unless (bobp)
              (forward-char -1)
              (if (re-search-backward (page-delimiter) #f #t)
                  ;; "We found one--move to the end of it."
                  (goto-char (match-end 0))
                  ;; "We found nothing--go to beg of buffer."
                  (goto-char (point-min))))
            (loop (+ count 1))))))

    (define (backward-page . rest)
      ;; GNU Emacs's `backward-page' (page.el:66): "Move backward to page
      ;; boundary. With arg, repeat, or go fwd if negative."
      ;;--------------------------------------------------------------
      (forward-page (- (or (and (pair? rest) (car rest)) 1))))

    
    (define-command (narrow-to-page . rest)
      ;; GNU Emacs's `narrow-to-page' (`page.el:88'): "Make text outside
      ;; current page invisible. A numeric arg specifies to move forward
      ;; or backward by that many pages, thus showing a page other than
      ;; the one point was originally in."
      ;;
      ;; `(put 'narrow-to-page 'disabled t)' (`page.el:127') is set
      ;; below, as `bindings.el:1111' sets `narrow-to-region`'s: the
      ;; prompt is `novice.scm`'s, and with that library not loaded the
      ;; command runs as Emacs's does with `disabled-command-function`
      ;; nil.
      ;;--------------------------------------------------------------
      "Make text outside current page invisible.
A numeric arg specifies to move forward or backward by that many pages,
thus showing a page other than the one point was originally in."
      (interactive (list (current-prefix-arg)))
      (let ((arg (let ((a (and (pair? rest) (car rest))))
                   (if a (uarg->integer 1 a) 0))))
        (save-excursion
          (widen)
          (if (> arg 0)
              (forward-page arg)
              (if (< arg 0)
                  (let ((adjust 0)
                        (opoint (point)))
                    ;; "If we are not now at the beginning of a page, move
                    ;; back one extra time, to get to the start of this
                    ;; page."
                    (save-excursion
                      (beginning-of-line)
                      (unless (and (looking-at (page-delimiter))
                                   (eqv? (match-end 0) opoint))
                        (set! adjust 1)))
                    (forward-page (- arg adjust)))))
          ;; "Find the end of the page."
          (set-match-data #f)
          (forward-page)
          ;; "If we stopped due to end of buffer, stay there. If we stopped
          ;; after a page delimiter, put end of restriction at the
          ;; beginning of that line. Before checking the match that was
          ;; found, verify that `forward-page' actually set the match
          ;; data."
          (if (and (match-beginning 0)
                   (save-excursion
                     (goto-char (match-beginning 0))
                     (looking-at (page-delimiter))))
              (goto-char (match-beginning 0)))
          ;; **`(point)` is read before the `begin`, as Emacs's argument
          ;; order does**: this is `(narrow-to-region (point) (progn ...))'
          ;; and the `progn` moves point. A `let` evaluates its bindings
          ;; first, which would narrow to the top of the page on both
          ;; sides - [6,6) instead of [6,8) on the page fixture.
          (let ((start (point)))
            (let ((end (begin
                       ;; "Find the top of the page."
                       (forward-page -1)
                       ;; "If we found beginning of buffer, stay there. If
                       ;; extra text follows page delimiter on same line,
                       ;; include it. Otherwise, show text starting with
                       ;; following line."
                       (if (and (eolp) (not (bobp)))
                           (forward-line 1))
                       (point))))
              (narrow-to-region start end))))))

    ;; `narrow-map`'s `p` (`bindings.el:1729'), flat - see the note on
    ;; `narrow-map` in `editfns.scm`.

    ;; `(put 'narrow-to-page 'disabled t)' (`page.el:127').
    (put 'narrow-to-page 'disabled #t)
    (define-key *default-keymap* (kbd "C-x n p") narrow-to-page)
))