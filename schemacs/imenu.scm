(define-library (schemacs imenu)
  ;; This library mirrors GNU Emacs's `lisp/imenu.el': the mode-specific
  ;; buffer index and the command that jumps through it.
  ;;
  ;; **What is here**: the variables a mode sets (all `defvar-local`s in
  ;; Emacs, so parameter + buffer-local slot here), the index builder
  ;; (`imenu--generic-function', `imenu-default-create-index-function'),
  ;; the index alist and its cleanup, the completion chooser and the
  ;; `imenu' command itself.
  ;;
  ;; **Not carried**, each named with what it waits for: the mouse menu
  ;; (`imenu--mouse-menu', `imenu--create-keymap') and the menu-bar entry
  ;; (`imenu-add-to-menubar', `imenu-update-menubar') - this tree's
  ;; keymaps are records and a menu rebuilt by `setcdr' has no record
  ;; shape; the `imenu-flatten' annotation/group values, which want
  ;; completion metadata the tree's `completing-read' does not carry;
  ;; `thing-at-point' for the default candidate guess; and the
  ;; Invisible-text skip (the renderer does not honour `invisible', so
  ;; treating text as visible is the consistent answer).
  ;;
  ;; `imenu-default-goto-function' is both a variable and a function in
  ;; Emacs - a Lisp-2 name. The variable's accessor is
  ;; `imenu-default-goto-function-variable' here.

  (import
    (scheme base)
    (scheme char)
    (only (scheme cxr) caddr cdddr)
    (only (guile) sort format)
    (only (schemacs timefns) float-time)
    (only (schemacs buffer)
          current-buffer buffer-local-value set-buffer-local-value!
          local-variable-p buffer-name *case-fold-search*)
    (only (schemacs data) default-value)
    (only (schemacs editfns)
          point point-min point-max goto-char save-excursion
          buffer-substring-no-properties buffer-size widen save-restriction
          message)
    (only (schemacs cmds) beginning-of-line)
    (only (schemacs search)
          re-search-backward match-beginning match-end
          match-string-no-properties regexp-quote string-match save-match-data)
    (only (schemacs syntax)
          syntax-table copy-syntax-table modify-syntax-entry
          with-syntax-table syntax-ppss)
    (only (schemacs marker)
          copy-marker markerp marker-position set-marker)
    (only (schemacs fns) nth)
    (only (schemacs subr) delq run-hooks nthcdr)
    (only (schemacs simple) push-mark)
    (only (schemacs command) define-command)
    (only (schemacs minibuffer) completing-read format-prompt make<history>)
    (only (schemacs core lisp) beginning-of-defun)
    (only (schemacs custom) define-custom)
    (only (schemacs font-lock) font-lock-defaults *font-lock-defaults*))

  (export
   *imenu-use-markers* *imenu-max-item-length* *imenu-auto-rescan*
   *imenu-auto-rescan-maxout* *imenu-use-popup-menu*
   *imenu-eager-completion-buffer* *imenu-after-jump-hook*
   *imenu-sort-function* *imenu-max-items* *imenu-space-replacement*
   *imenu-level-separator* *imenu-flatten*
   *imenu-generic-skip-comments-and-strings* *imenu-max-index-time*
   *imenu-allow-duplicate-menu-items*
   imenu-generic-expression set!imenu-generic-expression
   imenu-case-fold-search set!imenu-case-fold-search
   imenu-syntax-alist set!imenu-syntax-alist
   imenu-create-index-function set!imenu-create-index-function
   imenu-submenus-on-top set!imenu-submenus-on-top
   imenu-prev-index-position-function set!imenu-prev-index-position-function
   imenu-extract-index-name-function set!imenu-extract-index-name-function
   imenu-name-lookup-function set!imenu-name-lookup-function
   imenu-default-goto-function-variable
   set!imenu-default-goto-function-variable!
   imenu--index-alist set!imenu--index-alist
   imenu--rescan-item imenu--history-list
   imenu--subalist-p imenu-unavailable-error
   imenu--sort-by-name imenu--sort-by-position imenu--relative-position
   imenu--split imenu--split-menu imenu--split-submenus
   imenu--truncate-items imenu--make-index-alist imenu--cleanup
   imenu--in-alist imenu-default-create-index-function
   imenu--generic-function imenu-find-default imenu--completion-buffer
   imenu-choose-buffer-index imenu-default-goto-function
   imenu imenu-flush-cache)

  (begin

    (define (imenu-buffer-local param)
      ;; A buffer-local variable: the buffer's slot wins over the
      ;; parameter, as `font-lock-buffer-local' does.
      ;;--------------------------------------------------------------
      (buffer-local-value (current-buffer) param (param)))

    (define (set!imenu-buffer-local! param value)
      (set-buffer-local-value! (current-buffer) param value))

    ;;----------------------------------------------------------------
    ;; The options (defcustoms)
    ;;----------------------------------------------------------------

    (define-custom *imenu-use-markers* #t
      "Non-nil means use markers instead of integers for Imenu buffer positions."
      :type 'boolean :group 'imenu)

    (define-custom *imenu-max-item-length* 60
      "If a number, truncate Imenu entries to that length."
      :type '(choice integer (const :tag "Unlimited" nil)) :group 'imenu)

    (define-custom *imenu-auto-rescan* #f
      "Non-nil means Imenu should always rescan the buffers."
      :type 'boolean :group 'imenu)

    (define-custom *imenu-auto-rescan-maxout* 600000
      "Imenu auto-rescan is disabled in buffers larger than this size."
      :type 'natnum :group 'imenu)

    (define-custom *imenu-use-popup-menu* 'on-mouse
      "Use a popup menu rather than a minibuffer prompt."
      :type '(choice (const :tag "On Mouse" on-mouse)
                     (const :tag "Never" nil)
                     (other :tag "Always" t))
      :group 'imenu)

    (define-custom *imenu-eager-completion-buffer* #t
      "If nil, eagerly pop up the completion buffer."
      :type 'boolean :group 'imenu)

    (define-custom *imenu-after-jump-hook* '()
      "Hooks called after jumping to a place in the buffer."
      :type 'hook :group 'imenu)

    (define-custom *imenu-sort-function* #f
      "The function to use for sorting the index mouse-menu."
      :type '(choice (const :tag "No sorting" nil)
                     (const :tag "Sort by name" imenu--sort-by-name)
                     (function :tag "Another function"))
      :group 'imenu)
    (set! *imenu-sort-function* *imenu-sort-function*)   ; mutable

    (define-custom *imenu-max-items* 25
      "Maximum number of elements in a mouse menu for Imenu."
      :type 'natnum :group 'imenu)

    (define-custom *imenu-space-replacement* "."
      "The replacement string for spaces in index names."
      :type '(choice string (const nil)) :group 'imenu)

    (define-custom *imenu-level-separator* ":"
      "The separator between index names of different levels."
      :type 'string :group 'imenu)

    (define-custom *imenu-flatten* #f
      "Whether to flatten the list of sections in an imenu or show it nested."
      :type '(choice (const :tag "Show nested list" nil)
                     (const :tag "Flat list with sections as prefix" prefix)
                     (const :tag "Flat list annotated with sections" annotation)
                     (const :tag "Flat list grouped by sections" group))
      :group 'imenu)

    (define-custom *imenu-generic-skip-comments-and-strings* #t
      "When non-nil, ignore text inside comments and strings."
      :type 'boolean :group 'imenu)

    (define-custom *imenu-max-index-time* 5
      "Max time to use when creating imenu indices."
      :type 'number :group 'imenu)

    (define-custom *imenu-allow-duplicate-menu-items* #t
      "Non-nil means that Imenu can include duplicate menu items."
      :type 'boolean :group 'imenu)

    ;;----------------------------------------------------------------
    ;; The buffer-locals (defvar-locals)
    ;;----------------------------------------------------------------

    (define *imenu-generic-expression* (make-parameter #f))
    (define (imenu-generic-expression)
      (imenu-buffer-local *imenu-generic-expression*))
    (define (set!imenu-generic-expression value)
      (set!imenu-buffer-local! *imenu-generic-expression* value))

    (define *imenu-case-fold-search* (make-parameter #t))
    (define (imenu-case-fold-search)
      (imenu-buffer-local *imenu-case-fold-search*))
    (define (set!imenu-case-fold-search value)
      (set!imenu-buffer-local! *imenu-case-fold-search* value))

    (define *imenu-syntax-alist* (make-parameter '()))
    (define (imenu-syntax-alist)
      (imenu-buffer-local *imenu-syntax-alist*))
    (define (set!imenu-syntax-alist value)
      (set!imenu-buffer-local! *imenu-syntax-alist* value))

    (define *imenu-create-index-function* (make-parameter #f))
    (define (imenu-create-index-function)
      (imenu-buffer-local *imenu-create-index-function*))
    (define (set!imenu-create-index-function value)
      (set!imenu-buffer-local! *imenu-create-index-function* value))

    (define *imenu-submenus-on-top* (make-parameter #t))
    (define (imenu-submenus-on-top)
      (imenu-buffer-local *imenu-submenus-on-top*))
    (define (set!imenu-submenus-on-top value)
      (set!imenu-buffer-local! *imenu-submenus-on-top* value))

    (define *imenu-prev-index-position-function* (make-parameter #f))
    (define (imenu-prev-index-position-function)
      (imenu-buffer-local *imenu-prev-index-position-function*))
    (define (set!imenu-prev-index-position-function value)
      (set!imenu-buffer-local! *imenu-prev-index-position-function* value))

    (define *imenu-extract-index-name-function* (make-parameter #f))
    (define (imenu-extract-index-name-function)
      (imenu-buffer-local *imenu-extract-index-name-function*))
    (define (set!imenu-extract-index-name-function value)
      (set!imenu-buffer-local! *imenu-extract-index-name-function* value))

    (define *imenu-name-lookup-function* (make-parameter #f))
    (define (imenu-name-lookup-function)
      (imenu-buffer-local *imenu-name-lookup-function*))
    (define (set!imenu-name-lookup-function value)
      (set!imenu-buffer-local! *imenu-name-lookup-function* value))

    (define *imenu-default-goto-function-variable* (make-parameter #f))
    (define (imenu-default-goto-function-variable)
      (imenu-buffer-local *imenu-default-goto-function-variable*))
    (define (set!imenu-default-goto-function-variable! value)
      (set!imenu-buffer-local! *imenu-default-goto-function-variable* value))

    (define *imenu--index-alist* (make-parameter #f))
    (define (imenu--index-alist)
      (imenu-buffer-local *imenu--index-alist*))
    (define (set!imenu--index-alist value)
      (set!imenu-buffer-local! *imenu--index-alist* value))

    (define imenu--history-list '())
    ;; ^ `imenu.el:363`, a plain variable - "Making this buffer local
    ;; caused it not to work!"

    (define imenu--rescan-item '("*Rescan*" . -99))
    ;; ^ `imenu.el:334`.

    ;;----------------------------------------------------------------
    ;; Support functions
    ;;----------------------------------------------------------------

    (define (imenu--assoc key alist)
      ;; Emacs's `assoc` ignores a non-cons element (the `dummy` head the
      ;; generic builder starts with); Guile's raises.
      ;;--------------------------------------------------------------
      (let loop ((rest alist))
        (cond ((null? rest) #f)
              ((not (pair? (car rest))) (loop (cdr rest)))
              ((equal? (caar rest) key) (car rest))
              (else (loop (cdr rest))))))

    (define (imenu--delete-if pred items)
      ;; Emacs's `cl-delete-if`: the destructive filter the empty-menu
      ;; clean-up uses. This is a fresh list, which no caller can tell
      ;; apart.
      ;;--------------------------------------------------------------
      (let loop ((rest items) (acc '()))
        (cond ((null? rest) (reverse acc))
              ((pred (car rest)) (loop (cdr rest) acc))
              (else (loop (cdr rest) (cons (car rest) acc))))))

    (define (imenu--subalist-p item)
      ;; `imenu.el:302`.
      ;; Emacs's `(listp (cadr item))' is true for any cons, proper or
      ;; not; Scheme's `list?' is not, so the dotted `(NAME . POS)'
      ;; entry a sublist holds made every titled index look flat.
      (and (pair? item)
           (pair? (cdr item))
           (or (null? (cadr item)) (pair? (cadr item)))
           (not (procedure? (cadr item)))))

    (define (imenu-unavailable-error format-string . args)
      ;; `imenu.el:323`, over the `imenu-unavailable` error symbol. This
      ;; tree signals through `error`, whose message is one string.
      ;;--------------------------------------------------------------
      (error (apply format #f format-string args)))

    (define (imenu--sort-by-name item1 item2)
      ;; `imenu.el:374`.
      (string<? (car item1) (car item2)))

    (define (imenu--position pos)
      ;; Emacs's arithmetic converts a marker; this tree's does not.
      (if (markerp pos) (marker-position pos) pos))

    (define (imenu--sort-by-position item1 item2)
      ;; `imenu.el:379`.
      (if (list? (cdr item1))
          (< (imenu--position (cadr item1)) (imenu--position (cadr item2)))
          (< (imenu--position (cdr item1)) (imenu--position (cdr item2)))))

    (define (imenu--relative-position . rest)
      ;; `imenu.el:387`.
      (let* ((reverse (and (pair? rest) (car rest)))
             (total (buffer-size))
             (pos (point))
             (pos (if reverse (- total pos) pos)))
        (quotient (* 100 (- pos 1)) (max total 1))))

    (define (imenu--split list n)
      ;; `imenu.el:396`: "Split LIST into sublists of max length N."
      ;;--------------------------------------------------------------
      (let loop ((remain list) (result '()) (sublist '()) (i 0))
        (cond ((null? remain)
               (let ((result (if (pair? sublist)
                                 (cons (reverse sublist) result)
                                 result)))
                 (reverse result)))
              (else
               (let ((sublist (cons (car remain) sublist))
                     (i (+ i 1))
                     (remain (cdr remain)))
                 (if (= i n)
                     (loop remain (cons (reverse sublist) result) '() 0)
                     (loop remain result sublist i)))))))

    (define (imenu--split-menu menulist title)
      ;; `imenu.el:418`: "Split the alist MENULIST into a nested alist,
      ;; if it is long enough. In any case, add TITLE to the front."
      ;;--------------------------------------------------------------
      (let ((menulist (list-copy menulist))
            (keep-at-top '()))
        (when (member imenu--rescan-item menulist)
          (set! keep-at-top (list imenu--rescan-item))
          (set! menulist (delq imenu--rescan-item menulist)))
        (when (imenu-submenus-on-top)
          (set! menulist
                (let loop ((rest menulist) (kept '()))
                  (cond ((null? rest) (reverse kept))
                        ((imenu--subalist-p (car rest))
                         (set! keep-at-top (cons (car rest) keep-at-top))
                         (loop (cdr rest) kept))
                        (else (loop (cdr rest) (cons (car rest) kept)))))))
        (when (*imenu-sort-function*)
          (set! menulist (sort menulist (*imenu-sort-function*))))
        (when (> (length menulist) (*imenu-max-items*))
          (set! menulist
                (map (lambda (menu)
                       (cons (format #f "From: ~a" (caar menu)) menu))
                     (imenu--split menulist (*imenu-max-items*)))))
        (cons title (append (reverse keep-at-top) menulist))))

    (define (imenu--split-submenus alist)
      ;; `imenu.el:445`.
      (map (lambda (elt)
             (if (imenu--subalist-p elt)
                 (imenu--split-menu (cdr elt) (car elt))
                 elt))
           alist))

    (define (imenu--truncate-items menulist)
      ;; `imenu.el:455`.
      (for-each
       (lambda (item)
         (when (and (number? (*imenu-max-item-length*))
                    (> (string-length (car item)) (*imenu-max-item-length*)))
           (set-car! item (substring (car item) 0 (*imenu-max-item-length*))))
         (when (imenu--subalist-p item)
           (imenu--truncate-items (cdr item))))
       menulist))

    (define (imenu--make-index-alist . rest)
      ;; `imenu.el:466`: "Create an index alist for the definitions in
      ;; the current buffer."
      ;;--------------------------------------------------------------
      (let ((noerror (and (pair? rest) (car rest))))
        (unless (and (imenu--index-alist)
                     (or (not (*imenu-auto-rescan*))
                         (and (*imenu-auto-rescan*)
                              (> (buffer-size) (*imenu-auto-rescan-maxout*)))))
          (set!imenu--index-alist
           (save-excursion
             (save-restriction
               (widen)
               ((imenu-create-index-function)))))
          (imenu--truncate-items (imenu--index-alist)))
        (or (imenu--index-alist) noerror
            (imenu-unavailable-error
             "No items suitable for an index found in this buffer"))
        (unless (imenu--index-alist)
          (set!imenu--index-alist (list #f)))
        (if (*imenu-auto-rescan*)
            (imenu--index-alist)
            (cons imenu--rescan-item (imenu--index-alist)))))

    (define imenu--cleanup-seen '())

    (define (imenu--cleanup . rest)
      ;; `imenu.el:497`: "Find all markers in ALIST and make them point
      ;; nowhere."
      ;;--------------------------------------------------------------
      (let ((alist (and (pair? rest) (car rest))))
        (if alist
            (set! imenu--cleanup-seen (cons alist imenu--cleanup-seen))
            (begin
              (set! alist (imenu--index-alist))
              (set! imenu--cleanup-seen (list alist))))
        (when alist
          (for-each
           (lambda (item)
             (cond
              ((markerp (cdr item)) (set-marker (cdr item) #f))
              ((memq (cdr item) imenu--cleanup-seen) #f)
              ((imenu--subalist-p item) (imenu--cleanup (cdr item)))
              (else #f)))
           alist)
          #t)))

    (define (imenu--in-alist str alist)
      ;; `imenu.el:541`: "Check whether the string STR is contained in
      ;; multi-level ALIST."
      ;;--------------------------------------------------------------
      (let loop ((alist alist) (res #f))
        (cond ((or (null? alist) res) res)
              (else
               (let* ((elt (car alist))
                      (tail (cdr elt))
                      (head (car elt)))
                 (cond ((imenu--subalist-p elt)
                        (let ((r (imenu--in-alist str tail)))
                          (loop (if r '() (cdr alist)) (or r res))))
                       ((if (imenu-name-lookup-function)
                            ((imenu-name-lookup-function) str head)
                            (string=? str head))
                        elt)
                       (else (loop (cdr alist) res))))))))

    (define (imenu-default-create-index-function)
      ;; `imenu.el:579`. The two-variable method and the generic method;
      ;; `imenu-max-index-time`'s loop guard is carried.
      ;;--------------------------------------------------------------
      (cond
       ((and (imenu-prev-index-position-function)
             (imenu-extract-index-name-function))
        (let ((index-alist '())
              (pos (point-max))
              (start (float-time)))
          (goto-char pos)
          (let loop ()
            (when (and ((imenu-prev-index-position-function))
                       (< (- (float-time) start) (*imenu-max-index-time*)))
              (when (< (point) pos)
                (error "Infinite loop at ~a:~a: imenu-prev-index-position-function does not move point"
                       (buffer-name) pos))
              (set! pos (point))
              (let ((name (save-excursion ((imenu-extract-index-name-function)))))
                (when (string? name)
                  (set! index-alist
                        (cons (cons name
                                    (if (*imenu-use-markers*)
                                        (copy-marker (point) #t)
                                        (point)))
                              index-alist))))
              (loop)))
          index-alist))
       ((imenu-generic-expression)
        (imenu--generic-function (imenu-generic-expression)))
       (else
        (imenu-unavailable-error
         "This buffer cannot use `imenu-default-create-index-function'"))))

    ;; The variable's default, which Emacs writes as the symbol and this
    ;; tree needs the procedure for: set once the function exists.
    (*imenu-create-index-function* imenu-default-create-index-function)
    (*imenu-prev-index-position-function* beginning-of-defun)

    (define (imenu--generic-function patterns)
      ;; `imenu.el:634`: "Return an index alist of the current buffer
      ;; based on PATTERNS."
      ;;--------------------------------------------------------------
      (let* ((index-alist (list 'dummy))
             (case-fold-search
              (if (or (local-variable-p *imenu-case-fold-search*)
                      (not (local-variable-p *font-lock-defaults*)))
                  (imenu-case-fold-search)
                  (nth 2 (font-lock-defaults))))
             (start-time (float-time))
             (table (copy-syntax-table (syntax-table)))
             (slist (imenu-syntax-alist)))
        ;; "Modify the syntax table used while matching regexps."
        (for-each
         (lambda (syn)
           (if (number? (car syn))
               (modify-syntax-entry (car syn) (cdr syn) table)
               (for-each (lambda (c)
                           (modify-syntax-entry c (cdr syn) table))
                         (car syn))))
         slist)
        (goto-char (point-max))
        (with-syntax-table
         table
         (lambda ()
           (save-match-data
             (parameterize ((*case-fold-search* case-fold-search))
               ;; "Map over the elements of imenu-generic-expression."
               (for-each
                (lambda (pat)
                  (let ((menu-title (car pat))
                        (regexp (nth 1 pat))
                        (index (nth 2 pat))
                        (function (nth 3 pat))
                        (rest (nthcdr 4 pat))
                        (start #f) (beg #f))
                    (goto-char (point-max))
                    (let loop ()
                      (when (and (if (procedure? regexp)
                                     (regexp)
                                     (and (re-search-backward regexp #f #t)
                                          ;; The renderer does not honour
                                          ;; `invisible', so every
                                          ;; definition is visible.
                                          #t))
                                 (not (= (match-beginning 0) (match-end 0)))
                                 (or (< (- (float-time) start-time)
                                        (*imenu-max-index-time*))
                                     (begin
                                       (message "`imenu-max-index-time' exceeded")
                                       #f)))
                        (set! start (point))
                        (goto-char (match-beginning index))
                        (beginning-of-line)
                        (set! beg (point))
                        (unless (imenu--assoc menu-title index-alist)
                          (set! index-alist
                                (cons (list menu-title) index-alist)))
                        (when (*imenu-use-markers*)
                          (set! beg (copy-marker beg #t)))
                        (let* ((item (if function
                                         (append (list (match-string-no-properties index)
                                                       beg function)
                                                 rest)
                                         (cons (match-string-no-properties index)
                                               beg)))
                               (menu (imenu--assoc menu-title index-alist)))
                          (unless (or (member item (cdr menu))
                                      (and (*imenu-generic-skip-comments-and-strings*)
                                           (save-excursion
                                             (goto-char start)
                                             (nth 8 (syntax-ppss)))))
                            (set-cdr! menu (cons item (cdr menu)))))
                        (goto-char start)
                        (loop)))))
                patterns)))))
        ;; "Sort each submenu by position."
        (for-each
         (lambda (item)
           (when (list? item)
             (set-cdr! item (sort (cdr item) imenu--sort-by-position))))
         index-alist)
        ;; "Remove any empty menus."
        (set! index-alist
              (imenu--delete-if
               (lambda (it) (and (pair? it) (null? (cdr it))))
               index-alist))
        (let ((main-element (imenu--assoc #f index-alist)))
          (append (delq main-element (delq 'dummy index-alist))
                  (if main-element (cdr main-element) '())))))

    (define (imenu-find-default guess completions)
      ;; `imenu.el:759`.
      (call/cc
       (lambda (return)
         (parameterize ((*case-fold-search* #t))
           (if (imenu--assoc guess completions)
               guess
               (let ((res #f))
                 (for-each
                  (lambda (re)
                    (unless res
                      (for-each (lambda (x)
                                  (when (and (not res) (string-match re (car x)))
                                    (set! res (car x))))
                                completions)))
                  (list (string-append "\\`" (regexp-quote guess) "\\'")
                        (string-append "\\`" (regexp-quote guess))
                        (string-append (regexp-quote guess) "\\'")
                        (regexp-quote guess)))
                 (and res (return res))))))))

    (define (imenu--completion-buffer index-alist . rest)
      ;; `imenu.el:771`: "Let the user select from INDEX-ALIST in a
      ;; completion buffer with PROMPT."
      ;;
      ;; The default guess is `thing-at-point`'s; that is not ported, so
      ;; the prompt has no default. The completion metadata Emacs passes
      ;; (`imenu-flatten`'s annotation/group functions) is not carried by
      ;; this tree's `completing-read`.
      ;;--------------------------------------------------------------
      (let* ((prompt (or (and (pair? rest) (car rest)) "Index item: "))
             (prepared
              (if (not (*imenu-space-replacement*))
                  index-alist
                  (map (lambda (item)
                         (cons (substitute-space (car item)) (cdr item)))
                       index-alist)))
             (name (completing-read prompt (map car prepared)
                                    #f #f #f imenu--history-list #f)))
        (let ((choice (imenu--assoc name prepared)))
          (if (imenu--subalist-p choice)
              (imenu--completion-buffer (cdr choice) prompt)
              choice))))

    (define (substitute-space name)
      ;; `(subst-char-in-string ?\\s (aref imenu-space-replacement 0) name)'
      ;; (`imenu.el:785`).
      (string-map (lambda (c)
                    (if (char=? c #\space)
                        (string-ref (*imenu-space-replacement*) 0)
                        c))
                  name))

    (define (imenu-choose-buffer-index . rest)
      ;; `imenu.el:896`: "Let the user select from a buffer index and
      ;; return the chosen index." The mouse menu is not carried; this
      ;; tree always uses the completion path.
      ;;--------------------------------------------------------------
      (let ((prompt (and (pair? rest) (car rest)))
            (alist (and (pair? rest) (pair? (cdr rest)) (cadr rest)))
            (result #t))
        (let loop ()
          (when (eq? result #t)
            (let ((index-alist (if alist alist (imenu--make-index-alist))))
              (when (*imenu-flatten*)
                (set! index-alist (imenu--flatten-index-alist index-alist #t)))
              (set! result (imenu--completion-buffer index-alist prompt))
              (when (equal? result imenu--rescan-item)
                (imenu--cleanup)
                (set!imenu--index-alist #f)
                (set! result #t)
                (loop)))))
        result))

    (define (imenu--flatten-index-alist index-alist . rest)
      ;; `imenu.el:839`: flatten a nested alist, concatenating names when
      ;; CONCAT-NAMES is non-nil. The `imenu-flatten` annotation/group
      ;; values need text-property completion metadata and are not
      ;; carried; the prefix form is.
      ;;--------------------------------------------------------------
      (let ((concat-names (and (pair? rest) (car rest)))
            (prefix (and (pair? rest) (pair? (cdr rest)) (cadr rest))))
        (let loop ((rest index-alist) (acc '()))
          (cond ((null? rest) (reverse acc))
                (else
                 (let* ((item (car rest))
                        (name (car item))
                        (pos (cdr item))
                        (new-prefix (and concat-names
                                         (if prefix
                                             (string-append
                                              prefix (*imenu-level-separator*) name)
                                             name))))
                   (if (not (imenu--subalist-p item))
                       (loop (cdr rest)
                             (cons (cons new-prefix pos) acc))
                       (loop (cdr rest)
                             (append (reverse
                                      (imenu--flatten-index-alist
                                       pos concat-names new-prefix))
                                     acc)))))))))

    (define (imenu-default-goto-function _name position . rest)
      ;; `imenu.el:1019`: "Move to the given position." POSITION may be a
      ;; marker; Emacs's arithmetic converts one and this tree's does not.
      ;;--------------------------------------------------------------
      (let ((position (if (markerp position)
                          (marker-position position)
                          position)))
        (if (or (< position (point-min))
                (> position (point-max)))
            (widen))
        (goto-char position)))

    (*imenu-default-goto-function-variable* imenu-default-goto-function)

    (define-command (imenu . rest)
      "Jump to a place in the buffer chosen using a buffer menu or mouse menu."
      (interactive (list (imenu-choose-buffer-index)))
      (let ((index-item (if (pair? rest) (car rest) #f)))
        (when (string? index-item)
          (set! index-item (imenu--assoc index-item (imenu--make-index-alist))))
        (cond
         ((not index-item) #f)
         ((pair? (cddr index-item))
          ;; `(,name ,pos ,fn . ,args)'.
          (let ((name (car index-item))
                (pos (cadr index-item))
                (fn (caddr index-item))
                (args (cdddr index-item)))
            (push-mark #f #t)
            (apply fn name pos args)
            (run-hooks (*imenu-after-jump-hook*)))
          #f)
         ((pair? (cdr index-item))
          ;; `(,name . ,pos)'.
          (imenu (list (car index-item) (cdr index-item)
                       imenu-default-goto-function)))
         (else (error "Unknown imenu item: ~S" index-item)))))

    (define (imenu-flush-cache)
      ;; `imenu.el:1049`.
      (imenu--cleanup)
      (set!imenu--index-alist #f))

    ))
