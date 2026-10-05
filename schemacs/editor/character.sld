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
   parse-modifiers-uncached event-symbol-elements
   event-modifiers event-basic-type apply-modifiers event-convert-list
   key-path->event
   kbd
   *tab-width*
   char-width
   char-width-default
   sanitize-char-width)

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
    ;; The result is this tree's key path: a list of keys, each either a
    ;; character, a string naming a keyboard key, or a list of modifier
    ;; symbols followed by the character or string - so `(kbd "C-x C-f")'
    ;; is `((ctrl #\x) (ctrl #\f))' and `(kbd "C-/")' is `((ctrl #\/))'.
    ;; `define-key' takes it and `keymap-index' reads it, so a binding
    ;; written with `kbd' is written the way a front end is expected to
    ;; deliver.
    ;;----------------------------------------------------------------

    (define *key-parse-modifiers*
      ;; The modifier prefixes `key-parse' takes, with the modifier each
      ;; names. The letters are Emacs's (`keyboard.c':7390-7414):
      ;; `S-' is *shift* and `s-' is super, which this table had the other
      ;; way round - so `(kbd "S-<up>")' named a super key where Emacs
      ;; names a shifted one.
      '((#\A . alt)
        (#\C . ctrl)
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

    (define (parse-key word)
      ;; One word of a `kbd' string as one key of a key path: the chord
      ;; `(modifiers... character-or-string)'.
      ;;--------------------------------------------------------------
      (if (and (> (string-length word) 2)
               (char=? (string-ref word 0) #\<)
               (char=? (string-ref word (- (string-length word) 1)) #\>))
          ;; `<up>' names a keyboard key, which is how a named key is
          ;; written in a key path here - and Emacs's is a symbol in the
          ;; vector, `up', the same thing as the string this tree uses.
          (string->symbol (substring word 1 (- (string-length word) 1)))
          (let* ((mods-and-key (key-parse-modifiers word))
                 (mods (car mods-and-key))
                 (named (cdr mods-and-key))
                 ;; the modifiers are off; now a `<...>` names a keyboard
                 ;; key, which is why this is done after them
                 (named (if (and (> (string-length named) 2)
                                 (char=? (string-ref named 0) #\<)
                                 (char=? (string-ref named
                                                    (- (string-length named) 1))
                                 #\>))
                            (substring named 1 (- (string-length named) 1))
                            named))
                 (found (assoc named *key-parse-named*))
                 (char (if found (cdr found) (and (= (string-length named) 1)
                                                 (string-ref named 0)))))
            (cond
             ;; The word as the *event* it names: the modifiers and the
             ;; base, through `event-convert-list' - which is the C's way
             ;; from a description to an event, and the reason `C-s' comes
             ;; out as 19 and `M-<' as 134217788 rather than as a list.
             (char (event-convert-list (append mods (list (char->integer char)))))
             (named (event-convert-list
                     (append mods (list (string->symbol named)))))
             (else #f)))))

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
              ;; "Let the symbol A refer to the character A."
              (let ((base (if (and (symbol? base)
                                   (= 1 (string-length (symbol->string base))))
                              (char->integer (string-ref (symbol->string base) 0))
                              base)))
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

    (define (key-path->event path)
      ;; A one-key *path* as the *event* it names: `(ctrl #\s)' is 19,
      ;; `(meta #\<)' is 134217788, `("up")' is the symbol `up'.
      ;;
      ;; It is the seam between the two forms while the tree is being
      ;; moved onto events: a display's decoder builds the path - that is
      ;; what its key table holds - and this is `event-convert-list', the
      ;; C's way from a description to an event, applied to it.
      ;;--------------------------------------------------------------
      (event-convert-list
       (map (lambda (x)
              (cond ((char? x) (char->integer x))
                    ((string? x) (string->symbol x))
                    ((eq? x 'ctrl) 'control)
                    (else x)))
            path)))

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
                   (key (parse-key word)))
              (loop (substring rest (min word-end (string-length rest)))
                    (cons key keys)))))))

    ))
