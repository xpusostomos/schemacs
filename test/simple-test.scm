;; Tests for `simple.el''s undo tail - `undo-more' and the change-group
;; primitives `atomic-change-group' is built on. The expectations are
;; `emacs -Q --batch''s on the same buffers:
;;
;;   (atomic-change-group (insert "X"))             -> "abcX"
;;   the same body with an error                   -> "abc"
;;   both, with undo disabled                      -> the text above,
;;                                                    buffer-undo-list t
;;   undo-more one group                           -> "abc", pending t

(import
 (scheme base)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (schemacs buffer) allocate-buffer set-buffer buffer-local-value)
 (only (schemacs editfns) insert point point-max goto-char
       buffer-substring-no-properties)
 (only (schemacs simple)
       undo-more atomic-change-group *pending-undo-list*
       add-to-invisibility-spec remove-from-invisibility-spec
       kill-whole-line forward-visible-line end-of-visible-line
       *last-command* current-kill
       next-error previous-error recenter-top-bottom
       special-mode special-mode-hook)
 (only (schemacs textprop) put-text-property)
 (only (schemacs keyboard) key-binding)
 (only (schemacs subr) kbd add-hook remove-hook)
 (only (schemacs undo)
       text-editor-undo-boundary! text-editor-undo-disable!
       text-editor-undo-list))

(test-begin "schemacs_simple_undo")

(define (fresh)
  (let ((b (allocate-buffer)))
    (set-buffer b)
    b))

(define (text)
  (buffer-substring-no-properties 1 (point-max)))

;;----------------------------------------------------------------------
;; undo-more
;;----------------------------------------------------------------------

(let ((b (fresh)))
  (insert "abc")
  (text-editor-undo-boundary! b)
  (insert "X")
  (test-equal "the buffer holds both edits" "abcX" (text))
  (parameterize ((*pending-undo-list* (text-editor-undo-list b)))
    (undo-more 1))
  (test-equal "undo-more undoes the most recent group" "abc" (text)))

(let ((b (fresh)))
  (insert "X")
  (parameterize ((*pending-undo-list* (text-editor-undo-list b)))
    (undo-more 1)
    (test-equal "at the end of the list pending-undo-list becomes t" #t
                (*pending-undo-list*)))
  (test-equal "and the change is undone" "" (text)))

;;----------------------------------------------------------------------
;; atomic-change-group
;;----------------------------------------------------------------------

(let ((b (fresh)))
  (insert "abc")
  (atomic-change-group (insert "X"))
  (test-equal "a successful group keeps its changes" "abcX" (text)))

(let ((b (fresh)))
  (insert "abc")
  (guard (e (else #f))
    (atomic-change-group
      (insert "X")
      (error "boom")))
  (test-equal "a group that errors has its changes undone" "abc" (text)))

(let ((b (fresh)))
  (insert "abc")
  (text-editor-undo-disable! b)
  (guard (e (else #f))
    (atomic-change-group
      (insert "X")
      (error "boom")))
  (test-equal "even with undo disabled, the changes are undone" "abc" (text))
  (test-equal "and undo stays disabled" #t
              (eq? (text-editor-undo-list b) #t)))

(let ((b (fresh)))
  (insert "abc")
  (text-editor-undo-disable! b)
  (atomic-change-group (insert "X"))
  (test-equal "an accepted group keeps its changes with undo disabled"
              "abcX" (text))
  (test-equal "and undo stays disabled" #t
              (eq? (text-editor-undo-list b) #t)))

(test-end "schemacs_simple_undo")

;;----------------------------------------------------------------------
;; The keys bindings.el and window.el give these commands (`simple.el`'s
;; and `window.el`'s homes; `M-g' is flat because the lookup does not
;; descend into a submap here).
;;----------------------------------------------------------------------

(test-begin "schemacs_simple_bindings")

(test-equal "C-l is recenter-top-bottom" recenter-top-bottom
            (key-binding (kbd "C-l")))
(test-equal "M-g n is next-error" next-error (key-binding (kbd "M-g n")))
(test-equal "M-g M-n is next-error" next-error (key-binding (kbd "M-g M-n")))
(test-equal "M-g p is previous-error" previous-error
            (key-binding (kbd "M-g p")))
(test-equal "C-x ` is next-error" next-error (key-binding (kbd "C-x `")))
;; `bindings.el:1409` binds the event symbol itself; `(kbd
;; "C-S-backspace")` is an error in Emacs too.
(test-equal "C-S-backspace is kill-whole-line" kill-whole-line
            (key-binding (vector 'C-S-backspace)))

(test-end "schemacs_simple_bindings")

;;----------------------------------------------------------------------
;; `add-to-invisibility-spec` / `remove-from-invisibility-spec`
;; (`subr.el`), placed in `simple.scm` because they write the
;; buffer-local slot and `buffer.scm` is below that library.  Measured
;; on Emacs 31.1: `t` becomes `(foo t)`, a second add conses, and a
;; remove that matches nothing leaves the list alone.
(test-begin "schemacs_simple_invisibility_spec")

(let ((b (fresh)))
  (test-equal "a buffer starts with the default spec t" #t
              (buffer-local-value b 'buffer-invisibility-spec #t))
  (add-to-invisibility-spec 'foo)
  (test-equal "adding to t gives (foo t)" (list 'foo #t)
              (buffer-local-value b 'buffer-invisibility-spec #t))
  (add-to-invisibility-spec 'bar)
  (test-equal "a second add conses" (list 'bar 'foo #t)
              (buffer-local-value b 'buffer-invisibility-spec #t))
  (remove-from-invisibility-spec 'foo)
  (test-equal "remove takes the element out" (list 'bar #t)
              (buffer-local-value b 'buffer-invisibility-spec #t))
  (remove-from-invisibility-spec 'nope)
  (test-equal "removing an absent element leaves the list" (list 'bar #t)
              (buffer-local-value b 'buffer-invisibility-spec #t)))

(test-end "schemacs_simple_invisibility_spec")

;;----------------------------------------------------------------------
;; `kill-whole-line' (`simple.el:6824') and the two visible-line
;; movers it stands on.  Every row is Emacs 31.1's own answer for the
;; same buffer, point and argument; the last is its bounds error.
(test-begin "schemacs_simple_kill_whole_line")

(define (kwl text pt arg)
  (let ((b (fresh)))
    (insert text)
    (goto-char pt)
    (parameterize ((*last-command* 'ignore))
      (kill-whole-line arg))
    (list (buffer-substring-no-properties 1 (point-max)) (point)
          (current-kill 0))))

(test-equal "mid-line, forward: the whole line, trailing newline too"
  (list "aa\ncc" 4 "bb\n") (kwl "aa\nbb\ncc" 4 1))
(test-equal "arg zero leaves the trailing newline"
  (list "aa\n\ncc" 4 "bb") (kwl "aa\nbb\ncc" 4 0))
(test-equal "negative kills backward with the preceding newline"
  (list "aa\ncc" 3 "\nbb") (kwl "aa\nbb\ncc" 4 -1))
(test-equal "at the beginning of the line, forward"
  (list "bb\ncc" 1 "aa\n") (kwl "aa\nbb\ncc" 1 1))
(test-equal "at the beginning of the line, backward"
  (list "\nbb\ncc" 1 "aa") (kwl "aa\nbb\ncc" 1 -1))
(test-equal "at the end of the buffer the last line still goes"
  (list "aa\nbb\n" 7 "cc") (kwl "aa\nbb\ncc" 9 1))
(test-equal "and with arg zero"
  (list "aa\nbb\n" 7 "cc") (kwl "aa\nbb\ncc" 9 0))
(test-equal "a line with only its newline signals end-of-buffer"
  "End of buffer"
  (let ((b (fresh)))
    (insert "aa\nbb\n")
    (goto-char (point-max))
    (parameterize ((*last-command* 'ignore))
      (guard (e (#t (if (error-object? e) (error-object-message e) e)))
        (kill-whole-line 1)
        #f))))

(test-end "schemacs_simple_kill_whole_line")

;;----------------------------------------------------------------------
;; The two visible-line movers themselves, with an invisible run.
;; Measured on Emacs 31.1: a newline carrying `invisible` does not
;; count as a line, and an invisible run is stepped over whole.
(test-begin "schemacs_simple_visible_lines")

(define (visible-buffer start end)
  (let ((b (fresh)))
    (insert "aa\nbb\ncc")
    (put-text-property start end 'invisible #t)
    b))

(test-equal "a line whose newline is invisible is not counted" 7
  (begin (visible-buffer 3 4)
         (goto-char 1)
         (forward-visible-line 1)
         (point)))
(test-equal "end-of-visible-line skips an invisible run" 9
  (begin (visible-buffer 3 7)
         (goto-char 1)
         (end-of-visible-line)
         (point)))
(test-equal "backward, the invisible run is skipped too" 1
  (begin (visible-buffer 3 7)
         (goto-char 9)
         (forward-visible-line -1)
         (point)))

(test-end "schemacs_simple_visible_lines")

;;----------------------------------------------------------------------
;; A mode hook is a parameter and `add-hook` reaches it
;;----------------------------------------------------------------------
;; `add-hook` takes the hook object in this tree, so a hook written as a
;; plain list could not be extended. Every hook is a parameter now (the
;; Emacs defcustom ones are `define-custom`s; the ones Emacs `defvar`s,
;; like this mode's, are `make-parameter`s). `run-hooks` dereferences a
;; parameter, which is what makes the added function run.

(test-begin "schemacs_simple_mode_hook")

(test-assert "special-mode-hook is a parameter"
             (procedure? special-mode-hook))

(let ((b (allocate-buffer))
      (ran 0))
  (set-buffer b)
  (let ((f (lambda () (set! ran (+ ran 1)))))
    (add-hook special-mode-hook f)
    (special-mode)
    (remove-hook special-mode-hook f)
    (test-equal "special-mode-hook runs a function added with add-hook"
                1 ran)))

(test-end "schemacs_simple_mode_hook")
