(define-library (schemacs editor indent)
  ;; This library mirrors GNU Emacs's `lisp/indent.el': the commands that
  ;; indent text.
  ;;
  ;; The name is `indent' and not `indentc' because Emacs has *both*
  ;; `src/indent.c' and `lisp/indent.el', which would want the same file
  ;; name here; the elisp half keeps the plain one, as `dired.sld' keeps
  ;; it against `diredc.sld'. The C half - `current-column',
  ;; `indent-to`, `indent-tabs-mode` - is `(schemacs editor indentc)`.
  ;;
  ;; What is here is the one command `dired-insert-directory' needs:
  ;; `indent-rigidly'. Its helper `current-indentation' is `indent.c''s
  ;; and is in `indentc.sld' with the rest of the column arithmetic.
  ;;
  ;; Not ported: `indent-region', `indent-line-to', the tab-stop list and
  ;; `indent-for-tab-command', and the whole of the interactive
  ;; `indent-rigidly' map (`indent-rigidly-left' and its siblings), which
  ;; is a transient-map feature this display does not have yet.

  (import
    (scheme base)
    (only (schemacs editor buffer) current-buffer)
    (only (schemacs editor command) current-prefix-arg define-command)
    (only (schemacs editor editfns)
          bolp delete-region eolp forward-line goto-char point point-marker
          save-excursion)
    (only (schemacs editor engine) marker-position set-marker!)
    (only (schemacs editor indentc) current-indentation indent-to)
    (only (schemacs editor syntax) skip-chars-forward)
    )

  (export
   indent-rigidly
   )

  (begin

    (define-command (indent-rigidly start end arg)
      "Indent all lines starting in the region forward by ARG columns.
If called from a program, START and END specify the beginning and end
of the text to act on, in place of the region. Negative values of ARG
indent backward, so you can remove all indentation by specifying a
large negative ARG."
      (interactive (list (point) (point) (current-prefix-arg)))
      (let ((end-marker #f))
        (save-excursion
          (goto-char end)
          (set! end-marker (point-marker))
          (goto-char start)
          ;; "Indent all lines *starting* in the region", so a region that
          ;; begins part-way down a line leaves that line alone.
          (if (not (bolp)) (forward-line 1))
          ;; `(marker-position end-marker)' and not the marker itself:
          ;; Emacs compares a position with a marker directly - its
          ;; arithmetic converts one - and this tree's does not.
          (let loop ()
            (when (< (point) (marker-position end-marker))
              (let ((indent (current-indentation))
                    (eol-flag #f))
                (save-excursion
                  (skip-chars-forward " \t")
                  (set! eol-flag (eolp)))
                (if (not eol-flag)
                    (indent-to (max 0 (+ indent arg)) 0))
                ;; `delete-region' answers the engine's *zero-based*
                ;; indices, not this layer's one-based ones - the one
                ;; exception `editfns.sld' records - so the conversion is
                ;; here, as it is inside `delete-and-extract-region'.
                (delete-region (- (point) 1)
                               (- (save-excursion
                                    (skip-chars-forward " \t")
                                    (point))
                                  1)))
              (forward-line 1)
              (loop)))
          (set-marker! end-marker #f))))

    ))
