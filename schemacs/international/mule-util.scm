(define-library (schemacs international mule-util)
  ;; This library mirrors GNU Emacs's `lisp/international/mule-util.el`:
  ;; the string utilities over character *display width*. What is here is
  ;; `truncate-string-to-width` and the ellipsis it defaults to - which
  ;; is what `tab-line.el` uses for a truncated tab name.
  ;;
  ;; The widths are `character.scm`'s `char-width` and `string-width`
  ;; (`character.c`'s), which is what the C uses: `truncate-string-to-width`
  ;; sums `char-width` over the string and knows nothing about where it is
  ;; displayed - the docstring's own "see `char-width'".
  ;;
  ;; Not ported, each because nothing here asks for it: the nested-alist
  ;; family (`nested-alist-p` and its four relatives), and
  ;; `file-name-non-directory-suffix` - the rest of the file.

  (import
    (scheme base)
    (scheme char)
    (only (guile) caddr)
    (only (schemacs character) char-width string-width)
    (only (schemacs editfns) propertize))

  (export truncate-string-to-width truncate-string-ellipsis
          truncate-string-ellipsis-string)

  (begin

    (define truncate-string-ellipsis-string #f)
    ;; ^ GNU Emacs's `(defvar truncate-string-ellipsis nil)`: "String to
    ;; use to indicate truncation."
    ;;
    ;; **The `-string` because Scheme is a Lisp-1**: Emacs has a variable
    ;; and a function both called `truncate-string-ellipsis`, and here the
    ;; second definition would replace the first. The function keeps the
    ;; name, because that is what callers name.

    (define (truncate-string-ellipsis)
      ;; GNU Emacs's `truncate-string-ellipsis` (`mule-util.el:51`):
      ;; "Return the string used to indicate truncation. ... Otherwise,
      ;; return the Unicode character U+2026 \"HORIZONTAL ELLIPSIS\" when
      ;; it's displayable on the selected frame, or `...'."
      ;;
      ;; `char-displayable-p` is #t for every character here (there is
      ;; one display and it draws what the buffer holds - `icons.scm`
      ;; says the same for its own call), so the answer is the ellipsis
      ;; character.
      ;;--------------------------------------------------------------
      (or truncate-string-ellipsis-string
          (string (integer->char #x2026))
          "..."))

    (define (truncate-string-to-width str end-column . args)
      ;; GNU Emacs's `truncate-string-to-width` (`mule-util.el:65`):
      ;; "Truncate string STR to end at column END-COLUMN. The optional
      ;; 3rd arg START-COLUMN ... specifies the starting column ... The
      ;; optional 4th arg PADDING, if non-nil, specifies a padding
      ;; character ... If ELLIPSIS is non-nil, it should be a string which
      ;; will replace the end of STR (including any padding) if it extends
      ;; beyond END-COLUMN, unless the display width of STR is equal to or
      ;; less than the display width of ELLIPSIS."
      ;;
      ;; The C's `condition-case (args-out-of-range ...)` around each
      ;; walk is what stops it at the end of the string: reading past it
      ;; is the exception there and `str-len` here.
      ;;
      ;; Not carried: ELLIPSIS-TEXT-PROPERTY (the sixth argument), which
      ;; `tab-line.el` never passes and which needs the `display` property
      ;; to be the thing that hides text.
      ;;--------------------------------------------------------------
      (let* ((start-column (if (pair? args) (car args) #f))
             (padding (if (and (pair? args) (pair? (cdr args)))
                          (cadr args) #f))
             (ellipsis (if (and (pair? args) (pair? (cdr args))
                                (pair? (cddr args)))
                           (caddr args) #f))
             (start-column (or start-column 0))
             (ellipsis (if (and ellipsis (not (string? ellipsis)))
                           (truncate-string-ellipsis)
                           ellipsis)))
        (let ((str-len (string-length str))
              (str-width (string-width str))
              (ellipsis-width (if ellipsis (string-width ellipsis) 0))
              (idx 0)
              (column 0)
              (head-padding "")
              (tail-padding ""))
          ;; "while (< column start-column)": the walk to the start
          ;; column, stopping at the end of the string.
          ;; The C reads past the end to *stop*; here the length is the
          ;; test, and IDX ends at STR-LEN either way.
          (let loop ()
            (when (and (< column start-column) (< idx str-len))
              (set! column (+ column (char-width (string-ref str idx))))
              (set! idx (+ idx 1))
              (loop)))
          (if (< column start-column)
              (if padding (make-string end-column padding) "")
              (begin
                (when (and padding (> column start-column))
                  (set! head-padding
                        (make-string (- column start-column) padding)))
                (let ((from-idx idx))
                  (when (>= end-column column)
                    (if (and (< end-column str-width)
                             (> str-width ellipsis-width))
                        (set! end-column (- end-column ellipsis-width))
                        (set! ellipsis ""))
                    ;; "while (< column end-column)", with `last-column`
                    ;; and `last-idx` keeping the position before the
                    ;; character that crossed the edge.
                    (let ((last-column column) (last-idx idx) (stop #f))
                      (let loop ()
                        (when (and (not stop) (< column end-column))
                          (if (>= idx str-len)
                              (begin (set! idx str-len) (set! stop #t))
                              (begin
                                (set! last-column column)
                                (set! last-idx idx)
                                (set! column
                                      (+ column (char-width (string-ref str idx))))
                                (set! idx (+ idx 1))
                                (loop)))))
                      (when (> column end-column)
                        (set! column last-column)
                        (set! idx last-idx)))
                    (when (and padding (< column end-column))
                      (set! tail-padding
                            (make-string (- end-column column) padding))))
                  (string-append head-padding
                                 (substring str from-idx idx)
                                 tail-padding
                                 (or ellipsis ""))))))))))
