(define-library (schemacs editor derived)
  ;; This library mirrors GNU Emacs's `lisp/emacs-lisp/derived.el' - the
  ;; macro a major mode is defined with, and the names it makes.
  ;;
  ;; One thing cannot be transcribed and is named rather than faked.
  ;; Emacs's macro builds its names from the mode's *symbol*: it defines
  ;; `CHILD-map', `CHILD-hook', `CHILD-syntax-table' and
  ;; `CHILD-abbrev-table' by concatenating, which is `derived-mode-map-name'
  ;; and its three siblings. There is no variable registry in this tree -
  ;; the same thing `xdisp.sld' notes about `mode-line-format' resolving a
  ;; symbol to nothing - so a symbol cannot be turned back into a
  ;; variable and the macro cannot invent those names. The caller names
  ;; the keymap and the hook instead, and the mode is defined the same
  ;; way otherwise:
  ;;
  ;;   (define-derived-mode (special-mode #f "Special" special-mode-map
  ;;                                      special-mode-hook)
  ;;     (set!buffer-read-only (current-buffer) #t))
  ;;
  ;; The four name helpers are still here, because they are what the
  ;; names *are* - a mode defined with the naming convention spelled out
  ;; gets the names Emacs would have given it.

  (import
    (scheme base)
    (scheme char)
    ;; `filter` is `remq`'s stand-in in the cycle-breaking branch of
    ;; `derived-mode-all-parents`.
    (only (guile) filter)
    (prefix (schemacs editor keymap) km:)
    (only (schemacs editor buffer)
          current-local-map kill-all-local-variables major-mode set!major-mode
          set!mode-name use-local-map)
    (only (schemacs editor command) register-command!)
    ;; `get` and `put` - the symbol properties a mode's parentage and its
    ;; cached parent list live in. `fns.c`'s, and exported from
    ;; `intervals.sld`; that library is below this one.
    (only (schemacs editor intervals) get put)
    (only (schemacs editor keymap) keymap-parent set-keymap-parent)
    (only (schemacs editor subr) delay-mode-hooks merge-ordered-lists
          run-mode-hooks)
    (only (schemacs editor syntax) set-syntax-table)
    )

  (export
   define-derived-mode
   derived-mode-abbrev-table-name
   derived-mode-hook-name
   derived-mode-map-name
   derived-mode-syntax-table-name
   ;; `subr.el`'s, placed here because they read a buffer's `major-mode` -
   ;; see the note on them below.
   derived-mode-p provided-mode-derived-p derived-mode-all-parents
   derived-mode-set-parent derived-mode-add-parents derived-mode--flush
   )

  (begin

    (define (derived-mode-map-name mode)
      ;; GNU Emacs's `derived-mode-map-name' (derived.el): the symbol
      ;; MODE's keymap is named by - `foo-mode' gives `foo-mode-map'.
      ;;--------------------------------------------------------------
      (string->symbol (string-append (symbol->string mode) "-map")))

    (define (derived-mode-hook-name mode)
      ;; GNU Emacs's `derived-mode-hook-name' (derived.el): "The hook
      ;; will be named `foo-mode-hook'" for `foo-mode'.
      ;;--------------------------------------------------------------
      (string->symbol (string-append (symbol->string mode) "-hook")))

    (define (derived-mode-syntax-table-name mode)
      ;; GNU Emacs's `derived-mode-syntax-table-name' (derived.el).
      ;;--------------------------------------------------------------
      (string->symbol (string-append (symbol->string mode) "-syntax-table")))

    (define (derived-mode-abbrev-table-name mode)
      ;; GNU Emacs's `derived-mode-abbrev-table-name' (derived.el).
      ;;--------------------------------------------------------------
      (string->symbol (string-append (symbol->string mode) "-abbrev-table")))

    ;;----------------------------------------------------------------
    ;; `derived-mode-p' and the parentage it reads
    ;; (`subr.el:2984-3160')
    ;;----------------------------------------------------------------
    ;;
    ;; **Placement departure.** These six are `subr.el`'s, not
    ;; `derived.el`'s. They live here because `subr` cannot see a buffer -
    ;; this tree's `major-mode` is `buffer.c`'s and lives in `(schemacs
    ;; editor buffer)` - and this library already imports that one. It is
    ;; the same seam `locate-file-internal` took into `fileio.sld`: the
    ;; library that holds the primitives the function is built on.
    ;;
    ;; What they are for: `cl-indent.el` asks `(derived-mode-p
    ;; 'emacs-lisp-mode)` twice, and `derived-mode-p` is also how
    ;; `define-derived-mode`'s parentage becomes visible to anything at
    ;; all. Emacs records it with `(put CHILD 'derived-mode-parent
    ;; PARENT)' at definition time, caches the transitive answer, and
    ;; flushes the cache when a mode gains a parent later - that cache is
    ;; the whole reason this is more than a `while' loop over `get'.

    (define (derived-mode--flush mode)
      ;; GNU Emacs's `derived-mode--flush' (`subr.el:3138'): drop MODE's
      ;; cached parent list, and do the same for every mode that named it
      ;; a parent - their cached answers are derived from this one's.
      ;;--------------------------------------------------------------
      (put mode 'derived-mode--all-parents #f)
      (let ((followers (get mode 'derived-mode--followers)))
        (when followers
          (put mode 'derived-mode--followers #f)
          (for-each derived-mode--flush followers))))

    (define (derived-mode-set-parent mode parent)
      ;; GNU Emacs's `derived-mode-set-parent' (`subr.el:3133'):
      ;; "Declare PARENT to be the parent of MODE."
      ;;--------------------------------------------------------------
      (put mode 'derived-mode-parent parent)
      (derived-mode--flush mode))

    (define (derived-mode-add-parents mode extra-parents)
      ;; GNU Emacs's `derived-mode-add-parents' (`subr.el:3141'): "Add
      ;; EXTRA-PARENTS to the parents of MODE. Declares the parents of
      ;; MODE to be its main parent (as defined in `define-derived-mode')
      ;; plus EXTRA-PARENTS, which should be a list of symbols."
      ;;--------------------------------------------------------------
      (put mode 'derived-mode-extra-parents extra-parents)
      (derived-mode--flush mode))

    (define (derived-mode-all-parents mode . args)
      ;; GNU Emacs's `derived-mode-all-parents' (`subr.el:3048'): "Return
      ;; all the parents of MODE, starting with MODE."
      ;;
      ;; The second argument is `known-children', for the recursion's own
      ;; use - what stops a cycle in the hierarchy from looping for ever.
      ;;--------------------------------------------------------------
      (let ((known-children (if (pair? args) (car args) '()))
            (ps (get mode 'derived-mode--all-parents)))
        (cond
         (ps ps)
         ((memq mode known-children)
          ;; "These things happen, better not get all worked up about it.
          ;; But do try to return something meaningful."
          (memq mode (reverse known-children)))
         (else
          (let* ((new-children (cons mode known-children))
                 (get-all-parents
                  (lambda (parent)
                    ;; "Can't use `cl-lib' here (nor `gv'):-(" - the
                    ;; follower bookkeeping: PARENT remembers that MODE
                    ;; derived from it, so a later `derived-mode-set-parent'
                    ;; on PARENT can flush MODE's cached answer.
                    (let ((followers (get parent 'derived-mode--followers)))
                      (unless (and followers (memq mode followers))
                        (put parent 'derived-mode--followers
                             (cons mode (or followers '())))))
                    (derived-mode-all-parents parent new-children)))
                 ;; "(let ((alias (symbol-function mode))) (and (symbolp
                 ;; alias) alias))" - a mode that is an alias, its
                 ;; function cell holding another *symbol*. There are no
                 ;; function cells here, so a mode is never an alias.
                 (parent (get mode 'derived-mode-parent))
                 (extras (get mode 'derived-mode-extra-parents))
                 (all-parents
                  (merge-ordered-lists
                   (cons (if (and parent
                                  (not (and (pair? extras)
                                            (memq parent extras))))
                             (get-all-parents parent)
                             #f)
                         (if (pair? extras)
                             (map get-all-parents extras)
                             '())))))
            (if (and (memq mode all-parents) known-children)
                ;; "Cache the result unless it was affected by
                ;; `known-children' because of a cycle."
                (cons mode (filter (lambda (x) (not (eq? x mode)))
                                   all-parents))
                (put mode 'derived-mode--all-parents
                     (cons mode all-parents))))))))

    (define (provided-mode-derived-p mode modes . old-modes)
      ;; GNU Emacs's `provided-mode-derived-p' (`subr.el:3105'): "Non-nil
      ;; if MODE is derived from a mode that is a member of the list
      ;; MODES. MODES can also be a single mode instead of a list."
      ;;
      ;; Answers the matching *mode symbol*, as Emacs does, and `#f' for
      ;; Elisp's nil.
      ;;--------------------------------------------------------------
      (let* ((modes (cond ((pair? old-modes) (cons modes old-modes))
                          ((or (pair? modes) (null? modes)) modes)
                          (else (list modes))))
             (ps (derived-mode-all-parents mode)))
        (let loop ((ms modes))
          (cond ((null? ms) #f)
                ((memq (car ms) ps) (car ms))
                (else (loop (cdr ms)))))))

    (define (derived-mode-p modes . old-modes)
      ;; GNU Emacs's `derived-mode-p' (`subr.el:3123'): "Return non-nil if
      ;; the current major mode is derived from one of MODES. MODES
      ;; should be a list of symbols or a single mode symbol instead of a
      ;; list."
      ;;--------------------------------------------------------------
      (provided-mode-derived-p (major-mode)
                               (if (pair? old-modes)
                                   (cons modes old-modes)
                                   modes)))

    (define-syntax define-derived-mode
      ;; GNU Emacs's `define-derived-mode' (derived.el:114): "Create a
      ;; new mode CHILD which is a variant of an existing mode PARENT."
      ;; The generated mode does what the C's does, in the C's order:
      ;;
      ;;   (delay-mode-hooks
      ;;     (PARENT)                    ; or `kill-all-local-variables'
      ;;     (setq major-mode 'CHILD)
      ;;     (setq mode-name NAME)
      ;;     (unless (keymap-parent CHILD-map)
      ;;       (set-keymap-parent CHILD-map (current-local-map)))
      ;;     (use-local-map CHILD-map)
      ;;     (set-syntax-table SYNTAX-TABLE)     ; when one is given
      ;;     BODY ...)
      ;;   (run-mode-hooks 'CHILD-hook)
      ;;
      ;; CHILD and PARENT are names, NAME is the string the mode line
      ;; shows, MAP and HOOK are the mode's keymap and its hook, and the
      ;; sixth element - when a mode has one of its own - is its syntax
      ;; table. Emacs's macro *makes* those names from CHILD; this one is
      ;; handed them, for the reason in the library comment above.
      ;;
      ;; PARENT is the parent mode's name, or `#f' for none - which is
      ;; Emacs's nil, and means the mode starts from
      ;; `kill-all-local-variables'.
      ;;
      ;; Not ported: the abbrev table argument (`:abbrev-table'), and
      ;; `:group', `:after-hook', `:interactive', the `mode-class'
      ;; property, and `derived-mode-make-docstring'.
      ;;--------------------------------------------------------------
      (syntax-rules ()
        ((_ (child parent name map hook) docstring body ...)
         (begin
           (derived-mode-set-parent 'child (if (eq? 'parent 'fundamental-mode) #f 'parent))
           (define (child)
             docstring
             (delay-mode-hooks
              (lambda ()
                (if (and parent (not (eq? 'parent 'fundamental-mode)))
                    (parent)
                    (kill-all-local-variables))
                (set!major-mode 'child)
                (set!mode-name name)
                (when (and parent (not (keymap-parent map)))
                  (set-keymap-parent map (current-local-map)))
                (use-local-map map)
                body ...))
             (run-mode-hooks hook))
           (register-command! child #f)))
        ((_ (child parent name map hook) body ...)
         (begin
           (derived-mode-set-parent 'child (if (eq? 'parent 'fundamental-mode) #f 'parent))
           (define (child)
             (delay-mode-hooks
              (lambda ()
                (if (and parent (not (eq? 'parent 'fundamental-mode)))
                    (parent)
                    (kill-all-local-variables))
                (set!major-mode 'child)
                (set!mode-name name)
                (when (and parent (not (keymap-parent map)))
                  (set-keymap-parent map (current-local-map)))
                (use-local-map map)
                body ...))
             (run-mode-hooks hook))
           (register-command! child #f)))
        ((_ (child parent name map hook syntax) docstring body ...)
         (begin
           (derived-mode-set-parent 'child (if (eq? 'parent 'fundamental-mode) #f 'parent))
           (define (child)
             docstring
             (delay-mode-hooks
              (lambda ()
                (if (and parent (not (eq? 'parent 'fundamental-mode)))
                    (parent)
                    (kill-all-local-variables))
                (set!major-mode 'child)
                (set!mode-name name)
                (when (and parent (not (keymap-parent map)))
                  (set-keymap-parent map (current-local-map)))
                (use-local-map map)
                (when syntax (set-syntax-table syntax))
                body ...))
             (run-mode-hooks hook))
           (register-command! child #f)))
        ((_ (child parent name map hook syntax) body ...)
         (begin
           (derived-mode-set-parent 'child (if (eq? 'parent 'fundamental-mode) #f 'parent))
           (define (child)
             (delay-mode-hooks
              (lambda ()
                (if (and parent (not (eq? 'parent 'fundamental-mode)))
                    (parent)
                    (kill-all-local-variables))
                (set!major-mode 'child)
                (set!mode-name name)
                (when (and parent (not (keymap-parent map)))
                  (set-keymap-parent map (current-local-map)))
                (use-local-map map)
                (when syntax (set-syntax-table syntax))
                body ...))
             (run-mode-hooks hook))
           (register-command! child #f)))))

    ))