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
    (only (guile) string-contains)
    (only (schemacs editor coding)
          coding-system-p find-coding-system coding-system-name)
    ;; `string->utf8', which the encoding test needs, is `(scheme base)''s
    ;; here - as `xterm.sld' notes of the same call for the clipboard.
    )

  (export
   *enable-multibyte-characters*
   char-displayable-p
   terminal-coding-system
   ;; Detection - `mule.el''s `find-auto-coding' and what it reads
   *auto-coding-alist* auto-coding-alist-lookup
   find-auto-coding set-auto-coding
   coding-system-from-file-name
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


    ;;------------------------------------------------------------------
    ;; Finding a file's coding system from what it says
    ;;------------------------------------------------------------------
    ;;
    ;; GNU Emacs's `find-auto-coding' (`mule.el:1880'): "Find a coding
    ;; system for a file FILENAME of which SIZE bytes follow point. These
    ;; bytes should include at least the first 1k of the file and the last
    ;; 3k of the file, but the middle may be omitted."
    ;;
    ;; What it does **reads declarations**, it does not guess: a file
    ;; name matched against `auto-coding-alist', a `coding:' tag in the
    ;; first line, or a coding entry in the local-variables block. The
    ;; statistical detector is a different function (`detect-coding-
    ;; region', `coding.c') and is consulted elsewhere; nothing here has
    ;; an opinion about bytes.
    ;;
    ;; **The band is why this is exact rather than approximate.** Emacs
    ;; searches the first *line* for the tag - `set-auto-mode-1' bounds
    ;; the search - and the last 3k for the local-variables block.
    ;; Measured, that is what separates Emacs from Guile's `file-encoding':
    ;; for `A file.\n; coding: latin-1\n' Emacs answers nil, because the
    ;; tag is not on the first line, and `file-encoding' answers
    ;; "LATIN-1", because its window is "the first few hundred bytes".
    ;; A file that merely *mentions* `coding:' in a comment is decoded by
    ;; one and not the other, and Emacs's rule is the one to copy.

    (define *auto-coding-alist* (make-parameter '()))
    ;; ^ GNU Emacs's `auto-coding-alist': "Alist of filename patterns vs
    ;; coding systems. The value of `auto-coding-function' should match
    ;; names against this." Its default entries are for compressed files;
    ;; a caller adds what it wants.

    (define (auto-coding-alist-lookup filename)
      ;; The coding system `*auto-coding-alist*' gives for FILENAME, or
      ;; #f. Emacs matches with `string-match', so a pattern is a regexp.
      ;;--------------------------------------------------------------
      (let loop ((alist (*auto-coding-alist*)))
        (cond ((not (pair? alist)) #f)
              ((and (pair? (car alist))
                    (guard (e (#t #f))
                      (string-match (caar alist) filename)))
               (cdar alist))
              (else (loop (cdr alist))))))

    (define (%line-end-at text start)
      ;; The position of the newline ending the line START is on, or the
      ;; text's length - `set-auto-mode-1''s boundary, which is what
      ;; bounds the tag search to one line.
      ;;--------------------------------------------------------------
      (let loop ((i start))
        (cond ((>= i (string-length text)) i)
              ((char=? (string-ref text i) #\newline) i)
              (else (loop (+ i 1))))))

    (define (%tag-in text start end)
      ;; The coding system named by a `coding:' tag between START and END,
      ;; or #f.
      ;;
      ;; The C's pattern is `\\(.*;\\)?[ \t]*coding:[ \t]*\\([^ ;]+\\)'
      ;; - `coding:' possibly preceded by something ending in a
      ;; semicolon, which is what makes the `;; -*- coding: latin-1 -*-'
      ;; form match - and the name is everything up to a space or a
      ;; semicolon.
      ;;--------------------------------------------------------------
      (let loop ((i start))
        (cond
         ((>= i end) #f)
         ((and (<= (+ i 7) end)
               (string=? "coding:" (substring text i (+ i 7))))
          (let name ((j (+ i 7)))
            (cond ((>= j end) #f)
                  ((memv (string-ref text j) '(#\space #\tab)) (name (+ j 1)))
                  (else
                   (let val ((k j))
                     (cond ((>= k end)
                            (substring text j k))
                           ((memv (string-ref text k) '(#\space #\tab #\;))
                            (substring text j k))
                           (else (val (+ k 1)))))))))
         (else (loop (+ i 1))))))

    (define *auto-coding-tail-size* 3072)
    ;; ^ `find-auto-coding''s `(- size 3072)': the local-variables block is
    ;; searched in the last 3K bytes of the file and *nowhere else*, so a
    ;; file that merely mentions the phrase near its top is not read as
    ;; one that declares a coding system.

    (define (%line-after-break text i)
      ;; The start of the line containing I - the index just past the
      ;; *nearest* preceding line break - or #f when there is none.
      ;;
      ;; The C's pattern begins `[\r\n]PREFIX' with `PREFIX' being
      ;; `[^\r\n]*', so a prefix starts right after a break and never
      ;; crosses one. Taking the *nearest* preceding break is what makes
      ;; that true for a CR-LF file, where the two characters are two
      ;; breaks and only the second one begins the line.
      ;;--------------------------------------------------------------
      (let loop ((j i))
        (cond ((<= j 0) #f)
              ((memv (string-ref text (- j 1)) '(#\newline #\return)) j)
              (else (loop (- j 1))))))

    (define (%line-break-at-or-after text i)
      ;; The index of the break ending the line containing I, or #f for a
      ;; line with no break after it - the C's trailing `[\r\n]', which
      ;; every one of these patterns requires.
      ;;--------------------------------------------------------------
      (let ((n (string-length text)))
        (let loop ((j i))
          (cond ((>= j n) #f)
                ((memv (string-ref text j) '(#\newline #\return)) j)
                (else (loop (+ j 1)))))))

    (define (%skip-while s i pred)
      ;; The first index at or after I at which PRED is false.
      ;;--------------------------------------------------------------
      (let loop ((j i))
        (if (and (< j (string-length s)) (pred (string-ref s j)))
            (loop (+ j 1))
            j)))

    (define (%block-strip line prefix suffix)
      ;; LINE with the block's PREFIX off its front and its SUFFIX off its
      ;; back, or #f when it does not carry them. The two are what the
      ;; C's `(regexp-quote (match-string 1))' and `... 2)' carry from the
      ;; block's own `Local Variables:' line onto every entry's line, so
      ;; a block with unusual delimiters keeps them.
      ;;--------------------------------------------------------------
      (let* ((n (string-length line))
             (p (string-length prefix))
             (s (string-length suffix)))
        (and (>= n (+ p s))
             (string=? prefix (substring line 0 p))
             (string=? suffix (substring line (- n s) n))
             (substring line p (- n s)))))

    (define (%block-line-value line prefix suffix key)
      ;; The value of a `KEY ... : VALUE' line whose whole text is the
      ;; block's `PREFIX' then that entry then its `SUFFIX' - the C's
      ;; `re-coding', which is exactly
      ;;
      ;;   "[\r\n]" prefix "[ \t]*coding[ \t]*:[ \t]*\([^ \t\r\n]+\)[ \t]*" suffix "[\r\n]"
      ;;
      ;; with the two `[\r\n]'s already consumed by the caller. LINE is
      ;; one line with no break in it, so `[^\r\n]' is free.
      ;;--------------------------------------------------------------
      (let* ((mid (%block-strip line prefix suffix))
             (k (string-length key)))
        (and mid
             (let* ((i (%skip-while mid 0 (lambda (c) (memv c '(#\space #\tab)))))
                    (j (and (<= (+ i k) (string-length mid))
                            (string=? key (substring mid i (+ i k)))
                            (%skip-while mid (+ i k)
                                         (lambda (c) (memv c '(#\space #\tab))))))
                    (v (and j (< j (string-length mid))
                            (char=? (string-ref mid j) #\:)
                            (%skip-while mid (+ j 1)
                                         (lambda (c) (memv c '(#\space #\tab)))))))
               (and v (< v (string-length mid))
                    ;; `\([^ \t\r\n]+\)': up to a space, a tab or the end
                    (let* ((e (%skip-while mid v
                                           (lambda (c) (not (memv c '(#\space #\tab))))))
                           (t (%skip-while mid e
                                           (lambda (c) (memv c '(#\space #\tab))))))
                      (and (= t (string-length mid))
                           (substring mid v e))))))))

    (define (%block-line-is? line prefix suffix key)
      ;; Whether LINE is the block's `End:' line - `re-end', which is
      ;;
      ;;   "[\r\n]" prefix "[ \t]*End *:[ \t]*" suffix "[\r\n]?"
      ;;
      ;; and carries no value at all. That ` *' where every other entry
      ;; has `[ \t]*' is the C's own, and it means spaces may precede the
      ;; colon but tabs may not.
      ;;--------------------------------------------------------------
      (let* ((mid (%block-strip line prefix suffix))
             (k (string-length key)))
        (and mid
             (let* ((i (%skip-while mid 0 (lambda (c) (memv c '(#\space #\tab)))))
                    (j (and (<= (+ i k) (string-length mid))
                            (string=? key (substring mid i (+ i k)))
                            (%skip-while mid (+ i k)
                                         (lambda (c) (char=? c #\space))))))
               (and j (< j (string-length mid)) (char=? (string-ref mid j) #\:)
                    (= (%skip-while mid (+ j 1)
                                    (lambda (c) (memv c '(#\space #\tab))))
                       (string-length mid)))))))

    (define (%local-variables-coding text)
      ;; The coding system a local-variables block names, or #f - the
      ;; tail half of `find-auto-coding'.
      ;;
      ;; The window and the anchors are Emacs's and all three matter: the
      ;; search begins at `(max (- size 3072) 0)', the first line must be
      ;; a whole line (`[\r\n]PREFIX[ \t]*Local Variables:[ \t]*SUFFIX
      ;; [\r\n]', so a block on the file's very first line - which has no
      ;; break before it - does not match, and neither does one on a last
      ;; line with no break after it), the prefix and suffix the block's
      ;; own line carries must appear on every entry's line, and the
      ;; block *ends at its `End:' line*, so a `coding:' after it is not
      ;; in the block. A search with none of those bounds answers for a
      ;; file that merely mentions the phrase.
      ;;--------------------------------------------------------------
      (let* ((n (string-length text))
             (tail-start (max 0 (- n *auto-coding-tail-size*)))
             (at (let loop ((i tail-start))
                   (cond
                    ((>= i n) #f)
                    ((and (<= (+ i 16) n)
                          (string=? "Local Variables:" (substring text i (+ i 16))))
                     (let ((ls (%line-after-break text i)))
                       (and ls (cons ls i))))
                    (else (loop (+ i 1)))))))
        (and at
             (let* ((ls (car at))
                    (hit (cdr at))
                    (le (%line-break-at-or-after text ls)))
               (and le
                    (let* ((prefix (substring text ls hit))
                           (suffix (substring text (+ hit 16) le))
                           (from (%line-after-break text (+ le 1)))
                           (end (let loop ((j from))
                                  (cond
                                   ((or (not j) (>= j n)) n)
                                   (else
                                    (let ((je (%line-break-at-or-after text j)))
                                      (cond
                                       ((not je) n)
                                       ((%block-line-is? (substring text j je)
                                                         prefix suffix "End")
                                        je)
                                       (else (loop (%line-after-break text (+ je 1)))))))))))
                      (let loop ((j from))
                        (cond
                         ((or (not j) (>= j end)) #f)
                         (else
                          (let ((je (%line-break-at-or-after text j)))
                            (cond
                             ((not je) #f)
                             (else
                              (let ((v (%block-line-value (substring text j je)
                                                          prefix suffix "coding")))
                                (or v (loop (%line-after-break text (+ je 1)))))))))))))))))

    (define (coding-system-from-file-name name)
      ;; The coding system a *name* stands for, as Emacs's
      ;; `find-coding-system' does - with the aliases a tag may use. A tag
      ;; says `latin-1' where the coding system is `iso-latin-1', so the
      ;; few spellings Emacs accepts are listed rather than guessed at.
      ;;--------------------------------------------------------------
      (let ((sym (if (symbol? name) name (string->symbol name))))
        (or (find-coding-system sym)
            (find-coding-system
             (case sym
               ((latin-1 iso-latin-1 iso-8859-1) 'iso-latin-1)
               ((utf-8 utf8) 'utf-8)
               ((ascii us-ascii) 'us-ascii)
               ((binary no-conversion) 'no-conversion)
               ((raw-text text) 'raw-text)
               ((utf-16 utf-16le utf-16be) sym)
               (else sym))))))

    (define (%byte-order-mark bytes)
      ;; The coding system a byte order mark at the front says: `EF BB BF'
      ;; is UTF-8, and either of `FF FE' / `FE FF' is UTF-16. Emacs reads
      ;; these in `detect_coding' (`coding.c') before any tag, because a
      ;; BOM is a declaration too - it is just written in bytes.
      ;;
      ;; **Both UTF-16 marks answer the same coding system, and that is
      ;; the codec's doing rather than a simplification.** Emacs names
      ;; them apart - `utf-16le-with-signature' and
      ;; `utf-16be-with-signature' - because its `:coding-type' carries
      ;; the byte order *and* whether a signature is written. iconv's
      ;; "UTF-16" is one codec that reads whichever mark is there and
      ;; writes one in the host's byte order, so naming them apart here
      ;; would be a name that lied about what the codec does. The
      ;; departure is that the byte order written back is the host's
      ;; (measured: `FF FE' on this machine) rather than the one read.
      ;;
      ;; The alternative - `utf-16le' / `utf-16be' - is *wrong* here and
      ;; was the first version: iconv's explicit-order codecs keep the
      ;; mark as a character, so the buffer got a U+FEFF in front of the
      ;; text where Emacs's has none. Measured: `(16 0 65 0 66 0)' read
      ;; as "UTF-16LE" is `(65279 65 66)', and as "UTF-16" is `(65 66)'.
      ;;--------------------------------------------------------------
      (let ((n (bytevector-length bytes)))
        (cond ((and (>= n 3) (= (bytevector-u8-ref bytes 0) #xEF)
                    (= (bytevector-u8-ref bytes 1) #xBB)
                    (= (bytevector-u8-ref bytes 2) #xBF))
               (find-coding-system 'utf-8))
              ((and (>= n 2)
                    (or (and (= (bytevector-u8-ref bytes 0) #xFF)
                             (= (bytevector-u8-ref bytes 1) #xFE))
                        (and (= (bytevector-u8-ref bytes 0) #xFE)
                             (= (bytevector-u8-ref bytes 1) #xFF))))
               (find-coding-system 'utf-16))
              (else #f))))

    (define (find-auto-coding filename bytes)
      ;; GNU Emacs's `find-auto-coding': the coding system FILENAME's
      ;; BYTES declare, or #f when nothing does.
      ;;
      ;; The order is Emacs's and it matters: a *declaration* is used as
      ;; given and the statistics are never consulted, which is why a file
      ;; saying `-*- coding: latin-1 -*-' is right even when its first 1k
      ;; would score as UTF-8.
      ;;--------------------------------------------------------------
      (let ((by-name (auto-coding-alist-lookup filename)))
        (or (and by-name (coding-system-from-file-name by-name))
            ;; The bytes as a string, one character per byte, made *once*:
            ;; the search is over bytes - a tag is ASCII - and decoding
            ;; them is the very thing that cannot happen before a coding
            ;; system has been chosen.
            (let ((text (%bytevector->latin1-string bytes)))
              (or (%head-coding text)
                  (%byte-order-mark bytes)
                  (%lookup (%local-variables-coding text)))))))

    (define (%head-coding text)
      ;; The `coding:' tag in the first line's `-*- ... -*-' form, or #f.
      ;;
      ;; **The `-*-' pair is *required*, and that is measured rather than
      ;; assumed.** Emacs's head scan is bounded by
      ;; `(setq head-end (set-auto-mode-1))' (`mule.el:1938'), and
      ;; `set-auto-mode-1' answers the end of the `-*- ... -*-' form or
      ;; nil - so the `(when (and head-end (< head-found head-end)) ...)'
      ;; around the tag search is skipped entirely for a file with no
      ;; `-*-'. Measured on Emacs 31.1: a first line of
      ;; `; coding: iso-8859-1' answers **nil**, and
      ;; `;; -*- coding: latin-1 -*-' answers `latin-1'.
      ;;
      ;; That is exactly where Guile's `file-encoding' differs - it takes
      ;; the bare comment - and it is the difference that decides whether
      ;; a file merely *mentioning* `coding:' is mis-read.
      ;;--------------------------------------------------------------
      (let* ((eol (%line-end-at text 0))
             (line (substring text 0 eol))
             (open (string-contains line "-*-")))
        (and open
             (let ((close (string-contains line "-*-" (+ open 3))))
               (and close
                    (%lookup (%tag-in line (+ open 3) close)))))))

    (define (%lookup name)
      (and (string? name)
           (coding-system-from-file-name name)))

    (define (%bytevector->latin1-string bytes)
      ;; The bytes as a string, one character per byte. The *search* is
      ;; over bytes - a tag is ASCII - and this is the cheapest way to
      ;; look at them without decoding, which is the whole point of not
      ;; having decided a coding system yet.
      ;;--------------------------------------------------------------
      (let* ((n (bytevector-length bytes))
             (out (make-string n)))
        (let loop ((i 0))
          (if (>= i n) out
              (begin (string-set! out i (integer->char (bytevector-u8-ref bytes i)))
                     (loop (+ i 1)))))))

    (define (set-auto-coding filename bytes)
      ;; GNU Emacs's `set-auto-coding': "Return coding system for a file
      ;; FILENAME of which SIZE bytes follow point. ... Return nil if an
      ;; invalid coding system is found."
      ;;--------------------------------------------------------------
      (let ((found (find-auto-coding filename bytes)))
        (and found (coding-system-p found) found)))

    ))
