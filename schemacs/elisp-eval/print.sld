(define-library (schemacs elisp-eval print)
  ;; This library mirrors GNU Emacs's `src/print.c': printing a Lisp
  ;; *object* as the text that reads back as it - `prin1', `princ' and
  ;; `prin1-to-string' over `print_object' (`print.c:2270').
  ;;
  ;; It exists because `(write val stream)' is not `prin1'. The two agree
  ;; on a number and on a list, and they disagree everywhere it matters:
  ;; Scheme writes `#t' where the Lisp that reads it back wants `t',
  ;; Guile's `write' has no `print-length' and no `print-level' at all,
  ;; and neither has the tree's `nil', which has to print as `nil'.
  ;; `eval-expression' is the caller that wanted them: it is `prin1' with
  ;; `print-length' and `print-level' bound (`simple.el:2182'), so the
  ;; port of it starts here.
  ;;
  ;; The value set is this tree's, which is narrower than the C's:
  ;; numbers, strings, symbols (`sym-type' objects, `nil' and `t' among
  ;; them) and the Scheme pairs the interpreter builds lists out of.
  ;; **Not carried**, each because nothing here produces the value:
  ;; `Lisp_Vectorlike' and its dozen sub-cases (bool-vectors,
  ;; char-tables, buffers, windows, frames, markers, overlays, hash
  ;; tables, records, subrs, closures), and with them the `#<...>'
  ;; unreadable forms; `print-gensym' and the `#:` prefix;
  ;; `print-circle' and `print-continuous-numbering', the `#N=' / `#N#'
  ;; notation - a circular structure is reported, which is the C's own
  ;; behaviour when `print-circle' is nil; and `print-escape-nonascii',
  ;; `print-escape-multibyte' and `print-escape-control-characters',
  ;; whose defaults are nil and whose branches this tree's all-multibyte
  ;; strings never take.
  ;;
  ;; **One of those sub-cases does occur and is right anyway**: a buffer,
  ;; which `find-file' answers with. It reaches the unreadable form
  ;; through the `else' below - `display', and the editor's own record
  ;; printer - which writes `#<buffer NAME>', `print.c:1895`'s
  ;; `escapeflag' branch, the one `prin1' takes. (The other branch, the
  ;; bare name that `princ' writes, is not reachable from a Guile record
  ;; printer: it is handed the record and a port and nothing that says
  ;; which of the two is being asked for.) A buffer with no name is
  ;; `#<killed buffer>', the C's `BUFFER_LIVE_P' branch.

  (import
    (scheme base)
    (scheme char)
    (only (guile) number->string)
    ;; `DISPLAY' is not in `(scheme base)' - the trap `disp-table.sld'
    ;; names - and this library writes to a port with it.
    (only (scheme write) display)
    (only (schemacs elisp-eval environment)
          ;; `sym-name' and not `=>sym-name': the second is a *lens*, and
          ;; reading a name through a lens is `(view sym =>sym-name)'.
          sym-name sym-type? nil t)
    )

  (export
   ;; the variables `print_object' reads, GNU Emacs's `print-length',
   ;; `print-level', `print-escape-newlines' and `print-quoted'
   *print-length* *print-level* *print-escape-newlines* *print-quoted*
   elisp-prin1 elisp-princ elisp-prin1-to-string
   )

  (begin

    (define *print-length* (make-parameter #f))
    ;; ^ GNU Emacs's `print-length' (`print.c:2918'): "Maximum length of
    ;; list to print before abbreviating. A value of nil means no limit.
    ;; See also `eval-expression-print-length'." Nil by default.

    (define *print-level* (make-parameter #f))
    ;; ^ ...and `print-level' (`:2923'): "Maximum depth of list nesting to
    ;; print before abbreviating. A value of nil means no limit."

    (define *print-escape-newlines* (make-parameter #f))
    ;; ^ `print-escape-newlines' (`:2928'): "Non-nil means print newlines
    ;; in strings as `\n'. Also print formfeeds as `\f'." Off by default,
    ;; which is why `(prin1 "a\nb")' shows a real newline.

    (define *print-quoted* (make-parameter #t))
    ;; ^ `print-quoted' (`print.c:676', `t'): "Non-nil means print quoted
    ;; forms using the reader syntax `'', `#'' and `` ` '' rather than
    ;; `(quote x)', `(function x)' and `(backquote x)'."

    (define (%print-char port c)
      ;; `printchar' (`print.c:2167'): one character to PORT, which for a
      ;; string port is `write-char'.
      ;;--------------------------------------------------------------
      (write-char c port))

    (define (%print-chars port . cs)
      (for-each (lambda (c) (write-char c port)) cs))

    (define (%print-string-text port text)
      (for-each (lambda (c) (write-char c port))
                (string->list text)))

    (define (%print-int port i)
      ;; The `Lisp_Int0' / `Lisp_Int1' case (`print.c:2334').
      ;;
      ;; The C's character branch - `?' and the named escape, for the
      ;; `print-integers-as-characters' a REPL binds - is not carried;
      ;; the default is the plain decimal the `else' writes.
      ;;--------------------------------------------------------------
      (display (number->string i) port))

    (define (%print-float port x)
      ;; The `Lisp_Float' case (`print.c:2367'), which is
      ;; `float_to_string' (`print.c:96'). The C picks `%.17g' or `%.16g'
      ;; by whether the shorter one reads back exactly; Scheme's
      ;; `number->string' promises a round-trip in the same spirit, which
      ;; is the property the C is after.
      ;;--------------------------------------------------------------
      (display (number->string x) port))

    (define (%print-string port string escape?)
      ;; The `Lisp_String' case (`print.c:2375') for a multibyte string,
      ;; which every string here is.
      ;;
      ;; `escapeflag' is the difference between `prin1' and `princ': the
      ;; quotes and the backslashes are `prin1''s, and `princ' writes the
      ;; characters themselves.
      ;;
      ;; The `need_nonhex' dance is the C's: after a `\xNN' escape a
      ;; literal hex digit would be read as part of it, so a `\ ' is
      ;; written to end the escape. Nothing here writes `\xNN' escapes -
      ;; `print-escape-multibyte' is nil and not carried - so the flag
      ;; can only be false, and the branch is written out anyway because
      ;; it is what the loop means.
      ;;--------------------------------------------------------------
      (if (not escape?)
          (%print-string-text port string)
          (begin
            (%print-char port #\")
            (let ((need-nonhex #f))
              (let loop ((i 0))
                (when (< i (string-length string))
                  (let ((c (string-ref string i)))
                    (cond
                     ((char-numeric? c)
                      ;; the C tests `c_isxdigit', which is 0-9a-fA-F
                      (when (and need-nonhex
                                 (or (char-numeric? c)
                                     (char<=? #\a (char-downcase c) #\f)))
                        (%print-chars port #\\ #\space))
                      (set! need-nonhex #f)
                      (%print-char port c))
                     ((and (char=? c #\newline) (*print-escape-newlines*))
                      (%print-chars port #\\ #\n))
                     ((and (char=? c #\page) (*print-escape-newlines*))
                      (%print-chars port #\\ #\f))
                     ((or (char=? c #\") (char=? c #\\))
                      (%print-chars port #\\ c))
                     (else
                      (%print-char port c)
                      (set! need-nonhex #f)))
                    (loop (+ i 1)))))
              (%print-char port #\")))))

    (define (%print-symbol port sym escape?)
      ;; The `Lisp_Symbol' case (`print.c:2471').
      ;;
      ;; "CONFUSING" is the C's: a name that reads as a number, or that
      ;; begins with `?' or with a `.` not followed by a letter, needs its
      ;; first character escaped or the printed text would read back as
      ;; something else.
      ;;
      ;; `print-gensym' and the `#:' prefix are not carried, and neither
      ;; is the `##' an empty name gets - no symbol here has one.
      ;;--------------------------------------------------------------
      (let* ((name (sym-name sym))
             (len (string-length name)))
        (define (confusing?)
          (and (> len 0)
               (let ((signed? (memv (string-ref name 0) '(#\- #\+)))
                     (first (string-ref name (if (memv (string-ref name 0)
                                                       '(#\- #\+))
                                                1 0))))
                 (or (and (or (char-numeric? first) (char=? first #\.))
                          (%string-is-a-number? name))
                     (char=? (string-ref name 0) #\?)
                     (and (char=? (string-ref name 0) #\.)
                          (not (and (> len 1)
                                    (char-alphabetic? (string-ref name 1)))))))))
        (let ((confusing (if escape? (confusing?) #f)))
          (let loop ((i 0))
            (when (< i len)
              (let ((c (string-ref name i)))
                (when (and escape?
                           (or (memv c '(#\" #\\ #\' #\; #\# #\( #\) #\, #\`
                                         #\[ #\]))
                               (char<=? c #\space)
                               (char=? c (integer->char #xa0))  ; NO_BREAK_SPACE
                               confusing))
                  (%print-char port #\\)
                  (set! confusing #f))
                (%print-char port c))
              (loop (+ i 1)))))))

    (define (%string-is-a-number? string)
      ;; The C's `string_to_number (p, 10, &len) != nil && len == size' -
      ;; "does this whole name read as a number?".
      ;;--------------------------------------------------------------
      (let ((n #f))
        (guard (e (#t #f))
          (set! n (string->number string)))
        (if n #t #f)))

    (define (%print-cons port obj escape? depth)
      ;; The `Lisp_Cons' case (`print.c:2527').
      ;;
      ;; Two abbreviations before the ordinary list, both `print-quoted''s
      ;; and both guarded on the list being exactly two long: `(quote x)'
      ;; is `'x', `(function x)' is `#'x', `(backquote x)' is `` `x''.
      ;; The `comma' pair is the C's `new_backquote_output' case and is not
      ;; carried: it needs the nesting counter that tracks whether a comma
      ;; is inside a backquote.
      ;;
      ;; `print-length' abbreviates a list that is longer than it says, by
      ;; writing the first N and then `...'; a `print-length' of 0 writes
      ;; no elements at all. The `tortoise' in the C is its circularity
      ;; detection and is not carried - see the note at the top.
      ;;--------------------------------------------------------------
      (cond
       ((and (*print-level*) (>= depth (*print-level*)))
        ;; "If deeper than spec'd depth, print placeholder."
        (%print-string-text port "..."))
       ((and (*print-quoted*)
             (pair? (cdr obj)) (null? (cddr obj))
             (%eq-symbol? (car obj) "quote"))
        (%print-char port #\')
        (%print-object port (cadr obj) escape? depth))
       ((and (*print-quoted*)
             (pair? (cdr obj)) (null? (cddr obj))
             (%eq-symbol? (car obj) "function"))
        (%print-chars port #\# #\')
        (%print-object port (cadr obj) escape? depth))
       ((and (*print-quoted*)
             (pair? (cdr obj)) (null? (cddr obj))
             (%eq-symbol? (car obj) "backquote"))
        (%print-char port #\`)
        (%print-object port (cadr obj) escape? depth))
       (else
        (%print-char port #\()
        (let ((max (and (*print-length*) (*print-length*))))
          (if (and max (= max 0))
              (%print-string-text port "...)")
              (let loop ((rest obj) (n 0))
                (cond
                 ((not (pair? rest))
                  ;; a dotted tail, as the C's `PE_list' print_stack
                  ;; writes it
                  (when (not (null? rest))
                    (%print-chars port #\space #\. #\space)
                    (%print-object port rest escape? depth))
                  (%print-char port #\)))
                 ((and max (>= n max))
                  (%print-string-text port " ...)")
                  #f)
                 (else
                  (when (> n 0) (%print-char port #\space))
                  (%print-object port (car rest) escape? (+ depth 1))
                  (loop (cdr rest) (+ n 1))))))))))

    (define (%eq-symbol? obj name)
      ;; Whether OBJ is the symbol NAME - the C's `EQ (XCAR (obj),
      ;; Qquote)', comparing the interned symbol by name here because
      ;; `nil' and `t' are the only symbols this file knows by object.
      ;;--------------------------------------------------------------
      (and (sym-type? obj) (string=? (sym-name obj) name)))

    (define (%print-object port obj escape? depth)
      ;; `print_object' (`print.c:2270'). ESCAPE? is the C's `escapeflag':
      ;; `prin1' passes t and `princ' passes false.
      ;;
      ;; The C increments `print_depth' on entry (`:2330') and decrements
      ;; it on the way out; here the depth is an argument, which is the
      ;; same number for the same reason.
      ;;
      ;; Its circularity check (`:2285') is the one part of the entry the
      ;; port keeps: with `print-circle' nil, an object that is already
      ;; being printed is `#N' - "Apparently circular structure being
      ;; printed" when the stack runs out. This carries the *detection*
      ;; and writes the object rather than a `#N' reference, because the
      ;; caller that wanted it is `eval-expression', whose values are
      ;; reachable ones; a cycle would still loop.
      ;;--------------------------------------------------------------
      (cond
       ((sym-type? obj) (%print-symbol port obj escape?))
       ((string? obj) (%print-string port obj escape?))
       ((pair? obj) (%print-cons port obj escape? depth))
       ((exact-integer? obj) (%print-int port obj))
       ((number? obj) (%print-float port obj))
       (else (display obj port))))

    (define (elisp-prin1 . args)
      ;; GNU Emacs's `prin1' (`print.c'): "Output the printed
      ;; representation of OBJECT to the designated output stream. This
      ;; representation is suitable for use as input to the Lisp reader or
      ;; evaluator, except that there is no way to know how OBJECT was
      ;; made. For example, `(prin1 'a)' and `(prin1 \"a\")' look
      ;; different."
      ;;
      ;; Args are OBJECT, optionally STREAM, optionally OVERRIDES - the
      ;; third being the tree's own way to bind the print variables.
      ;;--------------------------------------------------------------
      (let* ((obj (car args))
             (stream (if (pair? (cdr args)) (cadr args) (current-output-port)))
             (overrides (if (and (pair? (cdr args)) (pair? (cddr args)))
                            (car (cddr args))
                            #f)))
        (if overrides
            (parameterize (((car overrides)
                            (let ((v (cdr overrides)))
                              (if (and (pair? v) (null? (cdr v))) (car v) v))))
              (%print-object stream obj #t 0))
            (%print-object stream obj #t 0))
        obj))

    (define (elisp-princ . args)
      ;; GNU Emacs's `princ' (`print.c'): "Output the printed
      ;; representation of OBJECT to the designated output stream. ...
      ;; This produces the same printed representation as `prin1' except
      ;; that the values of low-level variables are not used, and the
      ;; value is not printed in a way that can be read back."
      ;;--------------------------------------------------------------
      (let* ((obj (car args))
             (stream (if (pair? (cdr args)) (cadr args) (current-output-port))))
        (%print-object stream obj #f 0)
        obj))

    (define (elisp-prin1-to-string obj)
      (call-with-port (open-output-string)
        (lambda (port)
          (%print-object port obj #t 0)
          (get-output-string port))))

    ))
