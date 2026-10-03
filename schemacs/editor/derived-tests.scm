(import
 (scheme base)
 (scheme char)
 (schemacs editor engine)
 (schemacs editor buffer)
 (schemacs editor simple)
 (schemacs editor derived)
 (prefix (schemacs keymap) km:)
 (only (schemacs keymap) keymap-index keymap-lookup)
 (only (schemacs editor buffer) current-local-map)
 (only (schemacs editor keymap) define-key)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 )

;; The mode machinery: `define-derived-mode' and the names it makes
;; (`derived.el'), the buffer-local `major-mode' and `mode-name' and
;; `kill-all-local-variables' (`buffer.c'), and `special-mode'
;; (`simple.el'). What is asserted is the state a mode leaves behind,
;; which is what every later feature - the mode line, dired, the buffer
;; list - reads.

(test-begin "derived")

(define (in-buffer thunk)
  (parameterize ((*current-buffer* (get-buffer-create "*mode-test*")))
    (thunk)))

;; ------------------------------------------------------------------
;; the names

;; `derived-mode-map-name' and its three siblings turn a mode's symbol
;; into the names Emacs gives its parts.
(test-equal "map name" 'foo-mode-map (derived-mode-map-name 'foo-mode))
(test-equal "hook name" 'foo-mode-hook (derived-mode-hook-name 'foo-mode))
(test-equal "syntax table name" 'foo-mode-syntax-table
  (derived-mode-syntax-table-name 'foo-mode))
(test-equal "abbrev table name" 'foo-mode-abbrev-table
  (derived-mode-abbrev-table-name 'foo-mode))

;; ------------------------------------------------------------------
;; a buffer's mode, and `kill-all-local-variables'

(test-equal "a fresh buffer is Fundamental" 'fundamental-mode
  (in-buffer (lambda () (major-mode))))
(test-equal "and says so" "Fundamental" (in-buffer (lambda () (mode-name))))

(test-assert "kill-all-local-variables clears the buffer's own slots"
  (in-buffer
   (lambda ()
     (set-buffer-local-value! (current-buffer) 'some-slot 42)
     (set!major-mode 'foo-mode)
     (kill-all-local-variables)
     (and (eq? 'fundamental-mode (major-mode))
          (not (buffer-local-value (current-buffer) 'some-slot #f))))))

;; ------------------------------------------------------------------
;; `define-derived-mode'

(define test-mode-map (km:keymap '*test-mode-map*))
(define test-mode-hook '())
(define test-mode-ran #f)

(define-derived-mode (test-mode #f "Test" test-mode-map test-mode-hook)
  "A mode defined only to be looked at."
  (set! test-mode-ran #t))

(test-assert "the mode sets major-mode, mode-name and the keymap"
  (in-buffer
   (lambda ()
     (set! test-mode-ran #f)
     (test-mode)
     (and (eq? 'test-mode (major-mode))
          (string=? "Test" (mode-name))
          (eq? test-mode-map (current-local-map))
          test-mode-ran))))

;; a mode's own hook runs. The hook is the list the mode was defined
;; with - Emacs names a *variable* here and reads it, and a Scheme
;; variable is what stands in for one - so it is the list that is set.
(define test-mode-hook-ran #f)
(test-assert "the mode runs its own hook"
  (in-buffer
   (lambda ()
     (set! test-mode-ran #f)
     (set! test-mode-hook-ran #f)
     (set! test-mode-hook (list (lambda () (set! test-mode-hook-ran #t))))
     (test-mode)
     (set! test-mode-hook '())
     (and test-mode-ran test-mode-hook-ran))))

;; ------------------------------------------------------------------
;; `special-mode'

(test-equal "special-mode names itself" "Special"
  (in-buffer (lambda () (special-mode) (mode-name))))
(test-equal "and sets major-mode" 'special-mode
  (in-buffer (lambda () (special-mode) (major-mode))))
;; "These modes usually use read-only buffers" - the one thing its body
;; does is `(setq buffer-read-only t)'.
(test-assert "and makes the buffer read-only"
  (in-buffer (lambda () (special-mode) (text-editor-read-only? (current-buffer)))))
(test-assert "and installs its keymap"
  (in-buffer (lambda () (special-mode)
               (eq? special-mode-map (current-local-map)))))

;; ------------------------------------------------------------------
;; inheritance

;; A child mode's keymap takes the parent mode's as its *parent*, which
;; is Emacs's `(unless (keymap-parent ,map) (set-keymap-parent ,map
;; (current-local-map)))'. The bindings stay a *link*: what the parent
;; has is reachable through the child, and the child's own bindings
;; shadow it.
(define-key special-mode-map (list #\g) 'parent-key)
(define child-mode-map (km:keymap '*child-mode-map*))
(define child-mode-hook '())
(define-key child-mode-map (list #\c) 'child-key)
(define-derived-mode (child-mode special-mode "Child" child-mode-map
                                  child-mode-hook))

(test-assert "a derived mode's keymap has the parent's as its parent"
  (in-buffer
   (lambda ()
     (child-mode)
     (eq? (current-local-map) child-mode-map))))

(test-assert "the parent's bindings are reachable through the child"
  (in-buffer
   (lambda ()
     (child-mode)
     (and (eq? 'parent-key
               (km:keymap-lookup child-mode-map
                                 (km:keymap-index (list #\g))))
          (eq? 'child-key
               (km:keymap-lookup child-mode-map
                                 (km:keymap-index (list #\c))))))))

(test-assert "and the parent mode's own name is replaced, not inherited"
  (in-buffer (lambda () (child-mode)
               (and (eq? 'child-mode (major-mode))
                    (string=? "Child" (mode-name))))))

(test-end "derived")