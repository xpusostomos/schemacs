(define-library (schemacs editor mule)
  ;; This library mirrors GNU Emacs's `lisp/international/mule.el', which
  ;; is where `char-displayable-p' is defined (mule.el:483).
  ;;
  ;; Emacs decides displayability through its charset and coding-system
  ;; machinery, and two of the layers it asks do not exist in this editor.
  ;; They are named here rather than faked:
  ;;
  ;;   * `internal-char-font' asks the selected frame's fontset - or, on a
  ;;     text terminal, the character's glyph code. There are no fontsets
  ;;     in this tree and no glyph codes, so that call has no answer here.
  ;;     It has none in Emacs on such a terminal either: the C returns nil
  ;;     and the coding-system branch below is the one that decides, which
  ;;     is the branch this editor is always on.
  ;;
  ;;   * There is no charset or coding-system layer (`charset.c',
  ;;     `coding.c'), so "can this coding system encode CHAR" - Emacs's
  ;;     `encode-char' over the coding system's `:charset-list' - is asked
  ;;     of Guile instead of a ported `encode-char'. That is the
  ;;     substitution AGENTS.md allows for a facility Guile already has,
  ;;     the same way the line-break conventions lean on Guile's ports.
  ;;
  ;; What is left is the rule that matters on a terminal: ASCII always
  ;; displays, and past that the terminal's own encoding decides. On the
  ;; UTF-8 terminal this editor draws on, that is every character - which
  ;; is what Emacs answers for its own `utf-8-unix' terminal too, so the
  ;; `" -> "' spelling Emacs falls back to for a separator the terminal
  ;; cannot draw is unreachable in both.

  (import
    (scheme base)
    (scheme char)
    ;; `string->utf8', which the encoding test needs, is `(scheme base)''s
    ;; here - as `xterm.sld' notes of the same call for the clipboard.
    )

  (export
   *enable-multibyte-characters*
   char-displayable-p
   terminal-coding-system
   )

  (begin

    (define *enable-multibyte-characters*
      ;; GNU Emacs's `enable-multibyte-characters' (`character.c'): "Non-nil
      ;; means the current buffer accepts multibyte characters."
      ;;
      ;; A Scheme string is a sequence of characters and there is no other
      ;; kind for it to be, so there is no buffer where this is nil; it is
      ;; here because `char-displayable-p' asks it, and because Emacs's
      ;; answer to nil is about buffers rather than about the display:
      ;; "Maybe there's a font for it, but we can't put it in the buffer."
      ;;--------------------------------------------------------------
      (make-parameter #t))

    (define (terminal-coding-system)
      ;; GNU Emacs's `terminal-coding-system' (`coding.c'): "Return coding
      ;; system specified for terminal output".
      ;;
      ;; Emacs derives it from the locale in `set-locale-environment'; the
      ;; locale reading is not ported, and on this machine's `en_US.UTF-8'
      ;; terminal Emacs answers `utf-8-unix' - measured with `emacs -Q
      ;; --batch'. What this editor draws on is a UTF-8 terminal, which is
      ;; the same answer.
      ;;--------------------------------------------------------------
      'utf-8-unix)

    (define (terminal-encodes-char? char)
      ;; Whether this terminal's coding system can encode CHAR - Emacs's
      ;; `encode-char' over `coding-system-get''s `:charset-list', which
      ;; for `utf-8-unix' is the one-element list `(unicode)' and so true
      ;; for every character Unicode names.
      ;;
      ;; The one character UTF-8 has no bytes for is a surrogate, which is
      ;; not a scalar value and which `string->utf8' refuses - so the
      ;; encoding test is exactly that call. A coding system with no
      ;; encoder here answers nil, which is what Emacs's own cond answers
      ;; when nothing matches: it cannot say yes, so it does not.
      ;;--------------------------------------------------------------
      (case (terminal-coding-system)
        ((utf-8 utf-8-unix utf-8-dos utf-8-mac)
         (guard (e (#t #f))
           (string->utf8 (string char))
           #t))
        (else #f)))

    (define (char-displayable-p char)
      ;; GNU Emacs's `char-displayable-p' (`mule.el:483'): "Return non-nil
      ;; if we should be able to display CHAR."
      ;;
      ;; Emacs answers the *charset* it found rather than plain `t' - the
      ;; `unicode' that a UTF-8 terminal gives for an arrow, measured the
      ;; same way. Charsets are not ported, so the answer here is `t'; a
      ;; caller testing it for truth, which is what `query-replace-read-from'
      ;; does and what Emacs's own callers do, reads it the same.
      ;;--------------------------------------------------------------
      (cond ((< (char->integer char) 128)
             ;; "ASCII characters are always displayable."
             #t)
            ((not (*enable-multibyte-characters*))
             ;; "Maybe there's a font for it, but we can't put it in the
             ;; buffer."
             #f)
            (else (terminal-encodes-char? char))))

    ))
