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
 (only (schemacs editor undo) text-editor-undo-disable! text-editor-undo-enable!)
    (scheme base)
    (scheme char)
    ;; `erase-buffer` is `buffer.c`'s and `with-current-buffer` is its
    ;; neighbour; the insertion is `editfns.c`'s `insert`.
    (only (schemacs editor buffer)
          *inhibit-read-only* erase-buffer with-current-buffer set-point
          buffer-beg buffer-pt buffer-z)
    (only (schemacs editor editfns)
          delete-region insert line-beginning-position line-end-position
          point propertize text-editor-cursor-line)
    ;; **The row carries its entry, and each column its name**, as text
    ;; properties - which is where `tabulated-list-get-id' and
    ;; `tabulated-list-set-col' read them from. That is Emacs's own
    ;; arrangement (`tabulated-list.el:574', `:633'), and it is what makes
    ;; a command that edits the list work on the text it is looking at.
    (only (schemacs editor textprop)
          get-text-property next-single-property-change put-text-property)
    )

  (export
   tabulated-list-entries
   tabulated-list-format
   tabulated-list-get-id
   tabulated-list-get-entry
   tabulated-list-print
   tabulated-list-print-entry
   tabulated-list-revert
   tabulated-list-delete-entry
   tabulated-list-set-col
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

    (define (tabulated-list-get-id ed)
      ;; GNU Emacs's `tabulated-list-get-id' (`tabulated-list.el:186'):
      ;; the ID of the entry on the line point is on in ED, from the
      ;; `tabulated-list-id' property `tabulated-list-print-entry' left on
      ;; the row. Off an entry's line - the titles, or past the last row -
      ;; there is no property and the answer is #f.
      ;;
      ;; **It used to count lines** into `*tabulated-list-entries*',
      ;; there being no properties; a command that edits the list cannot
      ;; work that way, which is why `set-col' and `delete-entry' below
      ;; could not be written.
      ;;--------------------------------------------------------------
      (get-text-property (buffer-pt ed) 'tabulated-list-id ed))

    (define (tabulated-list-get-entry ed)
      ;; GNU Emacs's `tabulated-list-get-entry' (`:192'): the entry's
      ;; columns, from the `tabulated-list-entry' property, or #f off an
      ;; entry's line.
      ;;--------------------------------------------------------------
      (get-text-property (buffer-pt ed) 'tabulated-list-entry ed))

    (define (tabulated-list--col-prop column key default)
      ;; The value of KEY in COLUMN's property list - GNU Emacs's
      ;; `(plist-get (nthcdr 3 col) key)', the `:pad-right' and
      ;; `:right-align' a format entry may carry after its name, width and
      ;; sort predicate.
      ;;--------------------------------------------------------------
      (let loop ((rest (list-tail column 3)))
        (cond ((or (null? rest) (null? (cdr rest))) default)
              ((eq? (car rest) key) (cadr rest))
              (else (loop (cddr rest))))))

    (define (tabulated-list--cell text want right-align)
      ;; TEXT in a column WANT characters wide: truncated when it is longer,
      ;; and padded on the left when RIGHT-ALIGN and on the right otherwise.
      ;;
      ;; **This is the arithmetic the titles and the rows share**, which the
      ;; C's own comment asks for - "FIXME: Should share code with
      ;; `tabulated-list-print-col'!" (`tabulated-list.el:288') - and the
      ;; reason its titles and its rows line up.
      ;;--------------------------------------------------------------
      (let* ((text (if (> (string-length text) want)
                       (substring text 0 want)
                       text))
             (pad (max 0 (- want (string-length text)))))
        (if right-align
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

    (define (tabulated-list-print-col col-desc column width last?)
      ;; GNU Emacs's `tabulated-list-print-col' (`tabulated-list.el:598'):
      ;; insert one column at point and answer the character column after
      ;; it. The column's *name* is left on its text as the
      ;; `tabulated-list-column-name' property, which is how
      ;; `tabulated-list-set-col' finds the column again.
      ;;
      ;; The last column is not padded - trailing spaces on every line
      ;; would be noise, and Emacs leaves it unpadded too. Where the C
      ;; pads by pixel width (`tabulated-list--col->px') this pads in
      ;; characters, the same simplification the renderer makes.
      ;;--------------------------------------------------------------
      (let* ((beg (point))
             (pad-right (tabulated-list--col-prop column ':pad-right 1))
             (right-align (tabulated-list--col-prop column ':right-align #f)))
        (if last?
            (insert col-desc)
            (begin
              ;; `(max 1 ...)': a width of 0 is "as wide as the widest
              ;; entry", resolved by `tabulated-list--widths'; a *negative*
              ;; width is Emacs's older way of saying `:right-align'.
              (insert (tabulated-list--cell col-desc
                                            (max 1 (abs width))
                                            (or right-align (< width 0))))
              (when (>= pad-right 0)
                (insert (make-string pad-right #\space)))))
        (put-text-property beg (point) 'tabulated-list-column-name (car column))
        (+ 0 (abs width))))

    (define (tabulated-list-print-entry id cols widths)
      ;; GNU Emacs's `tabulated-list-print-entry' (`tabulated-list.el:550'):
      ;; the row at point, with the entry's ID and its columns left on the
      ;; text as properties - `add-text-properties' of both at once, the
      ;; C's own "ever so slightly faster than calling `put-text-property'
      ;; twice".
      ;;--------------------------------------------------------------
      (let ((beg (point))
            (format (*tabulated-list-format*)))
        (let loop ((fields cols) (columns format) (widths widths))
          (cond ((null? fields) #f)
                (else
                 (tabulated-list-print-col (car fields) (car columns)
                                           (car widths) (null? (cdr fields)))
                 (loop (cdr fields) (cdr columns) (cdr widths)))))
        (insert "\n")
        (put-text-property beg (point) 'tabulated-list-id id)
        (put-text-property beg (point) 'tabulated-list-entry cols)))

    (define (tabulated-list--header)
      ;; The column titles: GNU Emacs's `tabulated-list-init-header'
      ;; (`tabulated-list.el:287'), laid out with **the same arithmetic as
      ;; the rows** so that they line up under them - which is what the C's
      ;; own "FIXME: Should share code with `tabulated-list-print-col'!"
      ;; is asking for.
      ;;
      ;; Two departures, both named. Emacs puts the titles in the *header
      ;; line* (`tabulated-list-use-header-line' is t by default) and in
      ;; the buffer's text when it is nil - and this project has no header
      ;; line, so they are the buffer's first line, the layout Emacs gives
      ;; with that variable nil. And Emacs aligns by `display' space
      ;; specifications (`:align-to'); a terminal has no pixels, so the
      ;; alignment is done in characters.
      ;;
      ;; The titles carry the `header-line' face, which is what Emacs
      ;; draws its header line with - a grey band, not plain text.
      ;;--------------------------------------------------------------
      (let ((widths (tabulated-list--widths (tabulated-list--entries))))
        (let loop ((columns (*tabulated-list-format*)) (widths widths)
                   (acc ""))
          (cond
           ((null? columns) (propertize acc 'face 'header-line))
           (else
            (let* ((column (car columns))
                   (width (car widths))
                   (last? (null? (cdr columns)))
                   (label (car column))
                   (pad-right (tabulated-list--col-prop column ':pad-right 1))
                   (right-align (tabulated-list--col-prop column ':right-align #f)))
              (loop (cdr columns) (cdr widths)
                    (string-append
                     acc
                     (if last?
                         label
                         (string-append
                          (tabulated-list--cell label (max 1 (abs width))
                                                (or right-align (< width 0)))
                          (if (>= pad-right 0)
                              (make-string pad-right #\space)
                              "")))))))))))

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
        ;; The buffer is emptied from its *beginning*, whatever point is
        ;; on: GNU Emacs's `erase-buffer' here, which does not depend on
        ;; point. Deleting forward from point instead would leave whatever
        ;; came before it and draw the new list onto the end of the old -
        ;; which is what a redraw with point down the list used to do.
        (with-current-buffer ed
          (erase-buffer)
          (insert (tabulated-list--header))
          (insert "\n")
          (for-each (lambda (entry)
                      (tabulated-list-print-entry (car entry) (cdr entry) widths))
                    entries))
        (text-editor-undo-enable! ed)
        (set-point ed (buffer-beg ed))
        entries))

    (define (tabulated-list-delete-entry ed)
      ;; GNU Emacs's `tabulated-list-delete-entry' (`tabulated-list.el:641'):
      ;; "Delete the Tabulated List entry at point. Return a list (ID
      ;; COLS) ... Move point to the beginning of the deleted entry.
      ;; Return nil if there is no entry at point."
      ;;
      ;; It changes the buffer and nothing else - the entry in
      ;; `tabulated-list-entries' that it came from is left alone, which
      ;; is what the docstring means by "does not alter
      ;; `tabulated-list-entries'".
      ;;--------------------------------------------------------------
      (let ((id (tabulated-list-get-id ed))
            (cols (tabulated-list-get-entry ed)))
        (when cols
          ;; `(inhibit-read-only t)' - the list buffer is read-only
          ;; (`special-mode' made it so), and the list is not the user's
          ;; text.
          (parameterize ((*inhibit-read-only* #t))
            (with-current-buffer ed
              (delete-region (line-beginning-position)
                             (+ 1 (line-end-position)))))
          (list id cols))))

    (define (tabulated-list-set-col ed col desc change-entry-data?)
      ;; GNU Emacs's `tabulated-list-set-col' (`tabulated-list.el:658'):
      ;; replace one column's text in the entry at point, finding the
      ;; column by the `tabulated-list-column-name' property that
      ;; `tabulated-list-print-col' left on it - the property is what says
      ;; where one column ends and the next begins.
      ;;
      ;; With CHANGE-ENTRY-DATA the entry's own field is changed too, as
      ;; the C's `(aset entry col desc)' does; the entry here is a *list*
      ;; of fields, not a vector, so it is `list-set!'.
      ;;
      ;; COL is a column *number*. Emacs also takes a column *name* and
      ;; resolves it through `tabulated-list--column-number'; nothing here
      ;; asks for that form, so it is not carried.
      ;;--------------------------------------------------------------
      (let* ((format (*tabulated-list-format*))
             (i col)
             (name (car (list-ref format i)))
             (entry (tabulated-list-get-entry ed)))
        (unless entry
          (error "No Tabulated List entry at position" (buffer-pt ed)))
        (with-current-buffer ed
          (let ((eol (line-end-position))
                (bol (line-beginning-position))
                ;; **The row's identity is taken before the edit and put
                ;; back after it.** `set-col' deletes the column's text and
                ;; inserts new text in its place, and in Emacs that text
                ;; inherits the row's `tabulated-list-id' and
                ;; `tabulated-list-entry' because a text property sticks
                ;; both ways by default. This tree's property layer does
                ;; not carry them across the delete, so without this the
                ;; row a command has just marked can no longer say which
                ;; buffer it is - `Buffer-menu-execute' then walks past its
                ;; own marks.
                (row-id (tabulated-list-get-id ed))
                (row-entry (tabulated-list-get-entry ed))
                (width (car (list-tail (tabulated-list--widths
                                        (tabulated-list--entries))
                                       i)))
                (last? (= i (- (length format) 1)))
                (prop 'tabulated-list-column-name))
            ;; The column's start: the line's beginning when that is
            ;; already the column, and otherwise the next position at
            ;; which the property becomes this column's name - the C's
            ;; `(unless (equal (get-text-property pos prop) name) (while
            ;; ...))'.
            (let ((pos (if (equal? (get-text-property bol prop ed) name)
                           bol
                           (let loop ((p bol))
                             (let ((next (next-single-property-change p prop ed eol)))
                               (if (and next (< next eol)
                                        (not (equal? (get-text-property next prop ed)
                                                     name)))
                                   (loop next)
                                   next))))))
              (if (or (not pos) (>= pos eol))
                  (error "Column does not exist" i)
                  ;; `(inhibit-read-only t)' here too - see
                  ;; `tabulated-list-delete-entry'.
                  (parameterize ((*inhibit-read-only* #t))
                    (let ((end (next-single-property-change pos prop ed eol))
                          (line-end eol))
                      (delete-region pos end)
                      (set-point ed pos)
                      (tabulated-list-print-col desc (list-ref format i) width last?)
                      (when change-entry-data?
                        (list-set! entry i desc))
                      (put-text-property bol line-end 'tabulated-list-id row-id)
                      (put-text-property bol line-end 'tabulated-list-entry
                                         row-entry)))))))))

    (define (tabulated-list-revert ed)
      ;; Redraw the list from its entries: GNU Emacs's
      ;; `tabulated-list-revert', which runs `tabulated-list-revert-hook'
      ;; first so that the mode can make its entries again.
      ;;--------------------------------------------------------------
      (tabulated-list-print ed))

    ))