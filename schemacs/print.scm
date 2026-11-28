(define-library (schemacs print)
  ;; GNU Emacs's `src/print.c', so far as this tree has needed it: the
  ;; four printing functions `prin1', `princ', `terpri', `print', their
  ;; two string forms, and the `standard-output' they default to.
  ;;
  ;; **The object printer is Guile's `write'/`display'**, which is the
  ;; departure `(schemacs editfns)' has carried for `%S'/`%s' since the
  ;; first format port: `print_object' walks every Lisp type, and this
  ;; tree's records, char-tables and buffers have no Emacs printed form
  ;; to walk. `princ-to-string' keeps the one arm the difference is
  ;; visible in - a buffer prints as its name, which is
  ;; `print_object`'s `PVEC_BUFFER` case (`print.c:1895').
  ;;
  ;; **The destinations are the C's** (`printchar', `print.c:648'): a
  ;; buffer (insert at its point), a marker (insert at it, leave the
  ;; marker after the text), a function (called with each character), a
  ;; port, `t' for the echo area, and nil for `standard-output'. The
  ;; echo area is a seam because `message' lives above this library.
  ;;
  ;; `standard-output' is a **parameter** here, as the convention at the
  ;; top of AGENTS.md requires of a dynamically bound variable: Emacs
  ;; `let`-binds it in `with-output-to-string', `with-output-to-temp-
  ;; buffer' and `eval-region', and a plain variable could not be bound
  ;; from a caller's module. Its default is `t' - Emacs's initial value,
  ;; the echo area.
  ;;
  ;; Not carried: `print-length'/`print-level' and the rest of the
  ;; `print_*' variables, `print-circle' and the `#N=' notation,
  ;; `print-gensym', `print-escape-*', `print-charset-text-property',
  ;; the `float-output-format' machinery and the `#<...>' forms.
  ;;------------------------------------------------------------
  (import (scheme base)
          (scheme write)
          (only (guile) call-with-output-string)
          (only (schemacs buffer)
                bufferp buffer-name buffer-pt set!buffer-pt
                buffer-beg buffer-z current-buffer with-current-buffer)
          (only (schemacs insdel) insert-from-string)
          (only (schemacs marker)
                markerp marker-buffer marker-position set-marker))

  (export *standard-output* *print-echo-function*
          prin1-to-string princ-to-string prin1 princ terpri print)

  (begin

    (define *standard-output* (make-parameter #t))
    ;; ^ GNU Emacs's `standard-output' (`print.c:...`): "Output stream
    ;; `princ' and `prin1' print to. It can be t, nil, a buffer, a
    ;; marker or a function." The default `t' is the echo area.

    (define *print-echo-function* (make-parameter #f))
    ;; The seam to `message', which is `editfns.scm`'s and above this
    ;; library. It takes one string. `editfns.scm` installs it as it
    ;; loads.

    (define (prin1-to-string object)
      ;; GNU Emacs's `prin1-to-string' (`print.c:...`): "Return a string
      ;; that would be printed for OBJECT by `prin1'."
      ;;--------------------------------------------------------------
      (call-with-output-string
       (lambda (port) (write object port))))

    (define (princ-to-string object)
      ;; GNU Emacs's `princ-to-string' (`print.c:...`): "Return a string
      ;; that would be printed for OBJECT by `princ'."
      ;;
      ;; A buffer prints as its name with the escape flag off
      ;; (`print_object`'s `PVEC_BUFFER` arm, `print.c:1895'); a killed
      ;; buffer is `#<killed buffer>'.
      ;;--------------------------------------------------------------
      (cond ((string? object) object)
            ((bufferp object)
             (or (buffer-name object) "#<killed buffer>"))
            (else
             (call-with-output-string
              (lambda (port) (display object port))))))

    (define (%print-string string printcharfun)
      ;; `printchar' (`print.c:648') over a whole string: which sink the
      ;; characters go to, and what each sink does with them.
      ;;--------------------------------------------------------------
      (let ((dest (if printcharfun printcharfun (*standard-output*))))
        (cond
         ((eq? dest #t)
          (let ((echo (*print-echo-function*)))
            (if echo
                (echo string)
                (error "print: the echo area is not available (schemacs editfns is not loaded)"))))
         ((bufferp dest)
          (with-current-buffer dest
            (insert-from-string string)))
         ((markerp dest)
          (let ((buffer (marker-buffer dest)))
            (unless buffer
              (error "Marker does not point anywhere"))
            (with-current-buffer buffer
              (let ((old (buffer-pt buffer))
                    (pos (marker-position dest)))
                (unless (and (>= pos (buffer-beg buffer))
                             (<= pos (buffer-z buffer)))
                  (error "Marker is outside the accessible part of the buffer"))
                (set!buffer-pt buffer pos)
                (insert-from-string string)
                ;; "set_marker_both (pc->old_printcharfun, ...)" - the
                ;; marker ends up after the text it wrote.
                (set-marker dest (buffer-pt buffer))
                (set!buffer-pt buffer old)))))
         ((procedure? dest)
          (string-for-each (lambda (ch) (dest ch)) string))
         ((port? dest)
          (display string dest))
         (else
          (error "Invalid printcharfun: ~a" dest)))))

    (define (prin1 object . printcharfun-arg)
      ;; GNU Emacs's `prin1' (`print.c:...`): "Output the printed
      ;; representation of OBJECT to the designated character stream.
      ;; This function outputs OBJECT's printed representation, which is
      ;; mostly the same as its textual form, but with quotes around
      ;; strings and with escapes for special characters. ..."
      ;;--------------------------------------------------------------
      (%print-string (prin1-to-string object)
                     (and (pair? printcharfun-arg) (car printcharfun-arg)))
      object)

    (define (princ object . printcharfun-arg)
      ;; GNU Emacs's `princ' (`print.c:...`): "Output the printed
      ;; representation of OBJECT to the designated character stream.
      ;; This function outputs OBJECT's printed representation, which is
      ;; mostly the same as its textual form, but with quotes around
      ;; strings and with escapes for special characters.  If OBJECT is a
      ;; string, its contents are printed, not its printed representation.
      ;; ..."
      ;;--------------------------------------------------------------
      (%print-string (princ-to-string object)
                     (and (pair? printcharfun-arg) (car printcharfun-arg)))
      object)

    (define (terpri . printcharfun-arg)
      ;; GNU Emacs's `terpri' (`print.c:...`): "Output a newline to the
      ;; designated character stream. ..."
      ;;--------------------------------------------------------------
      (%print-string "\n"
                     (and (pair? printcharfun-arg) (car printcharfun-arg)))
      #f)

    (define (print object . printcharfun-arg)
      ;; GNU Emacs's `print' (`print.c:...`): "Output a newline, then
      ;; the printed representation of OBJECT, then a newline. ... The
      ;; newline before OBJECT is omitted if it is the first thing
      ;; printed." The first-newline rule is `printcharfun`'s state in
      ;; the C; nothing in this tree asks for it, so both newlines are
      ;; printed, which is the answer whenever anything has been printed
      ;; before.
      ;;--------------------------------------------------------------
      (let ((dest (and (pair? printcharfun-arg) (car printcharfun-arg))))
        (%print-string "\n" dest)
        (prin1 object dest)
        (terpri dest)
        object))

    ))
