(define-library (schemacs editor pages)
  ;; This library mirrors GNU Emacs's `lisp/textmodes/page.el' (the
  ;; library the C calls `pages.el'): the page-oriented movement - a
  ;; "page" being a stretch of text between form feeds, which is what
  ;; `page-delimiter' matches.
  ;;
  ;; `backward-page' is what Dired's log asks for, to find the start of
  ;; the group of errors it is about to describe (`dired-log');
  ;; `forward-page' is what `backward-page' is written in terms of, and
  ;; the pair is ported together. `mark-page', `narrow-to-page',
  ;; `count-lines-page' and the rest of `page.el' come with narrowing and
  ;; with C-x [ / C-x ], which this tree does not have yet.

  (import
    (scheme base)
    (only (schemacs editor editfns)
          bobp bolp eobp goto-char point point-max point-min save-excursion)
    (only (schemacs editor search)
          looking-at match-beginning match-end re-search-backward
          re-search-forward)
    ;; `forward-char' is `cmds.c''s `Fforward_char', which this tree keeps
    ;; in `simple.sld' beside the rest of the movement commands.
    (only (schemacs editor simple) forward-char))

  (export *page-delimiter* backward-page forward-page)

  (begin

    (define *page-delimiter* (make-parameter "^\014"))
    ;; ^ GNU Emacs's `page-delimiter' (page.el:25): "Regexp describing
    ;; line that separates pages. The ^L is a form feed." Emacs spells it
    ;; `"^\f"'; one form feed character is `\014' in octal, so it is the
    ;; same string written out.

    (define (forward-page count)
      ;; GNU Emacs's `forward-page' (page.el:31): "Move forward to page
      ;; boundary. With arg, repeat, or go back if negative. A page
      ;; boundary is any line whose beginning matches the regexp
      ;; `page-delimiter'."
      ;;--------------------------------------------------------------
      (let ((count (or count 1)))
        ;; "while (and (> count 0) (not (eobp)))"
        (let loop ((count count))
          (when (and (> count 0) (not (eobp)))
            (if (and (looking-at (*page-delimiter*))
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
                  (unless (re-search-forward (*page-delimiter*) #f #t)
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
                           (re-search-backward (*page-delimiter*) #f #t))))
              (when (and found (= (match-end 0) (point)))
                (goto-char (match-beginning 0))))
            (unless (bobp)
              (forward-char -1)
              (if (re-search-backward (*page-delimiter*) #f #t)
                  ;; "We found one--move to the end of it."
                  (goto-char (match-end 0))
                  ;; "We found nothing--go to beg of buffer."
                  (goto-char (point-min))))
            (loop (+ count 1))))))

    (define (backward-page count)
      ;; GNU Emacs's `backward-page' (page.el:66): "Move backward to page
      ;; boundary. With arg, repeat, or go fwd if negative."
      ;;--------------------------------------------------------------
      (forward-page (- (or count 1))))

    ))
