(define-library (schemacs progmodes cmacexp)
  ;; This library mirrors GNU Emacs's `lisp/progmodes/cmacexp.el' - "expand
  ;; C macros in a region" - whole: `c-macro-expand', its display helper
  ;; and `c-macro-expansion', the noninteractive entry point.
  ;;
  ;; The preprocessor is run through `call-process-region' (`callproc.scm',
  ;; itself `callproc.c'): the buffer's text becomes the child's standard
  ;; input and the child's output is inserted into the `*C Macro
  ;; Expansion*' work buffer, exactly as the Lisp does it. That is why
  ;; this file waited on `call-process-region' and `make-temp-file'.
  ;;
  ;; **Not carried, each named rather than faked**:
  ;;
  ;;   * the Solaris arm of `c-macro-preprocessor''s standard value - it
  ;;     tests `system-configuration', which this tree has no variable
  ;;     for; the remaining three probes are carried;
  ;;   * `msdos-shells' in the error-status test: there is no MS-DOS
  ;;     here, so the C's "and not an MS-DOS shell" arm is the
  ;;     always-true arm;
  ;;   * `with-file-modes' and `files--make-magic-temp-file': no file
  ;;     name handlers, and `make-temp-file-internal' creates 0600 files
  ;;     itself.
  ;;
  ;; **DEPARTURE**: `c-macro-expansion''s "insert `#line` after every
  ;; `#endif`/`#else`" loop compares `(nthcdr 3 (parse-partial-sexp ...))'
  ;; with a five-element literal. Emacs 31's state list is longer than
  ;; five elements, so the comparison is nil in Emacs too and no such
  ;; `#line' is ever inserted; the literal comparison is ported as it
  ;; stands so that a future parse-state shape change behaves the same
  ;; way on both sides.
  ;;--------------------------------------------------------------

  (import
    (scheme base)
    (only (guile) format)
    (only (schemacs custom) define-custom)
    (only (schemacs core syntax-macros) while-e)
    (only (schemacs command) define-command)
    (only (schemacs buffer)
          get-buffer get-buffer-create current-buffer buffer-name
          buffer-file-name default-directory
          bufferp with-current-buffer set-buffer buffer-read-only?
          set!buffer-read-only set-buffer-modified-p buffer-modified-p
          bury-buffer *inhibit-read-only* set-buffer-local-value!
          erase-buffer)
    (only (schemacs editfns)
          point point-min point-max goto-char insert delete-region
          buffer-substring insert-buffer-substring widen buffer-size
          message save-excursion save-restriction bolp forward-line)
    (only (schemacs cmds) beginning-of-line)
    (only (schemacs search)
          string-match match-beginning match-end re-search-backward
          re-search-forward search-forward regexp-quote)
    (only (schemacs syntax) parse-partial-sexp syntax-table set-syntax-table)
    (only (schemacs character) char-to-string)
    (only (schemacs fns) nth nthcdr)
    (only (schemacs simple) count-lines buffer-disable-undo
          exchange-point-and-mark)
    (only (schemacs files)
          make-temp-file temporary-file-directory
          *temporary-file-directory* *small-temporary-file-directory*
          expand-file-name delete-file
          insert-file-contents executable-find kill-buffer)
    (only (schemacs fileio) file-executable-p)
    (only (schemacs diredc) file-attributes file-attribute-size)
    (only (schemacs callproc) call-process-region shell-file-name)
    (only (schemacs window)
          display-buffer get-buffer-window enlarge-window window-min-height)
    (only (schemacs frame) frame-height selected-frame window-total-height
          selected-window select-window)
    (only (schemacs indentc) vertical-motion)
    (only (schemacs minibuffer) read-string)
    (only (schemacs keyboard) sit-for)
    ;; `(require 'cc-mode)': `c-macro-display-buffer' puts its result in
    ;; a real C buffer.
    (only (schemacs progmodes cc-mode) c-mode))

  (export c-macro-expand c-macro-expansion c-macro-display-buffer
          c-macro-buffer-name
          *c-macro-shrink-window-flag* *c-macro-prompt-flag*
          *c-macro-preprocessor* *c-macro-cppflags*)

  (begin

    (define-custom *c-macro-shrink-window-flag* #f
      "Non-nil means shrink the *Macroexpansion* window to fit its contents."
      :type 'boolean
      :group 'c-macro)

    (define-custom *c-macro-prompt-flag* #f
      "Non-nil means `c-macro-expand' will prompt for preprocessor arguments."
      :type 'boolean
      :group 'c-macro)

    (define-custom *c-macro-preprocessor*
      ;; The C's three `locate-file' probes, `locate-file' being
      ;; `file-executable-p' of the candidate on POSIX (`exec-suffixes'
      ;; is `("")' there). The Solaris arm needs `system-configuration',
      ;; which this tree has not got; the last arm is the C's fallback.
      (cond ((file-executable-p "/usr/ccs/lib/cpp") "/usr/ccs/lib/cpp -C")
            ((file-executable-p "/lib/cpp") "/lib/cpp -C")
            ((executable-find "cpp") "cpp -C")
            (else "gcc -E -C -o - -"))
      "The preprocessor used by the cmacexp package.

If you change this, be sure to preserve the `-C' (don't strip comments)
option, or to set an equivalent one."
      :type 'string
      :group 'c-macro)

    (define-custom *c-macro-cppflags* ""
      "Preprocessor flags used by `c-macro-expand'."
      :type 'string
      :group 'c-macro)

    (define c-macro-buffer-name "*Macroexpansion*")

    (define-command (c-macro-expand start end subst)
      "Expand C macros in the region, using the C preprocessor.
Normally display output in temp buffer, but
prefix arg means replace the region with it.

`c-macro-preprocessor' specifies the preprocessor to use.
If the user option `c-macro-prompt-flag' is non-nil
prompt for arguments to the preprocessor \(e.g. `-DDEBUG -I ./include'),
otherwise use `c-macro-cppflags'.

Noninteractive args are START, END, SUBST.
For use inside Lisp programs, see also `c-macro-expansion'."
      (interactive "r\nP")
      (let ((inbuf (current-buffer))
            (displaybuf (if subst
                            (get-buffer c-macro-buffer-name)
                            (get-buffer-create c-macro-buffer-name)))
            (expansion ""))
        ;; "Build the command string."
        (when (*c-macro-prompt-flag*)
          (*c-macro-cppflags* (read-string "Preprocessor arguments: "
                                           (*c-macro-cppflags*))))
        ;; "Decide where to display output."
        (when (and subst
                   (buffer-read-only? inbuf)
                   (not (*inhibit-read-only*))
                   (not (eq? inbuf displaybuf)))
          (message "Buffer is read only: displaying expansion in alternate window")
          (sit-for 2)
          (set! subst #f)
          (unless displaybuf
            (set! displaybuf (get-buffer-create c-macro-buffer-name))))
        ;; "Expand the macro and output it."
        (set! expansion
              (c-macro-expansion start end
                                 (string-append (*c-macro-preprocessor*) " "
                                                (*c-macro-cppflags*))
                                 #t))
        (if subst
            (let ((exchange (= (point) start)))
              (delete-region start end)
              (insert expansion)
              (when exchange (exchange-point-and-mark)))
            (begin
              (set-buffer displaybuf)
              (set!buffer-read-only (current-buffer) #f)
              (buffer-disable-undo displaybuf)
              (erase-buffer)
              (insert expansion)
              (set-buffer-modified-p #f)
              (if (string=? "" expansion)
                  (message "Null expansion")
                  (c-macro-display-buffer))
              (set!buffer-read-only (current-buffer) #t)
              ;; `buffer-auto-save-file-name' is `buffer.c`'s per-buffer
              ;; slot; auto-saving itself is not ported, and setting the
              ;; slot is exactly what Emacs's `setq' does to it.
              (set-buffer-local-value! (current-buffer)
                                       'buffer-auto-save-file-name #f)
              (bury-buffer displaybuf)))))

    (define (c-macro-display-buffer)
      ;; "Display the current buffer in a window which is either just
      ;; large enough to contain the entire buffer, or half the size of
      ;; the screen, whichever is smaller. Do not select the new
      ;; window."
      (goto-char (point-min))
      (c-mode)
      (let* ((oldwinheight (window-total-height))
             (alreadythere (get-buffer-window (current-buffer))) ; the window was already there
             (popped #f))                     ; the window popped changing the layout
        (unless alreadythere
          (display-buffer (current-buffer) #t)
          (set! popped (not (= oldwinheight (window-total-height)))))
        (when (and (*c-macro-shrink-window-flag*) ; "user wants fancy shrinking :\)"
                   (or alreadythere popped))
          ;; "Enlarge up to half screen, or shrink properly."
          (let ((oldwin (selected-window))
                (minheight 0)
                (maxheight 0))
            (save-excursion
              (select-window (get-buffer-window (current-buffer)))
              (set! minheight (if alreadythere
                                  (window-total-height)
                                  (window-min-height)))
              (set! maxheight (quotient (frame-height (selected-frame)) 2))
              (enlarge-window (- (min maxheight
                                      (max minheight
                                           (+ 2 (vertical-motion (point-max)))))
                                 (window-total-height)))
              (goto-char (point-min))
              (select-window oldwin))))))

    (define (c-macro-expansion start end cppcommand . display-args)
      ;; "Run a preprocessor on region and return the output as a string.
      ;; Expand the region between START and END in the current buffer
      ;; using the shell command CPPCOMMAND (e.g. \"/lib/cpp -C
      ;; -DDEBUG\"). Be sure to use a -C (don't strip comments) or
      ;; equivalent option. Optional arg DISPLAY non-nil means show
      ;; messages in the echo area."
      ;;
      ;; "Copy the current buffer's contents to a temporary hidden
      ;; buffer. Delete from END to end of buffer. Insert a preprocessor
      ;; #line directive at START and after each #endif following START
      ;; that are not inside a comment or a string. Put all the strings
      ;; thus inserted (without the \"line\" substring) in a list named
      ;; linelist. If START is inside a comment, prepend \"*/\" and
      ;; append \"/*\" to the #line directive. If inside a string,
      ;; prepend and append \"\\\"\". Preprocess the buffer contents,
      ;; then look for all the lines stored in linelist starting from
      ;; end of buffer. The last line so found is where START was, so
      ;; return the substring from point to end of buffer."
      (let ((display (if (pair? display-args) (car display-args) #f)))
        (let* ((inbuf (current-buffer))
               (outbuf (get-buffer-create " *C Macro Expansion*"))
               (filename (let ((file (buffer-file-name inbuf)))
                           (if (and file
                                    (string-match (regexp-quote
                                                   (default-directory))
                                                  file))
                               (substring file (match-end 0))
                               (buffer-name inbuf))))
               (mymsg (format #f "Invoking ~a~a~a on region..."
                              (*c-macro-preprocessor*)
                              (if (string=? "" (*c-macro-cppflags*)) "" " ")
                              (*c-macro-cppflags*)))
               (uniquestring "??? !!! ??? start of c-macro expansion ??? !!! ???")
               (startlinenum 0)
               (linenum 0)
               (startstat '())
               (startmarker "")
               (exit-status 0)
               (tempname (make-temp-file
                          (expand-file-name
                           "cmacexp"
                           (or (*small-temporary-file-directory*)
                               (temporary-file-directory))))))
          ;; `(unwind-protect BODY (kill-buffer outbuf))' is a
          ;; `dynamic-wind' here; see `cc-defs.scm`'s note on the tree's
          ;; spelling.
          (dynamic-wind
           (lambda () #f)
           (lambda ()
             (save-excursion
               (save-restriction
                 (widen)
                 (let ((in-syntax-table (syntax-table)))
                   (set-buffer outbuf)
                   (set!buffer-read-only (current-buffer) #f)
                   (erase-buffer)
                   (set-syntax-table in-syntax-table))
                 (insert-buffer-substring inbuf 1 end))

               ;; "We have copied inbuf to outbuf. Point is at end of
               ;; outbuf. Insert a newline at the end, so cpp can
               ;; correctly parse a token ending at END."
               (insert "\n")

               ;; "Save sexp status and line number at START."
               (set! startstat (parse-partial-sexp 1 start))
               (set! startlinenum (+ (count-lines 1 (point))
                                     (if (bolp) 1 0)))

               ;; "Now we insert the #line directives after all #endif or
               ;; #else following START going backward, so the lines we
               ;; insert don't change the line numbers."
               (goto-char (point-max))
               (while-e (re-search-backward "\n#\\(endif\\|else\\)\\>" start 'move)
                 ;; "neither in string nor in comment nor after quote"
                 ;; The literal is Emacs's five-element list; a
                 ;; parse state is longer than five elements on both
                 ;; sides, so this is nil, as it is in Emacs 31 - see
                 ;; the header.
                 (if (equal? (nthcdr 3 (parse-partial-sexp start (point)
                                                           #f #f startstat))
                             '(nil nil nil 0 nil))
                     (begin
                       (goto-char (match-end 0))
                       (set! linenum (+ startlinenum
                                        (count-lines start (point))))
                       (insert (format #f "\n#line ~a \"~a\"\n"
                                       linenum filename))
                       (goto-char (match-beginning 0)))))

               ;; "Now we are at START. Insert the first #line directive.
               ;; This must work even inside a string or comment, or
               ;; after a quote."
               (let* ((startinstring (nth 3 startstat))
                      (startincomment (nth 4 startstat))
                      (startafterquote (nth 5 startstat))
                      (startinbcomment (nth 7 startstat)))
                 (insert (if startafterquote " " "")
                         (cond (startinstring
                                (char-to-string startinstring))
                               (startincomment "*/")
                               (else ""))
                         (begin
                           (set! startmarker
                                 (string-append
                                  "\n" uniquestring
                                  (cond (startinstring
                                         (char-to-string startinstring))
                                        (startincomment "/*")
                                        (startinbcomment "//")
                                        (else ""))
                                  (if startafterquote "\\" "")))
                           startmarker)
                         (format #f "\n#line ~a \"~a\"\n"
                                 startlinenum filename)))

               ;; "Call the preprocessor."
               (if display (message "%s" mymsg))
               (set! exit-status
                     (call-process-region 1 (point-max)
                                          shell-file-name
                                          #t (list #t tempname) #f "-c"
                                          cppcommand))
               (if display (message "%s" (string-append mymsg "done")))
               (if (= (buffer-size) 0)
                   ;; "Empty output is normal after a fatal error."
                   (insert "\nPreprocessor produced no output\n")
                   ;; "Find and delete the mark of the start of the
                   ;; expansion."
                   ;; "Look for `# nn \"file.c\"' lines and delete them."
                   (begin
                     (goto-char (point-min))
                     (when (search-forward startmarker #f #t)
                       (delete-region 1 (point)))))
               (while-e (re-search-forward (string-append
                                          "^# [0-9]+ \""
                                          (regexp-quote filename)
                                          "\"")
                                         #f #t)
                 (beginning-of-line)
                 (let ((beg (point)))
                   (forward-line 1)
                   (delete-region beg (point))))

               ;; "If CPP got errors, show them at the beginning." There
               ;; are no MS-DOS shells here, so the C's first disjunct is
               ;; just the exit-status test.
               (or (= exit-status 0)
                   (= 0 (file-attribute-size (file-attributes
                                              (expand-file-name tempname))))
                   (begin
                     (goto-char (point-min))
                     ;; "Put the messages inside a comment, so they won't
                     ;; get in the way of font-lock, highlighting etc."
                     (insert
                      (format #f
                              "/* Preprocessor terminated with status ~a\n\n   Messages from '~a':\n\n"
                              exit-status cppcommand))
                     (goto-char (+ (point)
                                   (nth 1 (insert-file-contents tempname))))
                     (insert "\n\n*/\n")))
               (delete-file tempname)

               ;; "Compute the return value, keeping in account the space
               ;; inserted at the end of the buffer."
               (buffer-substring 1 (max 1 (- (point-max) 1)))))
           (lambda () (kill-buffer outbuf))))))

    ))
