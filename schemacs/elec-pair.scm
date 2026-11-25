(define-library (schemacs elec-pair)
  ;; This library mirrors GNU Emacs's `lisp/elec-pair.el': automatic
  ;; insertion of matching delimiter pairs and the balance-preserving
  ;; decisions that go with it. It is ported whole - the two pair alists,
  ;; `electric-pair-syntax-info', the balance walk, the post-self-insert
  ;; hook, the map's filtered DEL, `electric-pair-mode' and
  ;; `electric-pair-local-mode'.
  ;;
  ;; **Optional arguments and `let'.** Emacs's functions take integers for
  ;; characters; this tree's readers (`char-after', `char-before') answer
  ;; Scheme characters and `last-command-event' is an integer. Every
  ;; character that crosses between the two is put through `%char-code'
  ;; here, and the pair alists hold *code points* - Emacs's own
  ;; representation. That is why a pair is compared with `eqv?' and not
  ;; `char=?'.
  ;;
  ;; **Two definitions are placed later than Emacs's file order**, because
  ;; their `defcustom' default is a procedure this library defines further
  ;; down and a Scheme `define-custom' evaluates its default when it is
  ;; declared: `*electric-pair-skip-self*' and
  ;; `*electric-pair-inhibit-predicate*' come after the functions they
  ;; name. `electric-pair-skip-whitespace-function', a `defvar-local', is
  ;; placed after `electric-pair--skip-whitespace' for the same reason.
  ;;
  ;; **Not carried**, each with what it would need:
  ;;
  ;;  * `electric-layout-mode' - the third of electric.el's modes; its
  ;;    variable `electric-layout-allow-duplicate-newlines' is carried in
  ;;    `electric.scm' and `electric-pair--insert' would bind it, but a
  ;;    plain variable cannot be `let'-bound here and nothing else reads
  ;;    it. Named at the binding site.
  ;;  * the `blink-matching-paren' machinery is **in `paren.scm'**
  ;;    (`blink-matching-open' and the `post-self-insert-hook' entry) as
  ;;    of 2026-11-25; this library binds the option around the insert
  ;;    exactly as Emacs does, so the pair's closer does not blink and
  ;;    the next typed paren does.
  ;;  * `analyze-text-conversion' (`simple.el'), the caller of
  ;;    `electric-pair-analyze-conversion'. The function is carried whole;
  ;;    there are no text-conversion events here for it to be called from.
  ;;  * the `input-decode-map' half of `electric-pair-mode-map' beyond the
  ;;    DEL filter: Emacs binds only that one key, which is here.

  (import
    (scheme base)
    (scheme char)
    (only (guile) assq catch memq throw)
    (only (srfi srfi-1) last-pair)
    (only (schemacs core pcase) pcase)
    (only (schemacs core easy-mmode) define-minor-mode)
    (only (schemacs custom) define-custom)
    (only (schemacs character) kbd)
    (only (schemacs command)
          define-command *last-command-event* current-prefix-arg
          prefix-numeric-value uarg->integer)
    (only (schemacs electric)
          electric--after-char-pos *electric-quote-chars*
          electric-layout-allow-duplicate-newlines)
    (only (schemacs buffer)
          current-buffer buffer-local-value set-buffer-local-value!
          local-variable-p kill-local-variable call-with-buffer-local
          buffer-overwrite-mode major-mode)
    (only (schemacs data) default-value set-default)
    (only (schemacs editfns)
          point point-min point-max goto-char char-after char-before
          following-char delete-region insert bobp save-excursion pos-bol
          field-beginning field-end with-restriction)
    (only (schemacs cmds)
          self-insert-command delete-char forward-char
          *post-self-insert-hook*)
    (only (schemacs simple)
          backward-delete-char-untabify use-region-p mark insert-newline
          *self-insert-uses-region-functions* *blink-matching-paren*
          atomic-change-group)
    (only (schemacs syntax)
          char-syntax matching-paren scan-sexps scan-error?
          scan-error-message scan-error-end syntax-ppss
          syntax-ppss-flush-cache parse-partial-sexp with-syntax-table
          skip-syntax-forward skip-syntax-backward skip-chars-forward
          skip-chars-backward forward-comment)
    (only (schemacs search) looking-back string-match)
    (only (schemacs fns) proper-list-p nth rassq)
    (only (schemacs subr) add-hook remove-hook)
    (only (schemacs keymap) define-key make-sparse-keymap)
    (only (schemacs progmodes prog-mode) prog-mode-syntax-table))

  (export
   *electric-pair-pairs*
   *electric-pair-text-pairs*
   *electric-pair-skip-self* *electric-pair-inhibit-predicate*
   electric-pair-inhibit-predicate-value
   *electric-pair-preserve-balance* *electric-pair-delete-adjacent-pairs*
   *electric-pair-open-newline-between-pairs* *electric-pair-skip-whitespace*
   *electric-pair-skip-whitespace-chars*
   electric-pair-skip-whitespace-function
   set!electric-pair-skip-whitespace-function
   electric-pair-text-syntax-table electric-pair-string-bound-function
   electric-pair-field-search-size
   electric-pair-analyze-conversion electric-pair--skip-whitespace
   electric-pair-conservative-inhibit electric-pair-syntax-info
   electric-pair--insert electric-pair--syntax-ppss
   electric-pair--balance-info electric-pair--unbalanced-strings-p
   electric-pair--inside-string-p
   electric-pair-inhibit-if-helps-balance electric-pair-skip-if-helps-balance
   electric-pair-default-skip-self electric-pair-default-inhibit
   electric-pair-post-self-insert-function electric--pair-psif-1
   electric-pair-open-newline-between-pairs-psif
   electric-pair-will-use-region electric-pair-delete-pair
   electric-pair-mode-map electric-pair-mode electric-pair-mode-hook
   electric-pair-mode-value electric-pair-local-mode
   electric-pair-local-mode-hook)

  (begin

    ;;----------------------------------------------------------------
    ;; Character representation at this library's boundary
    ;;----------------------------------------------------------------

    (define (%char-code object)
      ;; A character or a code point as a code point; #f stays #f.
      ;; Emacs characters *are* integers, and every comparison below is
      ;; Emacs's `eq' of one against another.
      ;;--------------------------------------------------------------
      (cond ((char? object) (char->integer object))
            ((integer? object) object)
            (else #f)))

    (define (%char= a b)
      ;; Emacs's `(eq A B)' for two characters, where either may be nil.
      ;;--------------------------------------------------------------
      (let ((x (%char-code a)) (y (%char-code b)))
        (and x y (= x y))))

    (define (%chars-string chars)
      ;; `(apply #'string CHARS)': the characters may be Scheme
      ;; characters or code points.
      ;;--------------------------------------------------------------
      (list->string
       (map (lambda (c) (if (char? c) c (integer->char c))) chars)))

    (define (%normalize-pair pair)
      ;; A pair alist entry with its character halves as code points.
      ;; A string pair - `(STRING . STRING)' or `(STRING STRING SPC)' -
      ;; is left alone.
      ;;--------------------------------------------------------------
      (cond ((string? (car pair)) pair)
            ((pair? pair) (cons (%char-code (car pair))
                                (%char-code (cdr pair))))
            (else pair)))

    ;;----------------------------------------------------------------
    ;; Electric pairing
    ;;----------------------------------------------------------------

    (define-custom *electric-pair-pairs*
      (let ((q (*electric-quote-chars*)))
        (list (cons (char->integer #\") (char->integer #\"))
              (cons (char->integer (list-ref q 0))
                    (char->integer (list-ref q 1)))
              (cons (char->integer (list-ref q 2))
                    (char->integer (list-ref q 3)))))
      "Alist of pairs that should be used regardless of major mode.

Pairs of delimiters in this list are a fallback in case they have
no syntax relevant to `electric-pair-mode' in the mode's syntax
table.

Each list element should be in one of these forms:
 (CHAR . CHAR)
Where CHAR is character to be used as pair.

 (STRING STRING SPC)
Where STRING is a string to be used as pair and SPC a non-nil value
which specifies to insert an extra space after first STRING.

 (STRING . STRING)
This is similar to (STRING STRING SPC) form, except that SPC (space) is
ignored and will not be inserted.

In both string pairs forms, the first string pair must be a regular
expression.

Unlike character pairs, string pairs do not support
inserting pairs in regions and cannot be deleted with
`electric-pair-delete-pair', thus string pairs should be used only for
multi-character pairs.

See also the variable `electric-pair-text-pairs'."
      :version "24.1"
      :group 'electricity
      :type '(repeat
              (choice (cons :tag "Characters" character character)
                      (cons :tag "Strings" string string)
                      (list :tag "Strings, plus insert SPC after first string"
                            string string boolean))))

    (define-custom *electric-pair-text-pairs*
      (let ((q (*electric-quote-chars*)))
        (list (cons (char->integer #\") (char->integer #\"))
              (cons (char->integer (list-ref q 0))
                    (char->integer (list-ref q 1)))
              (cons (char->integer (list-ref q 2))
                    (char->integer (list-ref q 3)))))
      "Alist of pairs that should always be used in comments and strings.

Pairs of delimiters in this list are a fallback in case they have
no syntax relevant to `electric-pair-mode' in the syntax table
defined in `electric-pair-text-syntax-table'.

Each list element should be in one of these forms:
 (CHAR . CHAR)
Where CHAR is character to be used as pair.

 (STRING STRING SPC)
Where STRING is a string to be used as pair and SPC a non-nil value
which specifies to insert an extra space after first STRING.

 (STRING . STRING)
This is similar to (STRING STRING SPC) form, except that SPC (space) is
ignored and will not be inserted.

In both string pairs forms, the first string pair must be a regular
expression.

Unlike character pairs, string pairs do not support
inserting pairs in regions and cannot be deleted with
`electric-pair-delete-pair', thus string pairs should be used only for
multi-character pairs.

See also the variable `electric-pair-pairs'."
      :version "24.4"
      :group 'electricity
      :type '(repeat
              (choice (cons :tag "Characters" character character)
                      (cons :tag "Strings" string string)
                      (list :tag "Strings, plus insert SPC after first string"
                            string string boolean))))

    (define-custom *electric-pair-preserve-balance* #t
      "Whether to keep matching delimiters balanced.
When non-nil, typing a delimiter inserts only this character if there is
a unpaired matching delimiter later (if the latter is a closing
delimiter) or earlier (if the latter is a opening delimiter) in the
buffer.  When nil, inserting a delimiter disregards unpaired matching
delimiters.

Whether this variable takes effect depends on the variables
`electric-pair-inhibit-predicate' and `electric-pair-skip-self', which
check the value of this variable before delegating to other predicates
responsible for making decisions on whether to pair/skip some characters
based on the actual state of the buffer's delimiters.  In addition, this
variable has no effect if there is an active region."
      :version "24.4"
      :group 'electricity
      :type 'boolean)

    (define-custom *electric-pair-delete-adjacent-pairs* #t
      "Whether to automatically delete a matching delimiter.
If non-nil, then when an opening delimiter immediately precedes a
matching closing delimiter and point is between them, typing DEL (the
backspace key) deletes both delimiters.  If nil, only the opening
delimiter is deleted.

The value of this variable can also be a function of no arguments, in
which case that function's return value is considered instead."
      :version "24.4"
      :group 'electricity
      :type '(choice
              (const :tag "Yes" t)
              (const :tag "No" nil)
              function))

    (define-custom *electric-pair-open-newline-between-pairs* #t
      "Whether to insert an extra newline between matching delimiters.
If non-nil, then when an opening delimiter immediately precedes a
matching closing delimiter and point is between them, typing a newline
automatically inserts an extra newline after point.  If nil, just one
newline is inserted before point.

The value of this variable can also be a function of no arguments, in
which case that function's return value is considered instead."
      :version "24.4"
      :group 'electricity
      :type '(choice
              (const :tag "Yes" t)
              (const :tag "No" nil)
              function))

    (define-custom *electric-pair-skip-whitespace* #t
      "Whether typing a closing delimiter moves point over whitespace.
If non-nil and point is separated from a closing delimiter only by
whitespace, then typing a closing delimiter of the same type does not
insert that character but instead moves point to immediately after the
already present closing delimiter.  If the value of this variable is set
to the symbol `chomp', then the whitespace moved over is deleted.  If the
value is nil, typing a closing delimiter simply inserts it at point.

The specific kind of whitespace skipped is given by the variable
`electric-pair-skip-whitespace-chars'.

The value of this variable can also be a function of no arguments, in
which case that function's return value is considered instead."
      :version "24.4"
      :group 'electricity
      :type '(choice
              (const :tag "Yes, jump over whitespace" t)
              (const :tag "Yes, and delete whitespace" chomp)
              (const :tag "No, no whitespace skipping" nil)
              function))

    (define-custom *electric-pair-skip-whitespace-chars*
      (list #\tab #\space #\newline)
      "Whitespace characters considered by `electric-pair-skip-whitespace'."
      :version "24.4"
      :group 'electricity
      :type '(choice (set (const :tag "Space" #\space)
                          (const :tag "Tab" #\tab)
                          (const :tag "Newline" #\newline))
                     (repeat (character :value " "))))

    (define (electric-pair-analyze-conversion string)
      "Delete delimiters enclosing the STRING deleted by an input method.
If the last character of STRING is an electric pair character,
and the character after point is too, then delete that other
character.  Called by `analyze-text-conversion'."
      (let* ((prev (string-ref string (- (string-length string) 1)))
             (next (char-after))
             (syntax-info (electric-pair-syntax-info prev))
             (syntax (car syntax-info))
             (pair (cadr syntax-info)))
        (when (and next pair
                   (memq syntax (list #\( #\" #\$))
                   (%char= pair next))
          (delete-char 1))))

    (define (electric-pair--skip-whitespace)
      "Move point forward over whitespace.
But do not move point if doing so crosses comment or string boundaries."
      (let ((saved (point))
            (string-or-comment (nth 8 (syntax-ppss))))
        (skip-chars-forward
         (%chars-string (*electric-pair-skip-whitespace-chars*)))
        (unless (eq? string-or-comment (nth 8 (syntax-ppss)))
          (goto-char saved))))

    ;; **Placed here rather than before `electric-pair--skip-whitespace'
    ;; as in Emacs's file**: the default is the procedure above, and a
    ;; buffer-local's fallback is a value read when the accessor is
    ;; called, so it must exist when this is defined. A `defvar-local',
    ;; so the buffer's slot is the value and this pair is its reader and
    ;; writer (`buffer.scm`'s `buffer-local-value` convention).
    (define (electric-pair-skip-whitespace-function)
      "Function to use to move point forward over whitespace.
Before attempting a skip, if `electric-pair-skip-whitespace' is
non-nil, this function is called.  It moves point to a new buffer
position, presumably skipping only whitespace in between."
      (buffer-local-value (current-buffer)
                          'electric-pair-skip-whitespace-function
                          electric-pair--skip-whitespace))

    (define (set!electric-pair-skip-whitespace-function value)
      (set-buffer-local-value! (current-buffer)
                               'electric-pair-skip-whitespace-function value))

    (define electric-pair-text-syntax-table prog-mode-syntax-table)
    ;; ^ GNU Emacs's `electric-pair-text-syntax-table'. A plain `defvar',
    ;; and the value is a syntax table.

    (define (electric-pair-conservative-inhibit char)
      (or
       ;; I find it more often preferable not to pair when the
       ;; same char is next.
       (%char= char (char-after))
       ;; Don't pair up when we insert the second of "" or of ((.
       (and (%char= char (char-before))
            (%char= char (char-before (- (point) 1))))
       ;; I also find it often preferable not to pair next to a word.
       ;; `following-char` is #f at the end of the buffer here where
       ;; Emacs's is the integer 0; `char-syntax` of #f would raise.
       (let ((char (following-char)))
         (and char
              (let ((syntax (char-syntax char)))
                (and syntax (char=? syntax #\w)))))))

    (define-syntax electric-pair--with-syntax
      (syntax-rules ()
        ((_ string-or-comment body ...)
         (electric-pair--with-syntax-1
          string-or-comment (lambda () body ...)))))

    (define (electric-pair--with-syntax-1 string-or-comment body-fun)
      (if (not string-or-comment)
          (body-fun)
          ;; Here we assume that the `syntax-ppss' cache has already been
          ;; filled past `string-or-comment' with data corresponding to
          ;; the "normal" syntax (this should be the case because
          ;; STRING-OR-COMMENT was returned in the `nth 8' of
          ;; `syntax-ppss').
          (begin
            (syntax-ppss-flush-cache string-or-comment)
            (call-with-buffer-local
             'syntax-propertize-function #f
             (lambda ()
               (dynamic-wind
                (lambda () #f)
                (lambda ()
                  (with-syntax-table electric-pair-text-syntax-table
                    body-fun))
                (lambda ()
                  (syntax-ppss-flush-cache string-or-comment))))))))

    (define (electric-pair-syntax-info command-event)
      "Calculate a list (SYNTAX PAIR UNCONDITIONAL STRING-OR-COMMENT-START).

SYNTAX is COMMAND-EVENT's syntax character.  PAIR is COMMAND-EVENT's
pair.  UNCONDITIONAL indicates that the variables `electric-pair-pairs'
or `electric-pair-text-pairs' were used to look up syntax.
STRING-OR-COMMENT-START indicates that point is inside a comment or
string."
      (let* ((command-event (%char-code command-event))
             (pre-string-or-comment
              (or (bobp)
                  (nth 8 (save-excursion
                           (syntax-ppss (- (point) 1))))))
             (post-string-or-comment (nth 8 (syntax-ppss (point))))
             (string-or-comment (and post-string-or-comment
                                     pre-string-or-comment))
             (table-syntax-and-pair
              (electric-pair--with-syntax
               string-or-comment
               (list (char-syntax command-event)
                     (or (matching-paren command-event)
                         command-event))))
             (fallback
              (map %normalize-pair
                   (if string-or-comment
                       (append (*electric-pair-text-pairs*)
                               (*electric-pair-pairs*))
                       (*electric-pair-pairs*))))
             (direct (assq command-event fallback))
             (reverse (rassq command-event fallback)))
        (cond
         ((let loop ((pairs fallback))
            (cond
             ((null? pairs) #f)
             ((and (string? (car (car pairs)))
                   (looking-back (car (car pairs)) (pos-bol)))
              (list
               'str
               ;; Get pair ender
               (if (proper-list-p (car pairs))
                   (nth 1 (car pairs))
                   (cdr (car pairs)))
               #f
               ;; Check if pairs have to insert a space after
               ;; first pair was inserted.
               (if (proper-list-p (car pairs))
                   (nth 2 (car pairs))
                   #f)))
             (else (loop (cdr pairs))))))
         ((memq (car table-syntax-and-pair)
                (list #\" #\( #\) #\$))
          (append table-syntax-and-pair
                  (list #f string-or-comment)))
         (direct
          (if (%char= (car direct) (cdr direct))
              (list #\" command-event #t string-or-comment)
              (list #\( (%char-code (cdr direct)) #t string-or-comment)))
         (reverse
          (list #\) (%char-code (car reverse)) #t string-or-comment))
         (else #f))))

    (define (electric-pair--insert char times)
      ;; GNU Emacs's `electric-pair--insert'. `last-command-event' is a
      ;; parameter and this tree's SELF-INSERT-COMMAND takes the character
      ;; it inserts as an argument, so both are handed over.
      ;;
      ;; **`(let ((electric-pair-mode nil)) ...)' is a buffer-local
      ;; binding here** (`call-with-buffer-local'): a global minor
      ;; mode's value lives in the default store and has no Scheme `let'.
      ;; Without it the post-self-insert hook would see the inserted
      ;; closer and treat it as a typed key.
      ;;
      ;; `electric-layout-allow-duplicate-newlines' is bound in Emacs and
      ;; cannot be here - it is a plain variable, not a parameter, and
      ;; `electric-layout-mode' (its only other reader) is not ported.
      ;;--------------------------------------------------------------
      (call-with-buffer-local
       'electric-pair-mode #f
       (lambda ()
         (parameterize ((*last-command-event* (%char-code char))
                        (*blink-matching-paren* #f))
           (self-insert-command times (%char-code char))))))

    (define (electric-pair--syntax-ppss . rest)
      "Like `syntax-ppss', but maybe fall back to `parse-partial-sexp'.

WHERE is a list defaulting to \\='(string comment) and indicates
when to fall back to `parse-partial-sexp'."
      (let* ((pos (if (pair? rest) (car rest) #f))
             (pos (or pos (point)))
             (where (if (and (pair? rest) (pair? (cdr rest)))
                        (cadr rest)
                        #f))
             (where (or where (list 'string 'comment)))
             (quick-ppss (syntax-ppss pos))
             (in-string (and (nth 3 quick-ppss) (memq 'string where)))
             (in-comment (and (nth 4 quick-ppss) (memq 'comment where)))
             (s-or-c-start
              (cond (in-string (+ (nth 8 quick-ppss) 1))
                    (in-comment
                     (goto-char (nth 8 quick-ppss))
                     (forward-comment (- (point-max)))
                     (skip-syntax-forward " >!")
                     (point))
                    (else #f))))
        (if s-or-c-start
            (electric-pair--with-syntax-1
             s-or-c-start
             (lambda () (parse-partial-sexp s-or-c-start pos)))
            ;; HACK! cc-mode apparently has some `syntax-ppss' bugs
            (if (memq (major-mode) '(c-mode c++ mode))
                (parse-partial-sexp (point-min) pos)
                quick-ppss))))

    ;; Balancing means controlling pairing and skipping of delimiters
    ;; so that, if possible, the buffer ends up at least as balanced as
    ;; before, if not more.  The algorithm is slightly complex because
    ;; some situations like "()))" need pairing to occur at the end but
    ;; not at the beginning.  Balancing should also happen independently
    ;; for different types of delimiter, so that having your {}'s
    ;; unbalanced doesn't keep `electric-pair-mode' from balancing your
    ;; ()'s and your []'s.
    (define (electric-pair--balance-info direction string-or-comment)
      "Examine lists forward or backward according to DIRECTION's sign.

STRING-OR-COMMENT is the position of the start of the comment/string
in which we are, if applicable.

Return a cons of two descriptions (MATCHED-P . PAIR) for the
innermost and outermost lists that enclose point.  The outermost
list enclosing point is either the first top-level or first
mismatched list found by listing up.

If the outermost list is matched, don't rely on its PAIR.
If point is not enclosed by any lists, return ((t) . (t))."
      (let* ((innermost #f)
             (outermost #f)
             (at-top-level-or-equivalent-fn
              ;; Called when `scan-sexps' ran perfectly, when it found
              ;; a parenthesis pointing in the direction of travel.
              ;; Also when travel started inside a comment and exited it.
              (lambda ()
                (set! outermost (list #t))
                (unless innermost
                  (set! innermost (list #t)))))
             (ended-prematurely-fn
              ;; Called when `scan-sexps' crashed against a parenthesis
              ;; pointing opposite the direction of travel.  After
              ;; traversing that character, the idea is to travel one sexp
              ;; in the opposite direction looking for a matching
              ;; delimiter.
              (lambda ()
                (let* ((pos (point))
                       (matched
                        (save-excursion
                          (cond
                           ((< direction 0)
                            (guard (e ((scan-error? e) #f))
                              (%char=
                               (char-after pos)
                               (electric-pair--with-syntax-1
                                string-or-comment
                                (lambda ()
                                  (matching-paren
                                   (char-before
                                    (scan-sexps (point) 1))))))))
                           (else
                            ;; In this case, no need to use
                            ;; `scan-sexps', we can use some
                            ;; `electric-pair--syntax-ppss' in this
                            ;; case (which uses the quicker
                            ;; `syntax-ppss' in some cases)
                            (let* ((ppss (electric-pair--syntax-ppss
                                          (- (point) 1)))
                                   (stack (nth 9 ppss))
                                   (start (and (pair? stack)
                                               (car (last-pair stack))))
                                   (opener (and start (char-after start))))
                              (and start
                                   (%char=
                                    (char-before pos)
                                    (or (electric-pair--with-syntax-1
                                         string-or-comment
                                         (lambda ()
                                           (matching-paren opener)))
                                        opener))))))))
                       (actual-pair (if (> direction 0)
                                        (char-before (point))
                                        (char-after (point)))))
                  (unless innermost
                    (set! innermost
                          (cons matched (%char-code actual-pair))))
                  (unless matched
                    (set! outermost
                          (cons matched (%char-code actual-pair))))))))
        (save-excursion
          (let loop ()
            (unless outermost
              (guard (err
                      ((scan-error? err)
                       (cond
                        ((or
                          ;; Some error happened and it is not of the "ended
                          ;; prematurely" kind...
                          (not (string-match "ends prematurely"
                                             (scan-error-message err)))
                          ;; ... or we were in a comment and just came out
                          ;; of it.
                          (and string-or-comment
                               (not (nth 8 (syntax-ppss)))))
                         (at-top-level-or-equivalent-fn))
                        (else
                         ;; Exit the sexp.
                         (goto-char (scan-error-end err))
                         (ended-prematurely-fn)))))
                (electric-pair--with-syntax-1
                 string-or-comment
                 (lambda ()
                   (scan-sexps (point)
                               (if (> direction 0)
                                   (point-max)
                                   (- (point-max))))
                   (at-top-level-or-equivalent-fn))))
              (loop))))
        (cons innermost outermost)))

    (define electric-pair-string-bound-function point-max)
    ;; ^ GNU Emacs's `electric-pair-string-bound-function'. A plain
    ;; `defvar': a function of no arguments returning a buffer position.

    (define (electric-pair--unbalanced-strings-p char)
      "Return non-nil if there are unbalanced strings started by CHAR."
      (let* ((selector-ppss (syntax-ppss))
             (relevant-ppss
              (save-excursion
                (if (nth 4 selector-ppss)  ; comment
                    (electric-pair--syntax-ppss
                     (begin
                       (goto-char (nth 8 selector-ppss))
                       (forward-comment (point-max))
                       (skip-syntax-backward " >!")
                       (point)))
                    (syntax-ppss
                     (electric-pair-string-bound-function)))))
             (string-delim (nth 3 relevant-ppss)))
        (or (eq? #t string-delim)
            (%char= char string-delim))))

    (define (electric-pair--inside-string-p char)
      "Return non-nil if point is inside a string started by CHAR.

A comments text is parsed with `electric-pair-text-syntax-table'.
Also consider strings within comments, but not strings within
strings."
      ;; FIXME: could also consider strings within strings by examining
      ;; delimiters.
      (let ((ppss (electric-pair--syntax-ppss (point) '(comment))))
        (or (eq? #t (nth 3 ppss))
            (%char= char (nth 3 ppss)))))

    (define-syntax electric-pair--save-literal-point-excursion
      ;; FIXME: need this instead of `save-excursion' when functions in
      ;; BODY, such as `electric-pair-inhibit-if-helps-balance' and
      ;; `electric-pair-skip-if-helps-balance' modify and restore the
      ;; buffer in a way that modifies the marker used by `save-excursion'.
      (syntax-rules ()
        ((_ body ...)
         (let ((saved-point (point)))
           (dynamic-wind
            (lambda () #f)
            (lambda () body ...)
            (lambda () (goto-char saved-point)))))))

    (define (electric-pair-inhibit-if-helps-balance char)
      "Return non-nil if auto-pairing of CHAR unbalances delimiters.

Works by first removing the character from the buffer, then doing
some list calculations, finally restoring the situation as if nothing
happened."
      (pcase (electric-pair-syntax-info char)
        (`(,syntax ,pair ,_ ,s-or-c)
         (catch 'done
           (lambda ()
             ;; FIXME: modify+undo is *very* tricky business.  We used to
             ;; use `delete-char' followed by `insert', but this changed
             ;; the position some markers.  The real fix would be to
             ;; compute the result without having to modify the buffer at
             ;; all.
             (atomic-change-group
               ;; Don't use `delete-char'; that may modify the head of the
               ;; undo list.
               (delete-region
                (- (point) (prefix-numeric-value (current-prefix-arg)))
                (point))
               (throw
                'done
                (cond ((char=? syntax #\()
                       (let* ((pair-data
                               (electric-pair--balance-info 1 s-or-c))
                              (outermost (cdr pair-data)))
                         (cond ((car outermost) #f)
                               (else
                                (eqv? (cdr outermost) pair)))))
                      ((char=? syntax #\")
                       (electric-pair--unbalanced-strings-p char))
                      (else #f)))))
           (lambda (key . args)
             (and (pair? args) (car args)))))))

    (define (electric-pair-skip-if-helps-balance char)
      "Return non-nil if skipping CHAR preserves balance of delimiters.
Works by first removing the character from the buffer, then doing
some list calculations, finally restoring the situation as if nothing
happened."
      (let ((num (prefix-numeric-value (current-prefix-arg))))
        (pcase (electric-pair-syntax-info char)
          (`(,syntax ,pair ,_ ,s-or-c)
           (dynamic-wind
            (lambda () #f)
            (lambda ()
              (delete-char (- num))
              (cond ((char=? syntax #\))
                     (let* ((pair-data
                             (electric-pair--balance-info
                              (- num) s-or-c))
                            (innermost (car pair-data))
                            (outermost (cdr pair-data)))
                       (and
                        (cond ((car outermost)
                               (car innermost))
                              ((car innermost)
                               (not (eqv? (cdr outermost) pair)))))))
                    ((char=? syntax #\")
                     (electric-pair--inside-string-p char))
                    (else #f)))
            (lambda ()
              (insert (make-string
                       num
                       (if (char? char) char (integer->char char))))))))))

    (define (electric-pair-default-skip-self char)
      (if (*electric-pair-preserve-balance*)
          (electric-pair-skip-if-helps-balance char)
          #t))

    (define (electric-pair-default-inhibit char)
      (if (*electric-pair-preserve-balance*)
          (electric-pair-inhibit-if-helps-balance char)
          (electric-pair-conservative-inhibit char)))

    ;; **The two defcustoms whose default is a procedure defined above**;
    ;; in Emacs's file they come before these functions because a Lisp
    ;; `defcustom' can hold a quoted symbol. Here the default is the
    ;; procedure itself, so the declaration has to follow it (see the
    ;; library header).
    (define-custom *electric-pair-skip-self* electric-pair-default-skip-self
      "If non-nil, skip char instead of inserting a second closing paren.

When inserting a closing delimiter right before the same character, just
skip that character instead, so that, for example, consecutively
typing `(' and `)' results in \"()\" rather than \"())\".

This can be convenient for people who find it easier to type `)' than
\\[forward-char].

Can also be a function of one argument (the closing delimiter just
inserted), in which case that function's return value is considered
instead."
      :version "24.1"
      :group 'electricity
      :type '(choice
              (const :tag "Never skip" nil)
              (const :tag "Help balance" electric-pair-default-skip-self)
              (const :tag "Always skip" t)
              function))

    (define-custom *electric-pair-inhibit-predicate*
      electric-pair-default-inhibit
      "Predicate to prevent insertion of a matching pair.

The function is called with a single char (the opening delimiter just
inserted).  If it returns non-nil, then `electric-pair-mode' will not
insert a matching closing delimiter."
      :version "24.4"
      :group 'electricity
      :type '(choice
              (const :tag "Conservative" electric-pair-conservative-inhibit)
              (const :tag "Help balance" electric-pair-default-inhibit)
              (const :tag "Always pair" ignore)
              function))

    (define (electric-pair-inhibit-predicate-value)
      ;; Emacs's `electric-pair-inhibit-predicate' is a defcustom that a
      ;; major mode sets *buffer-locally* - `c-basic-common-init` sets
      ;; `c-electric-pair-inhibit-predicate` in every CC Mode buffer.
      ;; The parameter is the default; this is the buffer's value, in
      ;; `electric-pair-mode-value`'s shape above. Emacs's
      ;; `(default-value 'electric-pair-inhibit-predicate)` - what
      ;; `c-electric-pair-inhibit-predicate` falls back to - is the
      ;; parameter.
      ;;--------------------------------------------------------------
      (let ((buffer (current-buffer)))
        (if (and buffer
                 (local-variable-p 'electric-pair-inhibit-predicate buffer))
            (buffer-local-value buffer 'electric-pair-inhibit-predicate)
            (*electric-pair-inhibit-predicate*))))

    (define electric-pair-field-search-size #f)
    ;; ^ GNU Emacs's `electric-pair-field-search-size'. A plain `defvar':
    ;; nil or an integer, and nothing `let'-binds it.

    (define (electric-pair-post-self-insert-function)
      "Do main work for `electric-pair-mode'.
This function is added to `post-self-insert-hook' when
`electric-pair-mode' is enabled."
      ;; First, figure out whether to restrict the buffer (bug#50236)
      (if (or (not electric-pair-field-search-size)
              (use-region-p))
          (electric--pair-psif-1)
          (let* ((min (- (point) electric-pair-field-search-size))
                 (max (+ (point) electric-pair-field-search-size))
                 (beg (field-beginning #f #f (max (point-min) min)))
                 (end (field-end #f #f (min (point-max) max))))
            (with-restriction
                (if (= min beg) (point-min) beg)
                (if (= max end) (point-max) end)
              (electric--pair-psif-1)))))

    (define (electric--pair-psif-1)
      "Do main work for `electric-pair-post-self-insert-function.'

If the newly inserted character C has delimiter syntax, this
function may decide to insert additional paired delimiters, or
skip the insertion of the new character altogether by jumping
over an existing identical character, or do nothing.

The decision is taken by order of preference:

* According to `use-region-p'.  If this returns non-nil this
  function will unconditionally \"wrap\" the region in the
  corresponding delimiter for C;

* According to C alone, by looking C up in the tables
  `electric-pair-pairs' or `electric-pair-text-pairs' (which
  see);

* According to C's syntax and the syntactic state of the buffer
  (both as defined by the major mode's syntax table).  This is
  done by looking up the variables
 `electric-pair-inhibit-predicate', `electric-pair-skip-self'
  and `electric-pair-skip-whitespace' (which see)."
      (let* ((pos (and (electric-pair-mode-value)
                       (electric--after-char-pos)))
             (num (and pos
                       (prefix-numeric-value (current-prefix-arg))))
             (beg (and num (- pos num)))
             (skip-whitespace-info #f))
        (pcase (electric-pair-syntax-info (*last-command-event*))
          (`(,syntax ,pair ,unconditional ,space)
           (cond
            ((not pos) #f)
            ((= num 0) #f)
            ;; Wrap a pair around the active region.
            ;;
            ((and (memq syntax (list #\( #\) #\" #\$))
                  (use-region-p))
             ;; FIXME: To do this right, we'd need a
             ;; post-self-insert-function so we could add-function
             ;; around it and insert the closer after all the rest of
             ;; the hook has run.
             (if (or (char=? syntax #\")
                     (and (char=? syntax #\))
                          (>= (point) (mark)))
                     (and (not (char=? syntax #\)))
                          (>= (mark) (point))))
                 (save-excursion
                   (goto-char (mark))
                   (electric-pair--insert pair num))
                 (begin
                   (delete-region beg pos)
                   (electric-pair--insert pair num)
                   (goto-char (mark))
                   (electric-pair--insert (*last-command-event*) num))))
            ;; Backslash-escaped: no pairing, no skipping.
            ((save-excursion
               (goto-char beg)
               (not (even? (skip-syntax-backward "\\"))))
             (parameterize ((current-prefix-arg (- num 1)))
               (electric-pair-post-self-insert-function)))
            ;; Skip self.
            ((and (memq syntax (list #\) #\" #\$))
                  (and (or unconditional
                           (if (procedure? (*electric-pair-skip-self*))
                               (electric-pair--save-literal-point-excursion
                                 (goto-char pos)
                                 ((*electric-pair-skip-self*)
                                  (*last-command-event*)))
                               (*electric-pair-skip-self*)))
                       (save-excursion
                         (when (and
                                (not (and unconditional
                                          (char=? syntax #\")))
                                (begin
                                  (set! skip-whitespace-info
                                        (if (and
                                             (not
                                              (eq? (*electric-pair-skip-whitespace*)
                                                   'chomp))
                                             (procedure?
                                              (*electric-pair-skip-whitespace*)))
                                            ((*electric-pair-skip-whitespace*))
                                            (*electric-pair-skip-whitespace*)))
                                  skip-whitespace-info))
                           ((electric-pair-skip-whitespace-function)))
                         (%char= (char-after) (*last-command-event*)))))
             ;; This is too late: rather than insert&delete we'd want to
             ;; only skip (or insert in overwrite mode).  The difference is
             ;; in what goes in the undo-log and in the intermediate state
             ;; which might be visible to other post-self-insert-hook.
             ;; We'll just have to live with it for now.
             (when skip-whitespace-info
               ((electric-pair-skip-whitespace-function)))
             (delete-region beg (if (eq? skip-whitespace-info 'chomp)
                                    (point)
                                    pos))
             (forward-char num))
            ;; Insert matching pair.
            ;; String pairs
            ((and (eq? syntax 'str)
                  (not (buffer-overwrite-mode (current-buffer))))
             (if space (insert " "))
             (save-excursion
               (insert pair)))
            ;; Char pairs
            ((and (memq syntax (list #\( #\" #\$))
                  (not (buffer-overwrite-mode (current-buffer)))
                  (or unconditional
                      (not (electric-pair--save-literal-point-excursion
                             (goto-char pos)
                             ((electric-pair-inhibit-predicate-value)
                              (*last-command-event*))))))
             (save-excursion (electric-pair--insert pair num)))
            (else #f))))))

    (define (electric-pair-open-newline-between-pairs-psif)
      "Honor `electric-pair-open-newline-between-pairs'.
This function is added to `post-self-insert-hook' when
`electric-pair-mode' is enabled."
      (when (and (let ((value (*electric-pair-open-newline-between-pairs*)))
                   (if (procedure? value) (value) value))
                 (= (*last-command-event*) 10)
                 (< (+ (point-min) 1) (point) (point-max))
                 (%char=
                  (save-excursion
                    (skip-chars-backward "\t ")
                    (char-before
                     (- (point)
                        (prefix-numeric-value (current-prefix-arg)))))
                  (matching-paren (char-after))))
        (save-excursion (insert-newline 1 #t))))

    (define (electric-pair-will-use-region)
      (and (use-region-p)
           (memq (car (electric-pair-syntax-info (*last-command-event*)))
                 (list #\( #\) #\" #\$))))

    (define-command (electric-pair-delete-pair arg killp)
      "When between adjacent paired delimiters, delete both of them.
ARG and KILLP are passed directly to
`backward-delete-char-untabify', which see."
      (interactive "*p\nP")
      (delete-char arg)
      (backward-delete-char-untabify arg killp))

    (define electric-pair-mode-map
      (let ((map (make-sparse-keymap)))
        (define-key
         map (kbd "DEL")
         (list 'menu-item "" electric-pair-delete-pair
               ':filter
               (lambda (cmd)
                 (let* ((prev (char-before))
                        (next (char-after))
                        (syntax-info (and prev
                                          (electric-pair-syntax-info prev)))
                        (syntax (and syntax-info (car syntax-info)))
                        (pair (and syntax-info (cadr syntax-info))))
                   (and next pair
                        (memq syntax (list #\( #\" #\$))
                        (%char= pair next)
                        (let ((value (*electric-pair-delete-adjacent-pairs*)))
                          (if (procedure? value) (value) value))
                        cmd)))))
        map))
    ;; ^ GNU Emacs's `electric-pair-mode-map'. Its one binding is a
    ;; `menu-item' with a `:filter', and the keymap lookup applies the
    ;; filter on every lookup exactly as `access_keymap_1` does - so the
    ;; DEL pair deletion falls through to the global `backward-delete-
    ;; char-untabify` when the filter answers nil. A filter here is a
    ;; *procedure*, since a Scheme lambda in the item is evaluated when
    ;; the map is made.

    (define (electric-pair-mode-value)
      ;; The value of `electric-pair-mode' in the current buffer: a
      ;; buffer-local binding wins over the global default, which is what
      ;; Emacs's special variable reads.
      ;;--------------------------------------------------------------
      (let ((buffer (current-buffer)))
        (if (and buffer
                 (local-variable-p 'electric-pair-mode buffer))
            (buffer-local-value buffer 'electric-pair-mode #f)
            (default-value 'electric-pair-mode #f))))

    (define-minor-mode electric-pair-mode
      "Toggle automatic pairing of delimiters (Electric Pair mode).

Electric Pair mode is a global minor mode.  When enabled, typing an
opening delimiter (parenthesis, bracket, etc.) automatically inserts the
corresponding closing delimiter.  If the region is active, the
delimiters are inserted around the region instead.

To toggle the mode only in the current buffer, use
`electric-pair-local-mode'."
      :global #t
      :variable (lambda () (electric-pair-mode-value))
                (lambda (value) (set-default 'electric-pair-mode value))
      (if (electric-pair-mode-value)
          (begin
            (add-hook *post-self-insert-hook*
                      electric-pair-post-self-insert-function
                      ;; Prioritize this to kick in after
                      ;; `electric-layout-post-self-insert-function': that
                      ;; considerably simplifies interoperation when
                      ;; `electric-pair-mode', `electric-layout-mode' and
                      ;; `electric-indent-mode' are used together.
                      ;; Use `vc-region-history' on these lines for more
                      ;; info.
                      50)
            (add-hook *post-self-insert-hook*
                      electric-pair-open-newline-between-pairs-psif
                      50)
            (add-hook *self-insert-uses-region-functions*
                      electric-pair-will-use-region))
          (begin
            (remove-hook *post-self-insert-hook*
                         electric-pair-post-self-insert-function)
            (remove-hook *post-self-insert-hook*
                         electric-pair-open-newline-between-pairs-psif)
            (remove-hook *self-insert-uses-region-functions*
                         electric-pair-will-use-region))))

    (define-minor-mode electric-pair-local-mode
      "Toggle `electric-pair-mode' only in this buffer."
      :variable (lambda () (electric-pair-mode-value))
                (lambda (value)
                  (set-buffer-local-value! (current-buffer)
                                           'electric-pair-mode
                                           value))
      (cond
       ((eq? (electric-pair-mode-value)
             (default-value 'electric-pair-mode #f))
        (kill-local-variable 'electric-pair-mode))
       ((not (default-value 'electric-pair-mode #f))
        ;; Locally enabled, but globally disabled.
        (electric-pair-mode 1)              ; Setup the hooks.
        (set-default 'electric-pair-mode #f)) ; But keep it globally disabled.
       (else #f)))))
