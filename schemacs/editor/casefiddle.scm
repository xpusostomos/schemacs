(define-library (schemacs editor casefiddle)
  ;; This library mirrors GNU Emacs's `casefiddle.c': the case
  ;; conversions - `upcase-region' and `downcase-region' (C-x C-u and
  ;; C-x C-l), `upcase-word', `downcase-word' and `capitalize-word'
  ;; (M-u, M-l and M-c) - over the shared `casify_region' and
  ;; `casify_word'.
  ;;
  ;; The C works per character with the syntax table deciding what a
  ;; word is, and the capitalization asks each character's case
  ;; category; here a word-constituent is `syntax.sld`'s `word-char?'
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
          make-buffer-string
          buffer-beg buffer-z buffer-pt
          text-editor-set-cursor
          ;; `record_insert` and `record_delete` are undo.c's, and
          ;; `casify_region` calls them **directly** - `casefiddle.c`
          ;; records the whole region once around its per-character loop.
          ;; They are `undo.scm`'s now and re-exported by the engine.
          record-insert record-delete signal-after-change)
    ;; `replace_range_2` and `modify_text` are `insdel.c`'s, and
    ;; `casify_region` is the only caller of the first in all of Emacs.
    (only (schemacs editor insdel) modify-text replace-range-2)
    ;; The raw character store: the C's `FETCH_BYTE (pos) = ...` and
    ;; `memcpy (BYTE_POS_ADDR (pos_byte), ...)`, which `casefiddle.c` uses
    ;; the way any file above `insdel.c` may - they are `buffer.h`'s
    ;; macros and `buffer-text.scm` is `buffer.h`'s struct.
    (only (schemacs editor buffer-text) buffer-text-ref buffer-text-set!)
    ;; `point' is one-based here and the engine's cursor zero-based,
    ;; which is the conversion `casify-region''s positions go through.
    (only (schemacs editor editfns) save-excursion
          region-beginning region-end)
    ;; `WORD_CONSTITUENT', from its Emacs home: it was in `simple.sld`,
    ;; which put `casefiddle.c` above `simple.el` and closed a cycle
    ;; through `search.sld` and the coding layer. See `syntax.sld`.
    (only (schemacs editor syntax) word-char?)
    (only (schemacs editor command) current-prefix-arg define-command
          uarg->integer)
    (only (schemacs editor buffer) current-buffer validate-region
          text-editor-text set!buffer-pt)
    ;; `scan_words` is `syntax.c`'s - the word motions were reached
    ;; through `simple.sld`, which put `casefiddle.c` above `simple.el`
    ;; and closed a cycle through `search.sld` and the coding layer.
    ;; They are in their Emacs home now; see `syntax.sld`.
    (only (schemacs editor syntax) word-run-end word-run-start)
    (only (schemacs editor keymap) define-key *default-keymap*)
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

    ;;----------------------------------------------------------------
    ;; Casing one character - the C's three steps
    ;;------------------------------------------------------------------
    ;;
    ;; `case_character_impl` is the whole of the decision, and the other
    ;; two are entry points into it: `case_single_character` for a caller
    ;; that wants a character, `case_character` for the two walks that
    ;; case a run. Both walks below call the third, as `casefiddle.c`'s
    ;; do.

    (define (case-character-impl flag ch was-inword)
      ;; GNU Emacs's `case_character_impl` (`casefiddle.c:113`): case CH
      ;; under FLAG, given WAS-INWORD. Three answers - the cased text as a
      ;; *string*, which is the C's `struct casing_str_buf` and is one
      ;; character long for a one-to-one conversion and several for a
      ;; special casing; the `inword` state this character leaves behind,
      ;; which the next character's call needs; and the single cased
      ;; character, which is what the C answers when it was asked for a
      ;; change to one character.
      ;;
      ;; **`syntax_prefix_flag_p` is not carried**: it is a property of
      ;; the `'` syntax class, which this tree's `word-char?` does not
      ;; model, so the C's "a word constituent that is not a word prefix"
      ;; comes out as plain `word-char?`.
      ;;
      ;; **The titlecase and specialcase char tables are not ported** -
      ;; the Unicode one-to-many casings, see the file header - so every
      ;; conversion here is one-to-one and the text is never longer than
      ;; one character. The multi-character branch is the C's all the
      ;; same, and it is what `do-casify-multibyte-region`'s
      ;; `replace_range_2` call exists for.
      ;;--------------------------------------------------------------
      (let* ((inword (word-char? ch))
             ;; "Normalize flag so it's one of CASE_UP, CASE_DOWN or
             ;; CASE_CAPITALIZE."
             (action (cond ((eq? flag 'capitalize)
                            (if was-inword 'downcase 'upcase))
                           ((eq? flag 'capitalize-up)
                            (if was-inword 'none 'upcase))
                           (else flag)))
             (cased (cond ((eq? action 'upcase) (char-upcase ch))
                          ((eq? action 'downcase) (char-downcase ch))
                          ((eq? action 'none) ch)
                          (else (char-upcase ch)))))
        (values (string cased) inword cased)))

    (define (case-single-character flag ch was-inword)
      ;; GNU Emacs's `case_single_character` (`casefiddle.c:213`):
      ;; `case_character_impl` for a caller that wants the character and
      ;; not a buffer - "Special casing rules (such as upcase(ﬁ) = FI) are
      ;; not handled. For characters whose casing results in multiple code
      ;; points, the character is returned unchanged." The new `inword`
      ;; comes back too, since a Scheme call cannot leave it in the
      ;; caller's context the way the C's struct does.
      ;;--------------------------------------------------------------
      (let-values (((text inword cased) (case-character-impl flag ch was-inword)))
        (values cased inword)))

    (define (case-character flag ch was-inword next)
      ;; GNU Emacs's `case_character` (`casefiddle.c:226`): what the two
      ;; walks use. It is `case_character_impl` and the Greek final sigma
      ;; rule - "If we have just down-cased a capital sigma and the next
      ;; character no longer has a word syntax (i.e. current character is
      ;; end of word), use final sigma." NEXT is the character after CH,
      ;; or #f when CH is the last, which is the C's null pointer.
      ;;
      ;; Whether the character changed is `case_character_impl`'s own
      ;; answer - the sigma rule re-spells what came out, it does not
      ;; change that it changed.
      ;;--------------------------------------------------------------
      (let-values (((text inword cased) (case-character-impl flag ch was-inword)))
        (let ((text (if (and was-inword
                             (char=? ch #\x3a3)   ; GREEK CAPITAL LETTER SIGMA
                             (not (char=? cased ch))
                             (or (not next) (not (word-char? next))))
                        (string #\x3c2)       ; GREEK SMALL LETTER FINAL SIGMA
                        text)))
          (values text inword (not (char=? cased ch))))))

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
      (cond
       ((char? obj)
        ;; The C's `do_casify_natnum` (`casefiddle.c:220`), over
        ;; `case_single_character`. The context is fresh, so `inword` is
        ;; false going in - the C's `prepare_casing_context` sets it so -
        ;; and a lone character is therefore never "within a word".
        ;;
        ;; **Not carried**: the C's modifier-bit juggling, the `CHAR_ALT`
        ;; and friends it packs into a character's integer and strips
        ;; before casing. A Scheme character has nowhere to put them.
        (let-values (((cased inword) (case-single-character flag obj #f)))
          cased))
       ((string? obj)
        ;; The C's `do_casify_multibyte_string` (`casefiddle.c:281`): walk
        ;; the characters with `case_character`, keeping the `inword`
        ;; state, and build the answer - which may be *longer* than the
        ;; argument, since a special casing can expand one character into
        ;; several.
        ;;
        ;; **The unibyte walk is not ported** (`do_casify_unibyte_string`
        ;; and the `ascii_casify_character` it falls back to): every string
        ;; here is multibyte, `enable-multibyte-characters` being always
        ;; true. See `mule.scm`.
        (let ((n (string-length obj)))
          (let loop ((i 0) (inword #f) (acc '()))
            (if (>= i n)
                (apply string-append (reverse acc))
                (let-values (((text new-inword changed?)
                              (case-character flag (string-ref obj i) inword
                                              (and (< (+ i 1) n)
                                                   (string-ref obj (+ i 1))))))
                  (loop (+ i 1) new-inword (cons text acc)))))))
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

    (define (do-casify-multibyte-region flag start end)
      ;; GNU Emacs's `do_casify_multibyte_region` (`casefiddle.c:432`):
      ;; "Based on CTX, case region in a multibyte buffer from *STARTP to
      ;; *ENDP. Return number of added characters (may be negative if more
      ;; characters were deleted then inserted), save first and last
      ;; positions that has changed in *STARTP and *ENDP respectively. If
      ;; no characters were changed, return 0, save -1 to *STARTP and
      ;; leave *ENDP unspecified."
      ;;
      ;; The C writes the two positions back through its `*startp` and
      ;; `*endp`; here they come back with ADDED, which is the answer the C
      ;; returns.
      ;;
      ;; **A one-character-in, one-character-out conversion is written in
      ;; place** - the C's `memcpy`, "keeping text properties the same" -
      ;; and never goes through `replace_range_2`. That is the only path
      ;; this tree's casing can reach today, its conversions all being
      ;; one-to-one; the count-changing path (ß → SS) is the C's and is
      ;; what `replace_range_2` is here for.
      ;;
      ;; **Point is saved and put back**, because `replace_range_2`
      ;; relocates point as a marker and the C does not want that here: it
      ;; tracks the position itself, moved by the characters added before
      ;; it, and restores that at the end.
      ;;--------------------------------------------------------------
      (let* ((buffer (current-buffer))
             (text (text-editor-text buffer))
             (opoint (buffer-pt buffer)))
        (let loop ((pos start)
                   (size (- end start))
                   (inword #f)
                   (first -1)
                   (last -1)
                   (added 0))
          (if (<= size 0)
              (begin
                (unless (= (buffer-pt buffer) opoint)
                  (set!buffer-pt buffer opoint))
                (values added first last))
              (let* ((cp (buffer-text-ref text pos))
                     (ch (and (<= cp #x10ffff) (integer->char cp))))
                (if (not ch)
                    ;; A byte character - one this tree holds as a code
                    ;; point above `#x10ffff`, which no Scheme character
                    ;; can be (see `character.scm`). The C's case tables
                    ;; have no entry for one, so it is neither a word
                    ;; constituent nor changed, and the scan steps over it
                    ;; exactly as it does over an unchanged character.
                    (loop (+ pos 1) (- size 1) inword first last added)
                    (let ((next (and (> size 1)
                                     (let ((ncp (buffer-text-ref text (+ pos 1))))
                                       (and (<= ncp #x10ffff)
                                            (integer->char ncp))))))
                      (let-values (((text-out new-inword changed?)
                                    (case-character flag ch inword next)))
                        (if (not changed?)
                            (loop (+ pos 1) (- size 1) new-inword
                                  first last added)
                            (let* ((newlen (string-length text-out))
                                   (new-first (if (< first 0) pos first))
                                   (new-last (+ pos newlen)))
                              (if (= newlen 1)
                                  (buffer-text-set!
                                   text pos
                                   (char->integer (string-ref text-out 0)))
                                  (begin
                                    (replace-range-2 pos (+ pos 1) text-out
                                                     newlen #f)
                                    (when (> opoint pos)
                                      (set! opoint (+ opoint (- newlen 1))))))
                              (loop (+ pos newlen) (- size 1) new-inword
                                    new-first new-last
                                    (+ added (- newlen 1)))))))))))))

    (define (casify-region flag beg end)
      ;; GNU Emacs's `casify_region` (`casefiddle.c:534`): FLAG the region
      ;; BEG..END - `upcase', `downcase' or `capitalize' - and answer the
      ;; end *after* the change, which is BEG's for a same-length change
      ;; and moves only when a special casing made the text longer.
      ;;
      ;; **The hooks are around the whole region, once** - `modify_text`
      ;; before it and `signal_after_change` after it - and
      ;; `do_casify_multibyte_region` writes the characters in between
      ;; without any of them. That is the division the C's comment on
      ;; `replace_range_2` states, and it is why the undo record is one
      ;; deletion of the whole region followed by one insertion of it:
      ;; `record_delete` and `record_insert` bracket the loop here, where
      ;; the loop itself is the loop's business.
      ;;
      ;; **Not carried**: `casify_pnc_region` and the noncontiguous region
      ;; it walks, `region-extract-function` not being ported - so the
      ;; commands take two arguments where Emacs's take three - and the
      ;; tree-sitter bookkeeping, `update_compositions` (syntax.c) and the
      ;; `SETUP_BUFFER_SYNTAX_TABLE` of `prepare_casing_context`, whose
      ;; only reader is `syntax_prefix_flag_p`.
      ;;--------------------------------------------------------------
      (let-values (((beg end) (validate-region beg end)))
        (if (= beg end)
            ;; "Not modifying because nothing marked."
            end
            (begin
              (modify-text beg end)
              (let ((orig-end end)
                    (buffer (current-buffer)))
                ;; The whole region goes, before the loop - so undo puts it
                ;; back in one step whatever the loop then does to it.
                (record-delete beg (make-buffer-string buffer beg end))
                (let-values (((added first last)
                              (do-casify-multibyte-region flag beg end)))
                  ;; "Record the insertion", the whole region again, and
                  ;; with the characters a special casing added.
                  (record-insert beg (+ (- end beg) added))
                  (when (>= first 0)
                    ;; The first and last positions that *changed*, not the
                    ;; region: `added` converts the changed span's new
                    ;; length into what it was before.
                    (signal-after-change first
                                         (- (- last first) added)
                                         (- last first)))
                  (+ orig-end added)))))))

    (define (casify-word flag arg)
      ;; GNU Emacs's `casify_word' (casefiddle.c): FLAG the words from
      ;; point to the position ARG words away, and leave point there -
      ;; or, ARG negative, the words before point, leaving point where
      ;; it was ("With negative argument, convert previous words but
      ;; do not move"). The scan failing is BEGV or ZV by the sign.
      ;;--------------------------------------------------------------
      (let* ((ed (current-buffer))
             (pt (buffer-pt ed))
             (farend (or (scan-words arg)
                         (if (<= arg 0)
                             (buffer-beg ed)
                             (buffer-z ed)))))
        (text-editor-set-cursor
         ed (casify-region flag (min pt farend) (max pt farend)))
        #f))

    (define-command (upcase-region beg end)
      ;; GNU Emacs's `upcase-region' (`casefiddle.c:603'): "Convert the
      ;; region to upper case. In programs, wants two arguments..."
      ;;
      ;; **It answers nil, not the region's end.** `casify_region` answers
      ;; where the change ended, and that is what `casify_word` sets point
      ;; from - but the DEFUN goes through `casify_pnc_region`, which
      ;; throws that answer away and returns `Qnil`. Measured:
      ;; `(upcase-region 1 4)` answers nil in Emacs 31.1.
      ;;--------------------------------------------------------------
      "Convert the region to upper case.
In programs, wants two arguments.  These arguments
specify the starting and ending character numbers of the region to
operate on.  When used as a command, the text between point and the
mark is operated on.
See also `capitalize-region'."
      (interactive (list (region-beginning) (region-end)))
      (casify-region 'upcase beg end)
      #f)

    (define-command (downcase-region beg end)
      ;; GNU Emacs's `downcase-region' (`casefiddle.c:621'): the same,
      ;; downcasing, and nil the same way.
      "Convert the region to lower case.
In programs, wants two arguments.  These arguments
specify the starting and ending character numbers of the region to
operate on.  When used as a command, the text between point and the
mark is operated on."
      (interactive (list (region-beginning) (region-end)))
      (casify-region 'downcase beg end)
      #f)

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
