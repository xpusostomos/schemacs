(define-library (schemacs editor subr)
  ;; This library mirrors GNU Emacs's `subr.el': the small general
  ;; functions the rest of Emacs is written in terms of.
  ;;
  ;; What is here so far is one of them, `add-to-history', which the kill
  ;; ring and the mark ring both push onto. Subr is enormous and mostly
  ;; elisp-layer; it grows as the things that need it arrive.

  (import
    (scheme base)
    ;; `history-length' and `history-delete-duplicates' are `minibuf.c''s
    ;; variables, and `add-to-history' reads them for the maximum length
    ;; when the caller does not give one.
    (only (schemacs editor minibuf)
          *history-delete-duplicates* *history-length*)
    ;; `delete' is Guile's - R7RS has no list `delete' - and `logand' is
    ;; `key-parse''s control-character folding.
    ;; `logior' and `lognot' are the event model's bit arithmetic, beside
    ;; the `logand' `key-parse' already folds control characters with, and
    ;; `filter' orders a symbol event's modifiers.
    (only (guile) delete filter logand logior lognot string-contains)
    ;; `char-downcase' is `event-basic-type''s.
    (scheme char)
    ;; `string-prefix-p' compares with `compare-strings', which is
    ;; fns.c's and lives in `(schemacs editor fns)'. That library is
    ;; below this one - it imports none of subr - so this is not a
    ;; cycle.
    (only (schemacs editor fns) compare-strings)
    ;; The key event model and `kbd' live in `character.sld', the lowest
    ;; editor library - see its export note. They are re-exported from
    ;; here so that a library importing `(schemacs editor subr) kbd' still
    ;; finds it.
    (only (schemacs editor character)
          kbd char-alt char-super char-hyper char-shift char-ctl char-meta
          parse-solitary-modifier make-ctrl-char
          parse-modifiers-uncached event-symbol-elements
          event-modifiers event-basic-type apply-modifiers event-convert-list)
    )

  (export
   add-to-history
   ;; `minor-mode-alist' and the function that fills it. See the note on
   ;; `add-minor-mode' for why the alist lives here and not with the mode
   ;; line that reads it.
   *minor-mode-alist* *minor-mode-list* add-minor-mode
   regexp-unmatchable
   string-prefix-p
   string-replace
   ;; The key event model. `char-alt' and the five beside it are the C's
   ;; `CHAR_*'; the rest are `subr.el''s two decomposition functions,
   ;; `keyboard.c''s way back, and the three C functions that way back
   ;; rests on.
   char-alt char-super char-hyper char-shift char-ctl char-meta
   parse-solitary-modifier make-ctrl-char
   parse-modifiers-uncached event-symbol-elements
   event-modifiers event-basic-type apply-modifiers event-convert-list
   run-hook-with-args
   run-hook-with-args-until-success
   *after-change-major-mode-hook*
   *change-major-mode-after-body-hook*
   *delayed-after-hook-functions*
   *delayed-mode-hooks*
   *delay-mode-hooks*
   delay-mode-hooks
   ignore
   run-hooks
   run-mode-hooks
   kbd
   nthcdr
   ;; `nth' and the `posn-' cluster - see the note on them below.
   nth event-start event-end
   posn-window posn-area posn-point posn-x-y
   )

  (begin

    (define regexp-unmatchable "\\`a\\`")
    ;; ^ GNU Emacs's `regexp-unmatchable' (subr.el:7794): "Standard regexp
    ;; guaranteed not to match any string at all." Two beginning-of-buffer
    ;; anchors, which cannot both hold.

    (define (string-prefix-p prefix string . rest)
      ;; GNU Emacs's `string-prefix-p' (subr.el:6246): "Return non-nil if
      ;; STRING begins with PREFIX. PREFIX should be a string; the
      ;; function returns non-nil if the characters at the beginning of
      ;; STRING compare equal with PREFIX. If IGNORE-CASE is non-nil, the
      ;; comparison is done without paying attention to letter-case
      ;; differences."
      ;;
      ;; The answer is the C's `(eq t (compare-strings ...))' - against
      ;; the symbol `t', not against a true value: `compare-strings'
      ;; answers the index of the first difference when they differ, so
      ;; `eq t' is the whole test.
      ;;
      ;; `string-length' and not `length': Emacs's `length' takes a
      ;; string and Guile's does not.
      ;;--------------------------------------------------------------
      (let ((ignore-case (and (pair? rest) (car rest)))
            (prefix-length (string-length prefix)))
        (if (> prefix-length (string-length string))
            #f
            (eq? #t (compare-strings prefix 0 prefix-length
                                     string 0 prefix-length
                                     ignore-case)))))

    (define (string-replace from-string to-string in-string)
      ;; GNU Emacs's `string-replace' (subr.el:6157): "Replace FROM-STRING
      ;; with TO-STRING in IN-STRING each time it occurs."
      ;;
      ;; The C searches with `string-search', which is `string-contains'
      ;; here and answers an index rather than the C's position or nil -
      ;; the two are the same question. An empty FROM-STRING is the C's
      ;; `wrong-length-argument', which is an error here too.
      ;;--------------------------------------------------------------
      (when (string=? from-string "")
        (error "Wrong length argument: 0"))
      (let loop ((start 0) (result '()))
        (let ((pos (string-contains in-string from-string start)))
          (cond
           ((not pos)
            ;; "No replacements were done, so just return the original
            ;; string" - the C's answer when RESULT is still nil
            (if (null? result)
                in-string
                (begin
                  (unless (= start (string-length in-string))
                    (set! result (cons (substring in-string start) result)))
                  (apply string-append (reverse result)))))
           (else
            (loop (+ pos (string-length from-string))
                  (cons to-string
                        (if (= start pos)
                            result
                            (cons (substring in-string start pos) result)))))))))




    ;;------------------------------------------------------------------
    ;; Minor modes
    ;;------------------------------------------------------------------

    (define *minor-mode-list* (make-parameter '()))
    ;; ^ GNU Emacs's `minor-mode-list' (`bindings.el`): "List of
    ;; variables of minor modes. Each element is a variable symbol, whose
    ;; value is t when the minor mode is enabled." The list is not read
    ;; by anything here yet; `add-minor-mode' keeps it because it is one
    ;; of the three things that function maintains.

    (define *minor-mode-alist* (make-parameter (list (list 'overwrite-mode 'overwrite-mode))))
    ;; ^ GNU Emacs's `minor-mode-alist' (`bindings.el:976'): "Alist
    ;; saying how to show minor modes in the mode line. Each element
    ;; looks like (VARIABLE STRING); STRING is included in the mode line
    ;; if VARIABLE's value is non-nil. ... Actually, STRING need not be a
    ;; string; any mode-line construct is okay."
    ;;
    ;; The initial value is bindings.el's own list, of which only the
    ;; `overwrite-mode' entry is carried - `abbrev-mode',
    ;; `auto-fill-function' and `defining-kbd-macro' are not ported.
    ;;
    ;; **Placement, a departure.** Emacs declares this in `bindings.el',
    ;; and this tree declares the other mode-line variables there too
    ;; (`*mode-line-format*' is in `xdisp.sld'). The alist is here
    ;; instead, beside the one function that writes it, because of the
    ;; import graph: `xdisp.sld' imports `simple.sld', which imports this
    ;; library, so an alist that `simple.sld' had to reach could not live
    ;; in `xdisp.sld' - and `define-minor-mode', which is expanded in
    ;; libraries at and below `simple.sld', generates a call to
    ;; `add-minor-mode'.
    ;;
    ;; `overwrite-mode`'s indicator is the *symbol* of the same name and
    ;; not a string, which is the "need not be a string" clause doing
    ;; real work: the construct is evaluated, so what is shown is the
    ;; variable's value - `overwrite-mode-textual` or
    ;; `overwrite-mode-binary` - and then *that* symbol's value, which is
    ;; the string. The mode line does both steps.

    (define (add-minor-mode toggle name . rest)
      ;; GNU Emacs's `add-minor-mode' (`subr.el:3201'): "Register a new
      ;; minor mode. ... TOGGLE is a symbol that is the name of a
      ;; buffer-local variable that is toggled on or off to say whether
      ;; the minor mode is active or not. NAME specifies what will appear
      ;; in the mode line when the minor mode is active. NAME should be
      ;; either a string starting with a space, or a symbol whose value
      ;; is such a string."
      ;;
      ;; "This function shouldn't be used directly -- use
      ;; `define-minor-mode' instead (which will then call this
      ;; function)."
      ;;
      ;; What it maintains: the list above, and the alist entry. A NAME
      ;; of nil adds nothing to the alist - the entry it would add is
      ;; already there, which is how `overwrite-mode' gets its lighter
      ;; from bindings.el rather than from its own definition.
      ;;
      ;; Not carried: KEYMAP and `minor-mode-map-alist' (per-mode keymaps
      ;; are not ported), and the `:included'/`:menu-tag' menu entry,
      ;; which needs a symbol plist and the mode-line menu.
      ;;--------------------------------------------------------------
      (let ((keymap (if (pair? rest) (car rest) #f))
            (after (if (and (pair? rest) (pair? (cdr rest))) (cadr rest) #f))
            (toggle-fun (if (and (pair? rest) (pair? (cdr rest))
                                 (pair? (cddr rest)))
                            (car (cddr rest))
                            #f)))
        (unless (memq toggle (*minor-mode-list*))
          (*minor-mode-list* (cons toggle (*minor-mode-list*))))
        (when name
          (let ((alist (*minor-mode-alist*)))
            (let ((existing (assq toggle alist)))
              (if existing
                  (set-cdr! existing (list name))
                  (*minor-mode-alist*
                   (cons (list toggle name) alist))))))
        keymap after toggle-fun
        #f))

    (define (run-hooks . hooks)
      ;; GNU Emacs's `run-hooks' (subr.el): run each hook in turn. A hook
      ;; is named by a *variable* in Emacs and read by this; here a hook
      ;; is the list of procedures itself - the tree keeps one as a
      ;; `make-parameter' holding a list - so the list is what is passed.
      ;; An argument that is a procedure rather than a list is a single
      ;; function, which is what `run-hooks' does with a non-list value.
      ;;--------------------------------------------------------------
      (for-each (lambda (hook)
                  (cond ((not hook) #f)
                        ((procedure? hook) (hook))
                        (else (for-each (lambda (f) (f)) hook))))
                hooks))

    (define (run-hook-with-args hook . args)
      ;; GNU Emacs's `run-hook-with-args' (`eval.c:2908'): "Run HOOK with
      ;; the specified arguments ARGS. ... Call each function in order
      ;; with arguments ARGS. The final return value is unspecified."
      ;;
      ;; The C is `run_hook_with_args (nargs, args, funcall_nil)'
      ;; (`:2921') - the same walk as the `-until-success' form below,
      ;; with a handler that always answers nil, so every function runs
      ;; and no answer is used. HOOK is the list of procedures rather than
      ;; a symbol naming one, for `run-hooks'' reason.
      ;;--------------------------------------------------------------
      (let loop ((rest (cond ((not hook) '())
                             ((procedure? hook) (list hook))
                             (else hook))))
        (cond ((null? rest) #f)
              (else
               (apply (car rest) args)
               (loop (cdr rest))))))

    (define (run-hook-with-args-until-success hook . args)
      ;; GNU Emacs's `run-hook-with-args-until-success' (`eval.c:2927'):
      ;; "Run HOOK with the specified arguments ARGS. ... Call each
      ;; function in order with arguments ARGS, stopping at the first one
      ;; that returns non-nil, and return that value. Otherwise (if all
      ;; functions return nil, or if there are no functions to call),
      ;; return nil."
      ;;
      ;; HOOK is the list of procedures rather than a symbol naming one,
      ;; as `run-hooks' above takes it, and for the same reason: a hook is
      ;; a parameter here, so its value is what is to hand.
      ;;
      ;; The C's `t' marker in a hook's value - "this hook has a local
      ;; binding; it means to run the global binding too" - is not here.
      ;; A buffer-local half of a hook is not ported, so a hook's value is
      ;; the whole value.
      ;;--------------------------------------------------------------
      (let loop ((rest (cond ((not hook) '())
                             ((procedure? hook) (list hook))
                             (else hook))))
        (cond ((null? rest) #f)
              (else
               (let ((value (apply (car rest) args)))
                 (if value value (loop (cdr rest))))))))

    (define *change-major-mode-after-body-hook* (make-parameter '()))
    ;; ^ GNU Emacs's `change-major-mode-after-body-hook' (`subr.el'):
    ;; "Normal hook run after running the body of `define-derived-mode'."

    (define *after-change-major-mode-hook* (make-parameter '()))
    ;; ^ GNU Emacs's `after-change-major-mode-hook' (`subr.el'): "Normal
    ;; hook run at the end of `run-mode-hooks', which see. ... every
    ;; major mode runs it, whether it is defined with `define-derived-mode'
    ;; or not."

    (define *delay-mode-hooks* (make-parameter #f))
    ;; ^ GNU Emacs's `delay-mode-hooks' (`subr.el'): "Non-nil means
    ;; `run-mode-hooks' should delay running the hooks." A buffer-local
    ;; variable in Emacs and a parameter here, as this tree keeps
    ;; buffer-local flags.

    (define *delayed-mode-hooks* (make-parameter '()))
    ;; ^ GNU Emacs's `delayed-mode-hooks': the hooks a mode asked for
    ;; while the running was delayed, newest first.

    (define *delayed-after-hook-functions* (make-parameter '()))
    ;; ^ GNU Emacs's `delayed-after-hook-functions': what a derived
    ;; mode's `:after-hook' pushed, run at the very end of
    ;; `run-mode-hooks'.

    (define (delay-mode-hooks thunk)
      ;; GNU Emacs's `delay-mode-hooks' (`subr.el':2795): "Execute BODY,
      ;; but delay any `run-mode-hooks'. These hooks will be executed by
      ;; the first following call to `run-mode-hooks' that occurs outside
      ;; any `delay-mode-hooks' form."
      ;;
      ;; A macro in Emacs; a procedure taking the body as a thunk here,
      ;; which is how this tree spells a body-taking form that has no
      ;; syntax of its own to keep.
      ;;--------------------------------------------------------------
      (parameterize ((*delay-mode-hooks* #t)) (thunk)))

    (define (run-mode-hooks . hooks)
      ;; GNU Emacs's `run-mode-hooks' (subr.el:2756): "Run mode hooks
      ;; `delayed-mode-hooks' and HOOKS, or delay HOOKS. ... Otherwise,
      ;; runs hooks in the sequence: `change-major-mode-after-body-hook',
      ;; `delayed-mode-hooks' (in reverse order), HOOKS, then runs
      ;; `hack-local-variables' (if the buffer is visiting a file), runs
      ;; the hook `after-change-major-mode-hook', and finally evaluates
      ;; the functions in `delayed-after-hook-functions'."
      ;;
      ;; Not ported: `hack-local-variables', there being no file-local
      ;; variable machinery here yet. The C's other errand in that gap -
      ;; turning on `parse-sexp-lookup-properties' when
      ;; `syntax-propertize-function' is set - waits for
      ;; `syntax-propertize' too.
      ;;--------------------------------------------------------------
      (if (*delay-mode-hooks*)
          ;; "just adds the HOOKS to the list"
          (*delayed-mode-hooks* (append hooks (*delayed-mode-hooks*)))
          (begin
            (set! hooks (append (reverse (*delayed-mode-hooks*)) hooks))
            (*delayed-mode-hooks* '())
            (apply run-hooks
                   (cons (*change-major-mode-after-body-hook*) hooks))
            (run-hooks (*after-change-major-mode-hook*))
            (let ((after (reverse (*delayed-after-hook-functions*))))
              (*delayed-after-hook-functions* '())
              (for-each (lambda (f) (f)) after)))))

    (define (ignore . _arguments)
      ;; GNU Emacs's `ignore' (`subr.el:501'): accept any arguments, do
      ;; nothing, and answer nil. It is what Emacs binds keys that must be
      ;; received but not acted on to - `[sigusr1]' in
      ;; `special-event-map' - and it is what this tree's resize event is
      ;; bound to: a frame resize is handled by redisplay re-framing, and
      ;; the event only has to be dispatched for the loop to redraw.
      ;;
      ;; Emacs answers nil here, which this tree's `#f' is - and writing
      ;; the word `nil' was an error, not a spelling, and is what the
      ;; "unbound variable: nil" the echo area showed was.
      ;;--------------------------------------------------------------
      #f)

    (define (nthcdr n list)
      ;; GNU Emacs's `nthcdr': the tail of LIST after the first N
      ;; elements - and nil when the list is shorter than that, which is
      ;; the whole point of having it: Scheme's `list-tail' is an error
      ;; there, and Elisp's sloppiness is what the callers rely on.
      ;;--------------------------------------------------------------
      (let loop ((n n) (rest list))
        (if (or (<= n 0) (not (pair? rest)))
            rest
            (loop (- n 1) (cdr rest)))))

    (define (add-to-history history-list newelt . args)
      ;; GNU Emacs's `add-to-history': HISTORY-LIST with NEWELT on the
      ;; front, duplicates of it removed when
      ;; `history-delete-duplicates' says so, and the list cut back to
      ;; MAXELT - which answers with `history-length' when the caller
      ;; does not give one.
      ;;
      ;; It takes the list and answers a new one, rather than taking a
      ;; variable's name as Emacs's does: a Scheme procedure cannot set a
      ;; variable the caller names, so the setting is the caller's.
      ;;--------------------------------------------------------------
      (let* ((maxelt (if (pair? args) (car args) #f))
             (keep-all (if (and (pair? args) (pair? (cdr args)))
                           (cadr args)
                           #f))
             (maxelt (or maxelt (*history-length*))))
        (if (and (list? history-list)
                 (or keep-all
                     (not (string? newelt))
                     (< 0 (string-length newelt)))
                 ;; Elisp's `(car nil)' is nil, so Emacs's test is
                 ;; true for an empty list; Scheme's is an error, so
                 ;; the emptiness is tested for.
                 (or keep-all
                     (not (and (pair? history-list)
                               (equal? (car history-list) newelt)))))
            (let* ((history (if (*history-delete-duplicates*)
                                (delete newelt history-list)
                                history-list))
                   (history (cons newelt history)))
              (cond
               ((not (integer? maxelt)) history)
               ((<= maxelt 0) '())
               (else
                (let ((tail (nthcdr (- maxelt 1) history)))
                  (if (pair? tail) (set-cdr! tail '()))
                  history))))
            history-list)))

    (define (nth n list)
      ;; GNU Emacs's `nth': the Nth element of LIST, or nil - this tree's
      ;; #f - when the list is shorter than that. Built on `nthcdr'
      ;; above, which is the half that exists in a Scheme without
      ;; Elisp's tolerance for running off the end.
      ;;--------------------------------------------------------------
      (let ((tail (nthcdr n list)))
        (and (pair? tail) (car tail))))

    ;;----------------------------------------------------------------
    ;; Positions: the value a mouse event carries
    ;;
    ;; `subr.el''s `posn-' cluster, which is what a command bound to a
    ;; mouse event reads. A mouse event's value is
    ;;
    ;;   (SYMBOL (WINDOW POS-OR-AREA (X . Y) TIMESTAMP))
    ;;
    ;; - SYMBOL is `down-mouse-1' for the press and `mouse-1' for the
    ;; click that follows it - and everything below is a walk of that
    ;; list, as `subr.el''s are.
    ;;
    ;; **`posn-set-point' is not here**, though `subr.el' is where Emacs
    ;; keeps it, for a reason this tree has and Emacs does not: it needs
    ;; `select-window' and `goto-char', and `(schemacs editor frame)'
    ;; imports *this* library, so a definition here could not reach
    ;; them. It lives in `mouse.sld', with the commands that call it.
    ;;------------------------------------------------------------------

    (define (event-start event)
      ;; GNU Emacs's `event-start': where EVENT begins.
      ;;
      ;; Emacs's differs from `event-end' only after a drag, and asks
      ;; `posn-at-point' when handed nil; this asks nothing and answers
      ;; #f for something that is not an event at all, which is the
      ;; shape every caller in this tree wants.
      ;;--------------------------------------------------------------
      (and (pair? event) (nth 1 event)))

    (define (event-end event)
      ;; GNU Emacs's `event-end' (`subr.el:1952'): "Return the ending
      ;; position of EVENT. EVENT should be a click, drag, or key press
      ;; event."
      ;;
      ;; **A drag event carries two positions and a click carries one**,
      ;; which is the whole of the difference from `event-start':
      ;;
      ;;   (mouse-1      POSN)             a click
      ;;   (drag-mouse-1 START-POSN END-POSN)
      ;;
      ;; and Emacs tells them apart by asking whether the *third*
      ;; element is a position: `(nth (if (consp (nth 2 event)) 2 1)
      ;; event)'. A drag that ran off the end of a line and back has a
      ;; third element that is not a position, because Emacs puts the
      ;; click count there instead - `(drag-mouse-1 POSN 2)' - so the
      ;; test is what it is and not "is there a third element".
      ;;
      ;; The `posn-at-point' fallback for a nil event is not carried:
      ;; nothing here asks for the end of an event it does not have.
      ;;--------------------------------------------------------------
      (and (pair? event)
           (nth (if (pair? (nth 2 event)) 2 1) event)))

    (define (posn-window position)
      ;; GNU Emacs's `posn-window': the window the event happened in, or
      ;; the frame when it happened outside every window.
      ;;--------------------------------------------------------------
      (nth 0 position))

    (define (posn-area position)
      ;; GNU Emacs's `posn-area': the symbol naming the part of the
      ;; window - `mode-line', `vertical-border' - or nil (this tree's
      ;; #f) for the text area. The second element is a *position* in
      ;; the text area and a symbol elsewhere, which is what the cons
      ;; test is for.
      ;;--------------------------------------------------------------
      (let ((area (nth 1 position)))
        (let ((area (if (pair? area) (car area) area)))
          (and (symbol? area) area))))

    (define (posn-point position)
      ;; GNU Emacs's `posn-point' (`keyboard.c:13099'): the buffer
      ;; position of POSITION, or nil when it names no buffer location -
      ;; a click on a mode line or a scroll bar. The C answers the
      ;; position as it stands, falls back to the first element of a
      ;; cons, and gives up.
      ;;--------------------------------------------------------------
      (let ((posn (nth 1 position)))
        (cond ((integer? posn) posn)
              ((pair? posn) (car posn))
              (else #f))))

    (define (posn-x-y position)
      ;; GNU Emacs's `posn-x-y': the pixel coordinates, as a pair.
      ;;--------------------------------------------------------------
      (nth 2 position))

    ))
