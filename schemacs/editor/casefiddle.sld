(define-library (schemacs editor casefiddle)
  ;; This library mirrors GNU Emacs's `casefiddle.c': the case
  ;; conversions - `upcase-region' and `downcase-region' (C-x C-u and
  ;; C-x C-l), `upcase-word', `downcase-word' and `capitalize-word'
  ;; (M-u, M-l and M-c) - over the shared `casify_region' and
  ;; `casify_word'.
  ;;
  ;; The C works per character with the syntax table deciding what a
  ;; word is, and the capitalization asks each character's case
  ;; category; here a word-constituent is `simple.sld''s `word-char?'
  ;; - alphanumerics and the underscore, which is what the default
  ;; syntax table's `\sw' comes to - and the case conversions are
  ;; `(scheme base)''s `char-upcase' and `char-downcase'. The
  ;; multibyte machinery (case tables, `case-char-table') is not
  ;; ported: ASCII and the identity of the Latin-1 letters are what
  ;; those conversions give here.
  ;;
  ;; Not ported: `upcase-initials-region' and `capitalize-region' -
  ;; nothing calls them yet - the insert forms of the string
  ;; conversions, and the tree-sitter bookkeeping. The string-and-char
  ;; forms (`upcase', `downcase', `capitalize', `upcase-initials',
  ;; casefiddle.c:368/383/400/418, over `casify_object') ARE ported:
  ;; `replace-match''s case transfer casifies the replacement with
  ;; them.
  ;;
  ;; See LAYOUT-PLAN.txt for the rule this library is a step of.

  (import
    ;; `kbd' - see `character.sld''s export note for why it is there
    (only (schemacs editor character) kbd)
    (scheme base)
    (scheme char)
    (only (schemacs editor engine)
          text-editor-char-count text-editor-copy-string
          text-editor-delete-from-cursor text-editor-get-cursor
          text-editor-insert text-editor-set-cursor
          text-editor-undo-boundary!)
    ;; `point' is one-based here and the engine's cursor zero-based,
    ;; which is the conversion `casify-region''s positions go through.
    (only (schemacs editor editfns) point save-excursion
          region-beginning region-end)
    (only (schemacs editor simple) word-char?)
    (only (schemacs editor command) current-prefix-arg define-command
          uarg->integer)
    (only (schemacs editor buffer) current-buffer)
    ;; `scan_words' is `syntax.c''s in the C; here the word motions of
    ;; simple.sld stand for it, under `save-excursion'.
    (only (schemacs editor simple) word-run-end word-run-start)
    (only (schemacs editor keymap) define-key *default-keymap*)
    (only (guile) format)
    )

  (export
   casify-region
   casify-word
   upcase-region
   downcase-region
   upcase-word
   downcase-word
   capitalize-word
   upcase
   downcase
   capitalize
   upcase-initials
   )

  (begin

    (define (casify-object flag obj)
      ;; GNU Emacs's `casify_object' (casefiddle.c:354): FLAG the
      ;; character or string OBJ - `upcase', `downcase', `capitalize'
      ;; or `upcase-initials' - and answer the cased copy, the argument
      ;; itself untouched. The C's `do_casify_multibyte_string' walks
      ;; the characters keeping an in-word state, and so does this;
      ;; the character after a word-constituent is `the rest of the
      ;; word', which is what capitalize downcases and
      ;; upcase-initials leaves alone, and what follows a non-constituent
      ;; is a word's start, which both upcase.
      ;;
      ;; `case_character_impl' decides per character by first updating
      ;; `inword' with the character itself and then casing it by the
      ;; state as it stood - so a word's *last* constituent is already
      ;; inword when the following non-constituent is cased, which is
      ;; why the separator after it is not capitalized.
      ;;--------------------------------------------------------------
      ;; The titlecase and specialcase char tables (`Unicode' one-to-many
      ;; casing) are not ported, as the file header says.
      (cond
       ((char? obj)
        (let* ((inword (word-char? obj))
               ;; `case_character_impl''s normalization: CASE_CAPITALIZE
               ;; becomes CASE_DOWN after a word-constituent and stays
               ;; CASE_CAPITALIZE - which upcases - otherwise;
               ;; CASE_CAPITALIZE_UP becomes CASE_CAPITALIZE (upcase)
               ;; unless we are within a word, where the character
               ;; stands unchanged.
               (flag (cond
                      ((eq? flag 'capitalize)
                       (if inword 'downcase 'upcase))
                      ((eq? flag 'capitalize-up)
                       (if inword 'none 'upcase))
                      (else flag))))
          (cond
           ((eq? flag 'upcase) (char-upcase obj))
           ((eq? flag 'downcase) (char-downcase obj))
           ((eq? flag 'none) obj)
           (else (char-upcase obj)))))
       ((string? obj)
        (let loop ((i 0) (inword #f) (acc '()))
          (if (>= i (string-length obj))
              (list->string (reverse acc))
              (let* ((c (string-ref obj i))
                     (word? (word-char? c))
                     (flag (cond
                            ((eq? flag 'capitalize)
                             (if inword 'downcase 'upcase))
                            ((eq? flag 'capitalize-up)
                             (if inword 'none 'upcase))
                            (else flag)))
                     (cased
                      (cond
                       ((eq? flag 'upcase) (char-upcase c))
                       ((eq? flag 'downcase) (char-downcase c))
                       ((eq? flag 'none) c)
                       (else (char-upcase c)))))
                (loop (+ i 1) word? (cons cased acc))))))
       (else (error "Wrong type argument" obj))))

    (define (upcase obj)
      ;; GNU Emacs's `upcase' (casefiddle.c:368): "Convert argument to
      ;; upper case and return that. The argument may be a character
      ;; or string. The result has the same type."
      ;;--------------------------------------------------------------
      (casify-object 'upcase obj))

    (define (downcase obj)
      ;; GNU Emacs's `downcase' (casefiddle.c:383): the lower-case
      ;; mirror of `upcase'.
      ;;--------------------------------------------------------------
      (casify-object 'downcase obj))

    (define (capitalize obj)
      ;; GNU Emacs's `capitalize' (casefiddle.c:400): "each word's
      ;; first character is converted to either title case or upper
      ;; case, and the rest to lower case."
      ;;--------------------------------------------------------------
      (casify-object 'capitalize obj))

    (define (upcase-initials obj)
      ;; GNU Emacs's `upcase-initials' (casefiddle.c:418): "Like
      ;; Fcapitalize but change only the initials" - the rest of each
      ;; word is left as it stands.
      ;;--------------------------------------------------------------
      (casify-object 'capitalize-up obj))

    (define (scan-words count)
      ;; `scan_words' (syntax.c): the position COUNT words from point,
      ;; forward for positive COUNT and backward for negative; #f when
      ;; the words run out, which is the 0 the C answers and the
      ;; caller turns into BEGV or ZV.
      ;;--------------------------------------------------------------
      (save-excursion
        (let ((ed (current-buffer)))
          (if (> count 0)
              (word-run-end ed count)
              (word-run-start ed (- count))))))

    (define (casify-region flag beg end)
      ;; GNU Emacs's `casify_region' (casefiddle.c): FLAG the region
      ;; BEG..END - `upcase', `downcase' or `capitalize' - and answer
      ;; the end. Capitalize makes each word's first character upper
      ;; and the rest lower, a word's start being a word-constituent
      ;; that follows one that is not; the C's `do_casify_*_region'
      ;; walk the characters in one pass, and so does this. The
      ;; positions are one-based, the engine's are zero-based, and the
      ;; conversion is at the edges only.
      ;;--------------------------------------------------------------
      ;; The edit is delete-then-insert, with one undo boundary, which
      ;; is what `modify_text' makes of it for a case change: the text
      ;; is the same length, so the markers either side are unchanged
      ;; and the answer is END.
      ;;--------------------------------------------------------------
      (let ((ed (current-buffer))
            (beg (- beg 1))
            (end (- end 1)))
        (if (= beg end)
            (+ end 1)
            (let ((text (text-editor-copy-string ed beg end)))
              (text-editor-undo-boundary! ed)
              (let ((newtext
                     (let loop ((rest (string->list text))
                                (prev-word? #f)
                                (acc '()))
                       (cond
                        ((null? rest)
                         (list->string (reverse acc)))
                        (else
                         (let* ((c (car rest))
                                (word? (word-char? c))
                                (new
                                 (cond
                                  ((eq? flag 'upcase) (char-upcase c))
                                  ((eq? flag 'downcase) (char-downcase c))
                                  ;; capitalize: a word-constituent
                                  ;; changes case only at a word's
                                  ;; start, the rest going lower
                                  ((not word?) c)
                                  ((not prev-word?) (char-upcase c))
                                  (else (char-downcase c)))))
                           (loop (cdr rest) word? (cons new acc))))))))
                (text-editor-set-cursor ed beg)
                (text-editor-delete-from-cursor ed (- end beg))
                (text-editor-insert ed newtext)
                (text-editor-set-cursor ed beg)
                (+ end 1))))))

    (define (casify-word flag arg)
      ;; GNU Emacs's `casify_word' (casefiddle.c): FLAG the words from
      ;; point to the position ARG words away, and leave point there -
      ;; or, ARG negative, the words before point, leaving point where
      ;; it was ("With negative argument, convert previous words but
      ;; do not move"). The scan failing is BEGV or ZV by the sign.
      ;;--------------------------------------------------------------
      (let* ((ed (current-buffer))
             (pt (text-editor-get-cursor ed))
             (farend (or (scan-words arg)
                         (if (<= arg 0)
                             0
                             (text-editor-char-count ed)))))
        (text-editor-set-cursor
         ed (casify-region flag
                           (+ 1 (min pt farend))
                           (+ 1 (max pt farend))))
        #f))

    (define-command (upcase-region beg end)
      ;; GNU Emacs's `upcase-region' (casefiddle.c:609): "Convert the
      ;; region to upper case."
      "Convert the region to upper case."
      (interactive (list (region-beginning) (region-end)))
      (casify-region 'upcase beg end))

    (define-command (downcase-region beg end)
      ;; GNU Emacs's `downcase-region' (casefiddle.c:621).
      "Convert the region to lower case."
      (interactive (list (region-beginning) (region-end)))
      (casify-region 'downcase beg end))

    (define-command (upcase-word arg)
      ;; GNU Emacs's `upcase-word' (casefiddle.c:671): "Convert to
      ;; upper case from point to end of word, moving over."
      "Convert to upper case from point to end of word, moving over."
      (interactive (list (uarg->integer 1 (current-prefix-arg))))
      (casify-word 'upcase arg))

    (define-command (downcase-word arg)
      ;; GNU Emacs's `downcase-word' (casefiddle.c:684).
      "Convert to lower case from point to end of word, moving over."
      (interactive (list (uarg->integer 1 (current-prefix-arg))))
      (casify-word 'downcase arg))

    (define-command (capitalize-word arg)
      ;; GNU Emacs's `capitalize-word' (casefiddle.c:696): "Capitalize
      ;; from point to the end of word, moving over."
      "Capitalize from point to the end of word, moving over."
      (interactive (list (uarg->integer 1 (current-prefix-arg))))
      (casify-word 'capitalize arg))

    ;; The keys GNU Emacs binds them to, beside the commands as the
    ;; other libraries state theirs.
    (define-key *default-keymap* (kbd "C-x C-u")
      upcase-region)
    (define-key *default-keymap* (kbd "C-x C-l")
      downcase-region)
    (define-key *default-keymap* (kbd "M-u") upcase-word)
    (define-key *default-keymap* (kbd "M-l") downcase-word)
    (define-key *default-keymap* (kbd "M-c") capitalize-word)

    ))
