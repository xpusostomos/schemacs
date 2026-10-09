(define-library (schemacs editor character)
  ;; This library mirrors GNU Emacs's `src/character.c' - the width of a
  ;; character, which is how many screen *columns* it occupies and is not
  ;; the same thing as how many characters it takes to write it.
  ;;
  ;; It matters as soon as a buffer holds anything outside ASCII. A CJK
  ;; ideograph is one character and two columns; a combining acute is one
  ;; character and no columns at all. An editor that counts characters
  ;; where it should count columns draws the text correctly - the terminal
  ;; and the font both know the real width - and then puts the cursor, the
  ;; region and everything after it in the wrong place by one column per
  ;; wide character.
  ;;
  ;; The table itself is `characters.sld', which is
  ;; `lisp/international/characters.el'; this file is the C, which creates
  ;; the table and owns the default. The two names differ by one letter
  ;; because Emacs's do.

  (import
    (scheme base)
    (scheme char)
    ;; the bit arithmetic of the event model, and `filter' for a symbol
    ;; event's modifiers
    (only (guile) filter logand logior lognot)
    (scheme char)
    (only (schemacs editor characters) char-width-ranges))

  (export
   ;; The key event model and `kbd'. They are `subr.el''s and
   ;; `keyboard.c''s in Emacs and are *here* because this is the lowest
   ;; editor library: `lisp.h''s `CHAR_*' bits, `make_ctrl_char' and
   ;; `event-basic-type' are all about characters, and everything that
   ;; binds a key - `minibuffer.sld' included, which cannot import
   ;; `subr.sld' - has to be able to read a `kbd' description.
   char-alt char-super char-hyper char-shift char-ctl char-meta
   parse-solitary-modifier make-ctrl-char
   function-key-name function-key-offset *lispy-function-keys*
   parse-modifiers-uncached event-symbol-elements
   event-modifiers event-basic-type apply-modifiers event-convert-list
   kbd
   *tab-width*
   char-width
   char-width-default
   sanitize-char-width
   ;; The eight-bit representation - GNU Emacs's `CHAR_BYTE8_P' and the
   ;; four beside it. See the note where they are defined.
   *max-5-byte-char*
   char-byte8? byte8-to-char char-to-byte8 char-to-byte-safe unibyte-to-char)

  (begin

    (define *tab-width* (make-parameter 8))
    ;; ^ GNU Emacs's `tab-width'. Emacs defines it in `buffer.c' and
    ;; `CHARACTER_WIDTH' reads it through `SANE_TAB_WIDTH (current_buffer)',
    ;; which is why the default and the tab case of `char-width' below are
    ;; here. It is a parameter rather than a buffer-local because this
    ;; project has one value for the buffer being drawn rather than a value
    ;; per buffer - the same decision `disp-table.sld' records.
    ;;
    ;; It is *defined* here, rather than in `buffer.sld' where Emacs
    ;; defines it, because of the import graph: `buffer.sld' imports
    ;; `frame.sld', which imports `xdisp.sld', which imports
    ;; `disp-table.sld', which imports this library - so a `tab-width' in
    ;; `buffer.sld' is not reachable from the width code without a cycle.
    ;; `disp-table.sld' imports it from here for the same reason. There is
    ;; exactly one, so the two cannot disagree.

    (define char-width-default 1)
    ;; ^ `Vchar_width_table = Fmake_char_table (Qnil, make_fixnum (1))'
    ;; in `syms_of_character'. A character in none of the table's ranges
    ;; is one column wide.

    ;;------------------------------------------------------------------
    ;; The eight-bit representation - `character.h:104'
    ;;------------------------------------------------------------------
    ;;
    ;; "True iff C is a character that corresponds to a raw 8-bit byte."
    ;; Emacs has a *character* for every byte it cannot decode, so that a
    ;; file whose bytes are not valid in the buffer's charset can still be
    ;; held and written back unchanged: the byte becomes the code point
    ;; `0x3FFF00 + byte', and `CHAR_TO_BYTE8' turns it back into the byte.
    ;; That range sits above every character the five-byte
    ;; `utf-8-emacs' form can encode, which is what makes the test cheap.
    ;;
    ;; It is the one piece of coding machinery that has to be written by
    ;; hand: "do not convert" is not a charset conversion, so no iconv
    ;; encoding name expresses it - see `(schemacs editor coding)'. Every
    ;; other coding system here is Guile's iconv under a Lisp name.
    ;;
    ;; The arguments are *code points*, as the C's are, and not
    ;; characters: these are arithmetic on the numbers.
    (define *max-5-byte-char* #x3FFF7F)
    ;; ^ `MAX_5_BYTE_CHAR' (`character.h:59'), the largest character the
    ;; five-byte `utf-8-emacs' form holds.

    (define (char-byte8? c)
      ;; `CHAR_BYTE8_P' (`character.h:104'): "True iff C is a character
      ;; that corresponds to a raw 8-bit byte."
      ;;--------------------------------------------------------------
      (> c *max-5-byte-char*))

    (define (byte8-to-char byte)
      ;; `BYTE8_TO_CHAR' (`character.h:112'): "Return the character code
      ;; for raw 8-bit byte BYTE." 0x80 becomes #x3FFF80 and 0xFF #x3FFFFF.
      ;;--------------------------------------------------------------
      (+ byte #x3FFF00))

    (define (unibyte-to-char byte)
      ;; `UNIBYTE_TO_CHAR' (`character.h:117'): ASCII is itself; anything
      ;; else is the byte character above. This is how a *unibyte* buffer
      ;; holds its bytes, which is the same trick.
      ;;--------------------------------------------------------------
      (if (< byte #x80) byte (byte8-to-char byte)))

    (define (char-to-byte8 c)
      ;; `CHAR_TO_BYTE8' (`character.h:125'): "Return the raw 8-bit byte
      ;; for character C." A byte character gives its byte back; anything
      ;; else is masked to eight bits, which is the C's `c & 0xFF'.
      ;;--------------------------------------------------------------
      (if (char-byte8? c) (- c #x3FFF00) (logand c #xFF)))

    (define (char-to-byte-safe c)
      ;; `CHAR_TO_BYTE_SAFE' (`character.h:133'): "Return the raw 8-bit
      ;; byte for character C, or -1 if C doesn't correspond to a byte."
      ;; A *character* that is not ASCII and not a byte character has no
      ;; byte, and -1 says so where `char-to-byte8''s mask would quietly
      ;; invent one.
      ;;--------------------------------------------------------------
      (cond ((< c #x80) c)
            ((char-byte8? c) (- c #x3FFF00))
            (else -1)))

    (define (sanitize-char-width width)
      ;; Emacs's `sanitize_char_width': a width outside 0..1000 is taken
      ;; to be 1000, so a broken table cannot make redisplay allocate
      ;; nonsense.
      ;;--------------------------------------------------------------
      (if (and (<= 0 width) (<= width 1000)) width 1000))

    (define (char-width-table-ref c)
      ;; The table's answer for C: the width of the range it falls in, or
      ;; the default 1.
      ;;
      ;; A bisection rather than a scan: the ranges are sorted and
      ;; disjoint, there are 400-odd of them, and this runs once per
      ;; character of every line drawn.
      ;;--------------------------------------------------------------
      (let ((ranges char-width-ranges))
        (let loop ((lo 0) (hi (vector-length ranges)))
          (if (>= lo hi)
              char-width-default
              (let* ((mid (quotient (+ lo hi) 2))
                     (r (vector-ref ranges mid)))
                (cond ((< c (vector-ref r 0)) (loop lo mid))
                      ((< (vector-ref r 1) c) (loop (+ mid 1) hi))
                      (else (vector-ref r 2))))))))

    (define (char-width ch)
      ;; GNU Emacs's `char-width': the width of CH in columns when
      ;; displayed in the current buffer.
      ;;
      ;; This is Emacs's `CHARACTER_WIDTH' macro (`buffer.h'), which is
      ;; what `char_width' starts from. The C writes it as one nested
      ;; conditional and the branches are worth keeping in its order,
      ;; because they are not all table lookups:
      ;;
      ;;   0x20..0x7E   1        - printable ASCII, whatever the table says
      ;;   above 0x7F   the table
      ;;   tab          `tab-width'
      ;;   newline      0        - a newline ends a line, it does not occupy one
      ;;   other control characters, DEL included:
      ;;               2 in caret notation (^M), 4 as an octal escape (\015)
      ;;
      ;; The 2-versus-4 choice is Emacs's `ctl-arrow', a buffer-local
      ;; variable this editor does not have yet - `disp-table.sld' always
      ;; draws caret notation - so it is the 2 here. `char_width' then
      ;; applies the buffer's display table; this editor has no
      ;; `buffer-display-table' either, so there is nothing to apply.
      ;;--------------------------------------------------------------
      (let ((c (char->integer ch)))
        (cond
         ((and (<= #x20 c) (< c #x7f)) 1)
         ((< #x7f c) (sanitize-char-width (char-width-table-ref c)))
         ((char=? ch #\tab) (*tab-width*))
         ((char=? ch #\newline) 0)
         (else 2))))

    
    ;;
    ;; GNU Emacs's `kbd' (`subr.el:1258') is how a user writes a key
    ;; sequence: `(kbd "C-x C-f")', `(kbd "C-/")', `(kbd "<up>")'. It is
    ;; `key-parse' (`keymap.el:235') doing the work, and it is the one
    ;; place the key vocabulary is written down: every binding in Emacs
    ;; is either a literal string/vector or a `kbd' call, and both end up
    ;; in the same representation.
    ;;
    ;; Without it there is no way for a user to write a binding at all -
    ;; the only way here was a raw path list, and the path each *front
    ;; end* produces for a key is not the same. A terminal folds C-/ and
    ;; C-_ into one byte where a window system sends two different
    ;; keysyms, so a binding written against one front end's spelling
    ;; matched only that front end - which is why C-/ and C-_ did nothing
    ;; on the graphical one, and why C-@ and C-SPC needed two bindings.
    ;;
    ;; What that answer now is is GNU Emacs's: a *vector of key events* -
    ;; `(kbd "C-x C-f")' is `#(24 6)' and `(kbd "C-/")' is `#(31)' -
    ;; which is what `define-key' takes there ("a string or a vector of
    ;; symbols and characters", `keymap.c':1084') and what every read in
    ;; this tree answers with. The older spelling this parser also
    ;; produces, a list of modifier symbols and characters, is
    ;; `(schemacs keymap)''s own key representation and is what
    ;; `keymap-index' converts an event into; it is kept as an input
    ;; because the keymap layer tables are written in it.
    ;;----------------------------------------------------------------

    (define *key-parse-modifiers*
      ;; The modifier prefixes `key-parse' takes, with the modifier each
      ;; names. The letters are Emacs's (`keyboard.c':7390-7414):
      ;; `S-' is *shift* and `s-' is super, which this table had the other
      ;; way round - so `(kbd "S-<up>")' named a super key where Emacs
      ;; names a shifted one.
      '((#\A . alt)
        (#\C . control)
        (#\H . hyper)
        (#\M . meta)
        (#\S . shift)
        (#\s . super)))

    (define *key-parse-named*
      ;; The named keys `key-parse' translates, with the characters they
      ;; stand for. These are `key-parse''s own list.
      ;; `\delete' is ncurses's DEL; Scheme has no character name for
      ;; it that this tree agrees on, so it is the character 127.
      ;; A quasiquote and not a quote: the DEL entry is built, and under a
      ;; plain quote the `,' never fired - so `DEL' answered the *list*
      ;; `(unquote (integer->char 127))' instead of a character, and
      ;; `(kbd "DEL")' was broken from the day it was written.
      `(("NUL" . #\nul) ("RET" . #\return) ("LFD" . #\newline)
        ("TAB" . #\tab) ("ESC" . #\esc) ("SPC" . #\space)
        ("DEL" . ,(integer->char 127))))

    (define (key-parse-word keys pos)
      ;; The next word of KEYS from POS: up to the next space, but a word
      ;; that begins with `<' runs to its `>', which is how `<up>' holds
      ;; a space it should not be split at.
      ;;--------------------------------------------------------------
      (let ((end (string-length keys)))
        (if (and (< pos end) (char=? (string-ref keys pos) #\<))
            (let scan ((i (+ pos 1)))
              (cond ((>= i end) end)
                    ((char=? (string-ref keys i) #\>) (+ i 1))
                    (else (scan (+ i 1)))))
            (let scan ((i pos))
              (cond ((>= i end) end)
                    ((char=? (string-ref keys i) #\space) i)
                    (else (scan (+ i 1))))))))

    (define (key-parse-modifiers word)
      ;; The modifier symbols WORD prefixes and the character or named
      ;; key they modify: `(VALUES . REST)'. `key-parse' strips the
      ;; prefixes one at a time, so `C-M-_` is two.
      ;;--------------------------------------------------------------
      (let loop ((mods '()) (rest word))
        (if (and (> (string-length rest) 2)
                 (char=? (string-ref rest 1) #\-)
                 (assv (string-ref rest 0) *key-parse-modifiers*))
            (loop (cons (cdr (assv (string-ref rest 0)
                                   *key-parse-modifiers*))
                        mods)
                  (substring rest 2))
            (cons (reverse mods) rest))))

    (define (key-parse-bits mods)
      ;; The modifier bits the symbols MODS stand for, added up - the C's
      ;; `bits' in `key-parse' (`keymap.el:282'), where each `X-' prefix
      ;; contributes its `?\X-\0'. They are distinct bits, so this is a
      ;; `logior' written as the C writes it.
      ;;--------------------------------------------------------------
      (let loop ((rest mods) (bits 0))
        (if (null? rest)
            bits
            (loop (cdr rest)
                  (+ bits (cond ((eq? (car rest) 'alt) char-alt)
                                ((eq? (car rest) 'control) char-ctl)
                                ((eq? (car rest) 'hyper) char-hyper)
                                ((eq? (car rest) 'meta) char-meta)
                                ((eq? (car rest) 'shift) char-shift)
                                ((eq? (car rest) 'super) char-super)
                                (else 0)))))))

    (define (key-parse-char mods char word)
      ;; One character key with its modifiers, as `key-parse' builds it
      ;; (`keymap.el:304'-`:316'). Four cases, in the C's order:
      ;;
      ;;   * no modifiers: the character itself;
      ;;   * meta and nothing else on an all-digit word: the digits, each
      ;;     with the meta bit - `(kbd "M-6")' and its like;
      ;;   * a word of more than one character, with modifiers: an error,
      ;;     "X- must prefix a single character, not WORD";
      ;;   * control with the character in its *control column*
      ;;     (`@-_a-z', whose control code is the low five bits): the
      ;;     other bits plus that code - so `C-M-M' is meta + 13;
      ;;   * anything else: the bits added to the character's code.
      ;;--------------------------------------------------------------
      (let ((bits (key-parse-bits mods))
            (code (char->integer char)))
        (cond
         ((zero? bits) code)
         ((and (= bits char-meta) (char-numeric? char)) (+ code bits))
         ((not (= (string-length word) 1))
          (error "~a must prefix a single character, not ~a"
                 (substring word 0 (- (string-length word)
                                      (string-length (string char))))
                 word))
         ((and (not (zero? (logand bits char-ctl)))
               (or (char<=? #\@ char #\_)
                   (char<=? #\a char #\z)))
          (+ (- bits char-ctl) (logand code 31)))
         (else (+ bits code)))))

    (define %named-key-names
      ;; The seven words `key-parse' translates to a character
      ;; (`keymap.el:293'), which is also the list its angle-bracket
      ;; branch refuses to treat as a *name*: `(kbd "<DEL>")' is the
      ;; character 127 and not a key called DEL.
      '("NUL" "RET" "LFD" "TAB" "ESC" "SPC" "DEL"))

    (define (named-key-suffix? text)
      ;; Whether TEXT ends with one of `%named-key-names' at a word
      ;; boundary - the C's
      ;; "\\<\\(NUL\\|RET\\|...\\)$" (`keymap.el:275').
      ;;--------------------------------------------------------------
      (let loop ((names %named-key-names))
        (if (null? names)
            #f
            (let* ((name (car names))
                   (n (string-length name)))
              (cond
               ((and (>= (string-length text) n)
                     (string=? name (substring text (- (string-length text) n)
                                               (string-length text)))
                     (or (= n (string-length text))
                         (not (char-alphabetic?
                               (string-ref text (- (string-length text) n 1))))))
                #t)
               (else (loop (cdr names))))))))

    (define (meta-number? text)
      ;; Whether TEXT is what the C's "^\\(-?[0-9]+\\)$" matches
      ;; (`keymap.el:305'): an optional `-' and then ASCII digits, so that
      ;; `(kbd "M-6")' is `digit-argument' and `(kbd "M-12")' is two of
      ;; them. `char-numeric?' is not this test - it is Unicode's.
      ;;--------------------------------------------------------------
      (let ((start (if (and (> (string-length text) 0)
                            (char=? (string-ref text 0) #\-))
                       1 0)))
        (and (< start (string-length text))
             (let loop ((i start))
               (cond ((>= i (string-length text)) #t)
                     ((char<=? #\0 (string-ref text i) #\9) (loop (+ i 1)))
                     (else #f))))))

    (define (angle-key-name word)
      ;; The name a `<...>' word denotes, modifiers and all, or #f: the
      ;; C's "\\`\\(\\([ACHMsS]-\\)*\\)<\\(.+\\)>$" branch
      ;; (`keymap.el:270'), which turns `S-<f10>' into the *symbol*
      ;; `S-f10' and `C-<left>' into `C-left', and which steps aside for
      ;; the seven named keys - so `(kbd "<DEL>")' is the character 127
      ;; and not a symbol. The scan skips the modifier prefixes, which
      ;; are single letters each followed by `-', and then wants a `<'
      ;; and a closing `>'.
      ;;--------------------------------------------------------------
      (let loop ((i 0))
        (cond
         ((and (> (- (string-length word) i) 2)
               (char=? (string-ref word i) #\<)
               (char=? (string-ref word (- (string-length word) 1)) #\>))
          (let ((text (string-append (substring word 0 i)
                                     (substring word (+ i 1)
                                                (- (string-length word) 1)))))
            (and (not (named-key-suffix? text)) text)))
         ((and (< (+ i 1) (string-length word))
               (char=? (string-ref word (+ i 1)) #\-)
               (memv (string-ref word i) (list #\A #\C #\H #\M #\s #\S)))
          (loop (+ i 2)))
         (else #f))))

    (define (parse-key word)
      ;; One word of a `kbd' string as the key (or keys) it names, as a
      ;; *list* of events - Emacs's `key-parse''s `key', which `vconcat'
      ;; splices into the sequence. It is a list because one word can be
      ;; more than one event: `(kbd "M-12")' is two - the digits 1 and 2,
      ;; each with the meta bit - and `(kbd "f10")', a word with no
      ;; modifiers and no angle brackets, is the three characters f, 1
      ;; and 0.
      ;;
      ;; **A character's event is `key-parse''s own arithmetic and not
      ;; `event-convert-list'** (`keymap.el:304'-`:316'). The two
      ;; disagree, and the difference is a whole class of key:
      ;;
      ;;   * `event-convert-list' *folds* - it turns `(shift ?x)' into
      ;;     `X' and runs control through `make_ctrl_char' - so
      ;;     `(kbd "S-x")' came out as `X', losing the key;
      ;;   * `key-parse' adds the modifier *bits* to the character and
      ;;     folds only the control *column* (`@-_a-z', whose control is
      ;;     the low five bits), so `S-x' is `shift | ?x' = 33554552,
      ;;     which is what Emacs answers.
      ;;
      ;; Measured against Emacs 31.1: `(kbd "C-x")' 24, `(kbd "S-x")'
      ;; 33554552, `(kbd "C-M-M")' 134217741 - the `M' folds to 13,
      ;; `\r', with no shift kept - `(kbd "M-<")' 134217788, `(kbd
      ;; "M-12")' the two events 134217777 and 134217778, and `(kbd
      ;; "C-f10")' the error "C- must prefix a single character, not
      ;; f10".
      ;;--------------------------------------------------------------
      (let ((angle-name (angle-key-name word)))
        (cond
         (angle-name (list (string->symbol angle-name)))
         (else
          (let* ((mods-and-key (key-parse-modifiers word))
                 (mods (car mods-and-key))
                 (raw (cdr mods-and-key))
                 (bits (key-parse-bits mods))
                 (found (assoc raw *key-parse-named*))
                 ;; The word as Emacs has it *after* its named-key
                 ;; substitution: `TAB' is `#\tab' by then, and the
                 ;; "single character" test below is made on this.
                 (keytext (if found (string (cdr found)) raw))
                 (char (if found (cdr found)
                           (and (= (string-length raw) 1)
                                (string-ref raw 0)))))
            (cond
             ;; No modifiers: the word is its own keys - `key-parse''s
             ;; `key = word', which `vconcat' splices. That is where
             ;; `(kbd "f10")' being the three characters f, 1, 0 comes
             ;; from.
             ((zero? bits) (map char->integer (string->list keytext)))
             ;; Meta alone on a number: each digit takes the bit
             ;; (`keymap.el:305'), which is how `M-6' is
             ;; `digit-argument' and `M-12' is two of them.
             ((and (= bits char-meta) (meta-number? keytext))
              (map (lambda (c) (+ bits (char->integer c)))
                   (string->list keytext)))
             ;; A modifier prefix needs a *single* character under it -
             ;; Emacs's own complaint (`keymap.el:311'). `C-f10' is an
             ;; error and `C-<f10>' is the key, which is why the angle
             ;; form is taken above.
             ((not (= (string-length keytext) 1))
              (error "~a must prefix a single character, not ~a"
                     (substring word 0 (- (string-length word)
                                          (string-length raw)))
                     keytext))
             ;; The control column: `@-_a-z' denote control characters
             ;; by their low five bits, so `C-M-M' is meta + 13.
             ((and (not (zero? (logand bits char-ctl)))
                   (or (and (char>=? char #\@) (char<=? char #\_))
                       (and (char>=? char #\a) (char<=? char #\z))))
              (list (+ (- bits char-ctl) (logand (char->integer char) 31))))
             (else (list (+ bits (char->integer char))))))))))

    ;;----------------------------------------------------------------
    ;; Key events
    ;;
    ;; GNU Emacs's event model, which is what a key *is* everywhere above
    ;; the reader: an integer whose low bits are the character and whose
    ;; high bits are the modifiers, or a symbol for a key that is not a
    ;; character (`up', `f1', `delete'). The modifier bits are the C's
    ;; `CHAR_*' (`lisp.h':3221), and a terminal's meta byte becomes
    ;; `CHAR_META' rather than staying the 8th bit (`keyboard.c':2676) -
    ;; which is why `?\M-a' is 134217825 and not 225.
    ;;
    ;; `event-modifiers' and `event-basic-type' are `subr.el''s (1825 and
    ;; 1862) and are the two halves of the decomposition a keymap lookup
    ;; needs; `event-convert-list' is `keyboard.c''s (7832) and is the way
    ;; back, which is what `kbd' builds a binding with. The three C
    ;; functions it rests on - `parse_solitary_modifier' (7920),
    ;; `make_ctrl_char' (2178) and `apply_modifiers_uncached' (7479) - are
    ;; `keyboard.c''s too and live here with it, because `kbd' is
    ;; `subr.el''s and has to build an event: this library is *below*
    ;; `(schemacs editor keyboard)' and cannot import it. That is the same
    ;; seam `*tab-width*' gets in `character.sld'.
    ;;------------------------------------------------------------------

    (define char-alt   #x0400000)
    (define char-super #x0800000)
    (define char-hyper #x1000000)
    (define char-shift #x2000000)
    (define char-ctl   #x4000000)
    (define char-meta  #x8000000)
    ;; ^ `CHAR_ALT', `CHAR_SUPER', `CHAR_HYPER', `CHAR_SHIFT', `CHAR_CTL',
    ;; `CHAR_META' (`lisp.h':3221). `CHAR_CTL' is not a bit a *character*
    ;; event keeps: `make-ctrl-char' folds control into the code, and the
    ;; bit survives only for a code that cannot be folded.

    (define %modifier-bits
      ;; the six, as `(NAME . BIT)', in the order `event-modifiers' lists
      ;; them - `alt', `super', `hyper', `shift', `control', `meta' -
      ;; because the C pushes them onto the front of one list in the
      ;; opposite order (`subr.el':1846-1858).
      ;;--------------------------------------------------------------
      (list (cons 'alt char-alt) (cons 'super char-super)
            (cons 'hyper char-hyper) (cons 'shift char-shift)
            (cons 'control char-ctl) (cons 'meta char-meta)))

    (define *lispy-function-keys*
      ;; GNU Emacs's `lispy_function_keys' (`keyboard.c':5513): "You'll
      ;; notice that this table is arranged to be conveniently indexed by
      ;; X Windows keysym values." A keysym from `FUNCTION_KEY_OFFSET'
      ;; (0xff00) up is not a character, and what it is called is this
      ;; table at its offset: 0xff0d is `"return"', 0xff50 `"home"',
      ;; 0xff63 `"insert"', 0xffff `"delete"'. #f for a keysym the table
      ;; leaves unnamed, which is Emacs's 0.
      ;;
      ;; It is here rather than in a backend because it is not a
      ;; backend's: the same names come out of an X display, a Gtk one
      ;; and a terminal's terminfo (`term.c''s `fkey_table' spells the
      ;; terminfo names into exactly this list).
      ;;--------------------------------------------------------------
      (vector
        #f #f #f #f #f #f                                                    ; 0xff00
        #f #f "backspace" "tab" "linefeed" "clear"                           ; 0xff06
        #f "return" #f #f #f #f                                              ; 0xff0c
        #f "pause" #f #f #f #f                                               ; 0xff12
        #f #f #f "escape" #f #f                                              ; 0xff18
        #f #f #f "kanji" "muhenkan" "henkan"                                 ; 0xff1e
        "romaji" "hiragana" "katakana" "hiragana-katakana" "zenkaku" "hankaku" ; 0xff24
        "zenkaku-hankaku" "touroku" "massyo" "kana-lock" "kana-shift" "eisu-shift" ; 0xff2a
        "eisu-toggle" #f #f #f #f #f                                         ; 0xff30
        #f #f #f #f #f #f                                                    ; 0xff36
        #f #f #f #f #f #f                                                    ; 0xff3c
        #f #f #f #f #f #f                                                    ; 0xff42
        #f #f #f #f #f #f                                                    ; 0xff48
        #f #f "home" "left" "up" "right"                                     ; 0xff4e
        "down" "prior" "next" "end" "begin" #f                               ; 0xff54
        #f #f #f #f #f #f                                                    ; 0xff5a
        "select" "print" "execute" "insert" #f "undo"                        ; 0xff60
        "redo" "menu" "find" "cancel" "help" "break"                         ; 0xff66
        #f #f #f #f #f #f                                                    ; 0xff6c
        #f #f "backtab" #f #f #f                                             ; 0xff72
        #f #f #f #f #f #f                                                    ; 0xff78
        #f "kp-numlock" "kp-space" #f #f #f                                  ; 0xff7e
        #f #f #f #f #f "kp-tab"                                              ; 0xff84
        #f #f #f "kp-enter" #f #f                                            ; 0xff8a
        #f "kp-f1" "kp-f2" "kp-f3" "kp-f4" "kp-home"                         ; 0xff90
        "kp-left" "kp-up" "kp-right" "kp-down" "kp-prior" "kp-next"          ; 0xff96
        "kp-end" "kp-begin" "kp-insert" "kp-delete" #f #f                    ; 0xff9c
        #f #f #f #f #f #f                                                    ; 0xffa2
        #f #f "kp-multiply" "kp-add" "kp-separator" "kp-subtract"            ; 0xffa8
        "kp-decimal" "kp-divide" "kp-0" "kp-1" "kp-2" "kp-3"                 ; 0xffae
        "kp-4" "kp-5" "kp-6" "kp-7" "kp-8" "kp-9"                            ; 0xffb4
        #f #f #f "kp-equal" "f1" "f2"                                        ; 0xffba
        "f3" "f4" "f5" "f6" "f7" "f8"                                        ; 0xffc0
        "f9" "f10" "f11" "f12" "f13" "f14"                                   ; 0xffc6
        "f15" "f16" "f17" "f18" "f19" "f20"                                  ; 0xffcc
        "f21" "f22" "f23" "f24" "f25" "f26"                                  ; 0xffd2
        "f27" "f28" "f29" "f30" "f31" "f32"                                  ; 0xffd8
        "f33" "f34" "f35" #f #f #f                                           ; 0xffde
        #f #f #f #f #f #f                                                    ; 0xffe4
        #f #f #f #f #f #f                                                    ; 0xffea
        #f #f #f #f #f #f                                                    ; 0xfff0
        #f #f #f #f #f #f                                                    ; 0xfff6
        #f #f #f "delete"                                                    ; 0xfffc
        ))

    (define function-key-offset #xff00)
    ;; ^ `FUNCTION_KEY_OFFSET' (`keyboard.c':5507').

    (define (function-key-name keysym)
      ;; The name GNU Emacs gives a non-character keysym, or #f. The
      ;; lookup is the C's `lispy_function_keys[keysym -
      ;; FUNCTION_KEY_OFFSET]' and nothing more.
      ;;--------------------------------------------------------------
      (and (integer? keysym)
           (>= keysym function-key-offset)
           (< (- keysym function-key-offset) (vector-length *lispy-function-keys*))
           (vector-ref *lispy-function-keys* (- keysym function-key-offset))))

    (define (parse-solitary-modifier symbol)
      ;; GNU Emacs's `parse_solitary_modifier' (`keyboard.c':7920): the
      ;; modifier bit SYMBOL names, or #f when it names none. Both the
      ;; single letters and the spelled-out names count.
      ;;--------------------------------------------------------------
      (and (symbol? symbol)
           (let ((name (symbol->string symbol)))
             (cond
              ((string=? name "A") char-alt)
              ((string=? name "alt") char-alt)
              ((string=? name "C") char-ctl)
              ((string=? name "c") char-ctl)
              ((string=? name "ctrl") char-ctl)
              ((string=? name "control") char-ctl)
              ((string=? name "H") char-hyper)
              ((string=? name "hyper") char-hyper)
              ((string=? name "M") char-meta)
              ((string=? name "meta") char-meta)
              ((string=? name "S") char-shift)
              ((string=? name "shift") char-shift)
              ((string=? name "s") char-super)
              ((string=? name "super") char-super)
              (else #f)))))

    (define (make-ctrl-char c)
      ;; GNU Emacs's `make_ctrl_char' (`keyboard.c':2178): C as the control
      ;; character it denotes. "Everything in the columns containing the
      ;; upper-case letters denotes a control character" - `@A-Z[\]^_' are
      ;; 0-31, with the shift kept for a letter - and the lower-case
      ;; letters fold the same way. Any other printing ASCII keeps the
      ;; control *bit*, there being no folded code for it, and a code that
      ;; is not ASCII has only the bit.
      ;;--------------------------------------------------------------
      (let ((upper (logand c (lognot #o177))))
        (if (not (and (<= 0 c) (< c 128)))
            (logior c char-ctl)
            (let* ((c (logand c #o177))
                   (c (cond
                       ((and (>= c #o100) (< c #o140))
                        (logior (logand c (lognot #o140))
                                (if (and (>= c (char->integer #\A))
                                         (<= c (char->integer #\Z)))
                                    char-shift
                                    0)))
                       ((and (>= c (char->integer #\a))
                             (<= c (char->integer #\z)))
                        (logand c (lognot #o140)))
                       ((>= c (char->integer #\space)) (logior c char-ctl))
                       (else c))))
              (logior c (logand upper (lognot char-ctl)))))))

    (define (modifier-word name i)
      ;; The modifier *word* NAME has at I, as `(END . BITS)' or #f: one
      ;; letter or a spelled-out name. This is the `switch' of
      ;; `parse_modifiers_uncached' (`keyboard.c':7385).
      ;;--------------------------------------------------------------
      (let ((len (string-length name)))
        (define (single bit) (cons (+ i 1) bit))
        (define (multi word bit)
          (and (<= (+ i (string-length word)) len)
               (string=? (substring name i (+ i (string-length word))) word)
               (cons (+ i (string-length word)) bit)))
        (case (string-ref name i)
          ((#\A) (single char-alt))
          ((#\C) (single char-ctl))
          ((#\H) (single char-hyper))
          ((#\M) (single char-meta))
          ((#\S) (single char-shift))
          ((#\s) (or (multi "shift" char-shift)
                     (multi "super" char-super)
                     (single char-super)))
          ((#\a) (multi "alt" char-alt))
          ((#\c) (or (multi "ctrl" char-ctl) (multi "control" char-ctl)))
          ((#\h) (multi "hyper" char-hyper))
          ((#\m) (multi "meta" char-meta))
          (else #f))))

    (define (parse-modifiers-uncached symbol)
      ;; GNU Emacs's `parse_modifiers_uncached' (`keyboard.c':7365): the
      ;; modifier bits SYMBOL's *name* begins with, and the name's tail -
      ;; the base - as `(BITS . BASE-NAME)'. A word is a modifier only when
      ;; a dash follows it, and the scan stops one short of the end,
      ;; because the base is at least one character.
      ;;--------------------------------------------------------------
      (let* ((name (symbol->string symbol))
             (len (string-length name)))
        (let loop ((i 0) (bits 0))
          (if (>= i (- len 1))
              (cons bits (substring name i len))
              (let ((found (modifier-word name i)))
                (if (and found
                         (< (car found) len)
                         (char=? (string-ref name (car found)) #\-))
                    (loop (+ (car found) 1) (logior bits (cdr found)))
                    (cons bits (substring name i len))))))))

    (define (event-symbol-elements symbol)
      ;; GNU Emacs's `event-symbol-elements': the parsed event type of a
      ;; symbol, as `(BASE MODIFIER ...)'. Emacs caches this on the
      ;; symbol's plist, which a symbol has not got here, so it is parsed
      ;; each time.
      ;;--------------------------------------------------------------
      (let* ((parsed (parse-modifiers-uncached symbol))
             (bits (car parsed)))
        (cons (string->symbol (cdr parsed))
              ;; The *symbol* list runs the other way from the integer
              ;; one: `lispy_modifier_list' (`keyboard.c':7541) walks the
              ;; bits upwards and conses each onto the front, so the list
              ;; comes out in *descending* bit order - `(meta control
              ;; shift)' for `C-M-S-s' - where `event-modifiers' answers
              ;; ascending. Two orders for the one thing, and Emacs's.
              (map car (filter (lambda (m) (not (zero? (logand bits (cdr m)))))
                               (reverse %modifier-bits))))))

    (define (event-modifiers event)
      ;; GNU Emacs's `event-modifiers' (`subr.el':1825): "Return a list of
      ;; symbols representing the modifier keys in event EVENT." A symbol
      ;; event carries its modifiers in its own name; an integer carries
      ;; them as the C's bits - and *control* is also implied by a basic
      ;; code below 32, because a terminal sends `C-a' as the byte 1 and
      ;; there is no bit to find.
      ;;--------------------------------------------------------------
      (if (symbol? event)
          (cdr (event-symbol-elements event))
          (let* ((mask (lognot (logior char-alt char-super char-hyper
                                       char-shift char-ctl char-meta)))
                 (char (logand event mask)))
            (append
             (if (not (zero? (logand event char-alt))) (list 'alt) '())
             (if (not (zero? (logand event char-super))) (list 'super) '())
             (if (not (zero? (logand event char-hyper))) (list 'hyper) '())
             (if (or (not (zero? (logand event char-shift)))
                     (not (char=? (integer->char char)
                                  (char-downcase (integer->char char)))))
                 (list 'shift) '())
             (if (or (not (zero? (logand event char-ctl))) (< char 32))
                 (list 'control) '())
             (if (not (zero? (logand event char-meta))) (list 'meta) '())))))

    (define (event-basic-type event)
      ;; GNU Emacs's `event-basic-type' (`subr.el':1862): "Return the basic
      ;; type of the given event (all modifiers removed). The value is a
      ;; printing character (not upper case) or a symbol."
      ;;--------------------------------------------------------------
      (if (symbol? event)
          (car (event-symbol-elements event))
          (let* ((base (logand event (- char-alt 1)))
                 (uncontrolled (if (< base 32) (logior base 64) base)))
            ;; "There are some numbers that are invalid characters and
            ;; cause `downcase' to get an error."
            (guard (e (#t (integer->char uncontrolled)))
              (char-downcase (integer->char uncontrolled))))))

    (define (apply-modifiers modifiers base)
      ;; GNU Emacs's `apply_modifiers_uncached' (`keyboard.c':7479):
      ;; "Return a symbol whose name is the modifier prefixes for
      ;; MODIFIERS prepended to the string BASE". The prefixes are the
      ;; single letters, in the C's own order - `A- C- H- M- S- s-'.
      ;;--------------------------------------------------------------
      (let* ((name (symbol->string base))
             (prefixes (string-append
                        (if (not (zero? (logand modifiers char-alt))) "A-" "")
                        (if (not (zero? (logand modifiers char-ctl))) "C-" "")
                        (if (not (zero? (logand modifiers char-hyper))) "H-" "")
                        (if (not (zero? (logand modifiers char-meta))) "M-" "")
                        (if (not (zero? (logand modifiers char-shift))) "S-" "")
                        (if (not (zero? (logand modifiers char-super))) "s-" ""))))
        (string->symbol (string-append prefixes name))))

    (define (event-convert-list event-desc)
      ;; GNU Emacs's `event-convert-list' (`keyboard.c':7832): "Convert the
      ;; event description list EVENT-DESC to an event type. EVENT-DESC
      ;; should contain one base event type (a character or symbol) and
      ;; zero or more modifier names ... The base must be last."
      ;;--------------------------------------------------------------
      (let loop ((rest event-desc) (modifiers 0) (base #f))
        (if (null? rest)
            (cond
             ((not base) (error "Invalid base event"))
             (else
              ;; "Let the symbol A refer to the character A." The C's
              ;; `base' is a *character*, and a character in Elisp is an
              ;; integer, so a description written with a Scheme
              ;; character - `(control #\x)' - is the C's
              ;; `(control ?x)' and is made one here. Without this the
              ;; character fell past both branches below and the whole
              ;; list was rejected as having no base.
              (let ((base (cond
                           ((char? base) (char->integer base))
                           ((and (symbol? base)
                                 (= 1 (string-length (symbol->string base))))
                            (char->integer (string-ref (symbol->string base) 0)))
                           (else base))))
                (cond
                 ((integer? base)
                  ;; "Turn (shift a) into A", then "Turn (control a) into
                  ;; C-a".
                  (let* ((modifiers
                          (if (and (not (zero? (logand modifiers char-shift)))
                                   (>= base (char->integer #\a))
                                   (<= base (char->integer #\z)))
                              (begin (set! base (- base (- (char->integer #\a)
                                                           (char->integer #\A))))
                                     (logand modifiers (lognot char-shift)))
                              modifiers)))
                    (if (not (zero? (logand modifiers char-ctl)))
                        (logior (logand modifiers (lognot char-ctl))
                                (make-ctrl-char base))
                        (logior modifiers base))))
                 ((symbol? base) (apply-modifiers modifiers base))
                 (else (error "Invalid base event"))))))
            (let* ((elt (car rest))
                   (this (if (and (symbol? elt) (pair? (cdr rest)))
                             (parse-solitary-modifier elt)
                             #f)))
              (cond (this (loop (cdr rest) (logior modifiers this) base))
                    (base (error "Two bases given in one event"))
                    (else (loop (cdr rest) modifiers elt)))))))

    (define (kbd keys)
      ;; GNU Emacs's `kbd': "Convert KEYS to the internal Emacs key
      ;; representation" - a *vector of events*, which is what a key is.
      ;; `(kbd "C-s")` is `#(19)`, `(kbd "M-<")` is `#(134217788)`,
      ;; `(kbd "C-x C-c")` is `#(24 3)` and `(kbd "<up>")` is `#(up)`.
      ;;
      ;; Emacs's is `read-kbd-macro', which parses the description with the
      ;; reader a keyboard macro is read with; this parses the same words
      ;; and builds each one with `event-convert-list', the C's way from a
      ;; description to an event.
      ;;--------------------------------------------------------------
      (list->vector
       (let loop ((rest keys) (keys '()))
        (if (string=? rest "")
            (reverse keys)
            (let* ((pos (let scan ((i 0))
                          (cond ((>= i (string-length rest)) #f)
                                ((char=? (string-ref rest i) #\space)
                                 (scan (+ i 1)))
                                (else i))))
                   (word-beg (or pos (string-length rest)))
                   (word-end (key-parse-word rest word-beg))
                   (word (substring rest word-beg word-end))
                   ;; A word can be more than one event - `M-12' is two
                   ;; - so `parse-key' answers a *list* and it is spliced,
                   ;; which is what `vconcat' does with `key-parse''s
                   ;; `key' (`subr.el:1268').
                   (evs (parse-key word)))
              (loop (substring rest (min word-end (string-length rest)))
                    (append (reverse evs) keys)))))))

    ))
