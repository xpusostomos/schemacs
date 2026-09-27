(define-library (schemacs editor tabulated-list)
  ;; This library mirrors GNU Emacs's `tabulated-list.el`: the mode for
  ;; displaying a list of entries in columns, which `buff-menu.el` is
  ;; written against. `list-buffers' does not format its own text - it
  ;; hands `tabulated-list-mode' a *format* (the columns, their widths and
  ;; their printers) and an *entries* function (the rows), and the mode
  ;; lays them out, sorts them, and redraws the buffer.
  ;;
  ;; This is a **subset**, and the subset is the part `(schemacs editor
  ;; buff-menu)' calls. Emacs's file is about nine hundred lines, most of
  ;; which is sorting through `tabulated-list-sort-key' and its comparators,
  ;; the header line (`tabulated-list-use-header-line' and the whole
  ;; `header-line-format' machinery this project does not have yet),
  ;; faces and text properties for the highlighting, padding by pixel
  ;; width rather than by column, and the `tabulated-list-get-entry' /
  ;; `tabulated-list-put-tag' editing API for modes that are also editors
  ;; of their own list. What is here is the format, the entries, laying
  ;; them out into the buffer, and refreshing.
  ;;
  ;; Where Emacs pads to the column width with `tabulated-list--col->px'
  ;; and pixel arithmetic, this pads in characters, which is what a
  ;; terminal has; that is the same simplification the renderer makes.
  ;;
  ;; See LAYOUT-PLAN.txt for the rule this library is a step of.

  (import
    (scheme base)
    (scheme char)
    (only (schemacs editor engine)
          text-editor-char-count text-editor-get-cursor text-editor-insert
          text-editor-delete-from-cursor text-editor-set-cursor
          text-editor-undo-disable! text-editor-undo-enable!))

  (export
   tabulated-list-entries
   tabulated-list-format
   tabulated-list-print
   tabulated-list-revert
   *tabulated-list-entries*
   *tabulated-list-format*
   )

  (begin

    (define *tabulated-list-format*
      ;; GNU Emacs's `tabulated-list-format': a vector of columns, each a
      ;; vector of (NAME WIDTH SORT-PREDICATE), where a width of 0 means
      ;; "as wide as the widest entry".
      ;;
      ;; It is a parameter here because it is a buffer-local variable in
      ;; Emacs - each list buffer has its own - and parameters are what
      ;; this project uses for that until buffer-local variables exist.
      ;;--------------------------------------------------------------
      (make-parameter '()))

    (define *tabulated-list-entries*
      ;; GNU Emacs's `tabulated-list-entries': either a list of (ID .
      ;; FIELDS) pairs, one per row, or a function of no arguments that
      ;; returns such a list. `LIST-BUFFERS--REFRESH' is a function, so
      ;; that the rows are made when the list is drawn rather than kept.
      ;;--------------------------------------------------------------
      (make-parameter '()))

    (define (tabulated-list-format) (*tabulated-list-format*))
    (define (tabulated-list-entries) (*tabulated-list-entries*))

    (define (tabulated-list--entries)
      ;; The rows to draw, asking for them if they are a function: GNU
      ;; Emacs's `tabulated-list-entries' handles both forms the same way.
      ;;--------------------------------------------------------------
      (let ((entries (*tabulated-list-entries*)))
        (if (procedure? entries) (entries) entries)))

    (define (tabulated-list--cell text width)
      ;; TEXT in a column of WIDTH characters. A negative width means the
      ;; column is padded on the left - Emacs uses that for a number, so
      ;; that digits line up - and 0 means "as wide as the widest entry",
      ;; which is resolved by the caller.
      ;;--------------------------------------------------------------
      (let* ((want (abs width))
             (text (if (> (string-length text) want)
                       (substring text 0 want)
                       text))
             (pad (max 0 (- want (string-length text)))))
        (if (< width 0)
            (string-append (make-string pad #\space) text)
            (string-append text (make-string pad #\space)))))

    (define (tabulated-list--widths entries)
      ;; The width of each column: the format's width, or - for a width of
      ;; 0 - the widest field in that column, which is Emacs's rule.
      ;;--------------------------------------------------------------
      (let ((format (*tabulated-list-format*)))
        (let loop ((columns format) (at 0) (acc '()))
          (if (null? columns)
              (reverse acc)
              (let* ((column (car columns))
                     (declared (cadr column))
                     (width (if (= declared 0)
                                (let loop ((rest entries) (widest 0))
                                  (if (null? rest)
                                      widest
                                      (let ((field (list-ref (cdar rest) at)))
                                        (loop (cdr rest)
                                              (max widest
                                                   (string-length field))))))
                                declared)))
                (loop (cdr columns) (+ 1 at) (cons width acc)))))))

    (define (tabulated-list--line fields widths)
      ;; One row: each field in its column, and the last column not padded
      ;; - trailing spaces on every line would be noise, and Emacs leaves
      ;; the last column unpadded too.
      ;;--------------------------------------------------------------
      (let loop ((fields fields) (widths widths) (acc ""))
        (cond ((null? fields) acc)
              ((null? (cdr fields))
               (string-append acc (car fields)))
              (else
               (loop (cdr fields) (cdr widths)
                     (string-append acc (tabulated-list--cell (car fields)
                                                              (car widths))))))))

    (define (tabulated-list--header)
      ;; The column titles, each padded to its column: GNU Emacs's
      ;; `tabulated-list-init-header'.
      ;;
      ;; Emacs puts these in the *header line* - a row above the window's
      ;; text - and in the buffer's text when
      ;; `tabulated-list-use-header-line' is nil. This project has no
      ;; header line, so they are the buffer's first line, which is the
      ;; layout Emacs gives with that variable nil.
      ;;--------------------------------------------------------------
      (let loop ((columns (*tabulated-list-format*)) (acc ""))
        (cond ((null? columns) acc)
              ;; the last column is as wide as it needs to be, so it is
              ;; not padded
              ((null? (cdr columns)) (string-append acc (car (car columns))))
              (else
               (let* ((title (car (car columns)))
                      (width (cadr (car columns))))
                 (loop (cdr columns)
                       (string-append acc title
                                      (make-string
                                       (max 1 (- width (string-length title)))
                                       #\space))))))))

    (define (tabulated-list-print ed)
      ;; Draw the list into buffer ED: GNU Emacs's
      ;; `tabulated-list-print'. The buffer's text is replaced - the
      ;; titles and then the rows - point is left at the beginning, and
      ;; undo does not record any of it, the list not being the user's
      ;; text.
      ;;--------------------------------------------------------------
      (let* ((entries (tabulated-list--entries))
             (widths (tabulated-list--widths entries)))
        (text-editor-undo-disable! ed)
        (text-editor-delete-from-cursor ed (text-editor-char-count ed))
        (text-editor-set-cursor ed 0)
        (text-editor-insert ed (tabulated-list--header))
        (text-editor-insert ed "\n")
        (for-each (lambda (entry)
                    (text-editor-insert
                     ed (tabulated-list--line (cdr entry) widths))
                    (text-editor-insert ed "\n"))
                  entries)
        (text-editor-undo-enable! ed)
        (text-editor-set-cursor ed 0)
        entries))

    (define (tabulated-list-revert ed)
      ;; Redraw the list from its entries: GNU Emacs's
      ;; `tabulated-list-revert', which runs `tabulated-list-revert-hook'
      ;; first so that the mode can make its entries again.
      ;;--------------------------------------------------------------
      (tabulated-list-print ed))

    ))