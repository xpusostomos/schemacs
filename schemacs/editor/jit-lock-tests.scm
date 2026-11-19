;; Tests for `(schemacs editor jit-lock)` - `lisp/jit-lock.el`'s core:
;; the register/refontify/fontify-now cycle, and the after-change hook
;; that *marks* instead of fontifying.
;;
;; Every expectation is derived from the C (`jit-lock.el`, `xdisp.c`'s
;; `handle_fontified_prop`): Emacs's own answers here cannot be measured
;; from `emacs -Q --batch`, because with jit-lock nothing is fontified
;; until text is displayed - which is the whole point of the library, and
;; is what the pty battery's `font-lock-scheme` check exercises end to
;; end through the renderer.

(import
 (scheme base)
 (scheme char)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (guile) setvbuf)
 (only (schemacs editor frame) *current-frame* new-frame)
 (only (schemacs editor buffer)
       allocate-buffer current-buffer erase-buffer get-buffer-create
       set-buffer set-buffer-local-value! buffer-local-value)
 (only (schemacs editor editfns) goto-char insert point point-max point-min)
 (only (schemacs editor textprop) get-text-property put-text-property)
 (only (schemacs editor insdel) *after-change-functions*)
 (only (schemacs editor jit-lock)
       jit-lock-mode jit-lock-mode-on? jit-lock-functions jit-lock-register
       jit-lock-unregister jit-lock-refontify jit-lock-fontify-now
       jit-lock-after-change jit-lock-function jit-lock-contextually
       jit-lock-context-timer jit-lock-context-unfontify-pos
       jit-lock-context-fontify)
 (only (schemacs editor xdisp)
       fontification-functions set!fontification-functions!)
 (only (schemacs editor font-lock)
       set!font-lock-defaults! font-lock-ensure font-lock-fontified
       font-lock-fontify-region font-lock-mode-internal)
 (only (schemacs editor font-core) font-lock-mode))

(setvbuf (current-output-port) 'none)

(define ed (allocate-buffer))
(parameterize ((*current-frame* (new-frame ed 24 80)))
  (insert "aaa foo bbb\nccc foo ddd\n")

  (define (fontified-at p)
    (get-text-property p 'fontified (current-buffer)))
  (define (face-at p)
    (get-text-property p 'face (current-buffer)))

  (test-begin "schemacs_editor_jit_lock")

  ;;----------------------------------------------------------------
  ;; registering
  ;;----------------------------------------------------------------
  (test-equal "a buffer starts with no jit-lock"
    (list #f '() '()) (list (jit-lock-mode-on?) (jit-lock-functions)
                            (fontification-functions)))

  (define (probe-fun beg end) #t)
  (jit-lock-register probe-fun)
  (test-equal "register makes the mode on, the function listed, and the hook installed"
    (list #t #t #t #t)
    (list (jit-lock-mode-on?)
          (and (memq probe-fun (jit-lock-functions)) #t)
          (and (memq jit-lock-after-change (*after-change-functions*)) #t)
          (and (memq jit-lock-function (fontification-functions)) #t)))

  (jit-lock-unregister probe-fun)
  (test-equal "unregister takes it off and turns the mode off"
    (list #f '() #f '())
    (list (jit-lock-mode-on?)
          (jit-lock-functions)
          (and (memq jit-lock-after-change (*after-change-functions*)) #t)
          (fontification-functions)))

  ;;----------------------------------------------------------------
  ;; refontify and fontify-now
  ;;----------------------------------------------------------------
  (jit-lock-register probe-fun)
  (jit-lock-refontify)
  (test-equal "jit-lock-refontify marks the whole buffer unfontified"
    '(#f #f) (list (fontified-at (point-min)) (fontified-at (point-max))))

  (jit-lock-fontify-now)
  ;; the property at `point-max` itself is Emacs's special-cased nil - no
  ;; amount of fontifying changes it (`xdisp.c:4683`) - so the text's last
  ;; character is what a "whole buffer" answer is checked at.
  (test-equal "jit-lock-fontify-now fontifies it"
    '(#t #t) (list (fontified-at (point-min)) (fontified-at (- (point-max) 1))))

  ;; a second run left nothing to do - the chunk walk found no nil run
  ;; **registering marks the buffer for refontification again** -
  ;; `jit-lock-register` turns `jit-lock-mode` on, and its first act is
  ;; `jit-lock-refontify` - so the "nothing left" call has to come after
  ;; a fontification that follows the registration.
  (define calls 0)
  (jit-lock-unregister probe-fun)
  (jit-lock-register (lambda (beg end) (set! calls (+ calls 1)) #t))
  (jit-lock-fontify-now)
  (set! calls 0)
  (jit-lock-fontify-now)
  (test-equal "and a second call has nothing left to fontify" 0 calls)

  ;;----------------------------------------------------------------
  ;; the after-change hook marks, and only marks
  ;;----------------------------------------------------------------
  (goto-char (point-max))
  (insert "eee foo fff\n")
  (test-equal "a change marks the changed line unfontified, and fontifies nothing"
    '(#f #f)
    (list (fontified-at (- (point-max) 6)) (fontified-at (- (point-max) 2))))
  (set! calls 0)
  (jit-lock-fontify-now)
  (test-equal "and the fontification happens on demand" 1 calls)
  (test-equal "...leaving the text fontified" #t (fontified-at (- (point-max) 4)))

  ;;----------------------------------------------------------------
  ;; font-lock on jit-lock
  ;;----------------------------------------------------------------
  (erase-buffer)
  (insert "aaa foo bbb\n")
  ;; a mode sets the defaults; `font-lock-mode' turns on and registers
  (set!font-lock-defaults! (list (list (list "foo" (list 0 'bold)))))
  (font-lock-mode #t)
  (test-equal "font-lock-mode registers `font-lock-fontify-region' with jit-lock"
    #t (and (memq font-lock-fontify-region (jit-lock-functions)) #t))
  (test-equal "and does not fontify at once" #f (face-at 5))
  (font-lock-ensure)
  (test-equal "font-lock-ensure is what makes the faces appear" 'bold (face-at 5))

  (goto-char (point-max))
  (insert "zzz foo\n")
  (test-equal "an edit takes the new line's face off by marking it unfontified"
    '(#f #f)
    (list (fontified-at (- (point-max) 4)) (face-at (- (point-max) 2))))
  (font-lock-ensure)
  (test-equal "and the redisplay's own call (`font-lock-ensure') puts it back"
    'bold (face-at (- (point-max) 2)))

  (test-end "schemacs_editor_jit_lock")

  ;;----------------------------------------------------------------
  ;; contextual fontification (`jit-lock.el:154-270', `:636-666')
  ;;----------------------------------------------------------------
  ;;
  ;; A *registered* buffer is needed here: `jit-lock-context-fontify'
  ;; walks `(buffer-list)', as the C's `dolist' does, and a buffer from
  ;; `allocate-buffer' is not on it.
  (define tb (get-buffer-create "*jit-lock-context-test*"))
  (set-buffer tb)
  (insert "aaa foo bbb\nccc foo ddd\n")

  (test-begin "schemacs_editor_jit_lock_context")

  ;; without CONTEXTUAL the buffer-local stays unset, so the custom's
  ;; default (`syntax-driven') is what the mode reads - and it is not
  ;; `t', so no sweep position is set for this buffer.
  (jit-lock-register probe-fun)
  (test-equal "without CONTEXTUAL the buffer keeps the custom default and no sweep position"
    (list 'syntax-driven #f)
    (list (jit-lock-contextually) (jit-lock-context-unfontify-pos)))

  ;; "If non-nil, CONTEXTUAL means that a contextual fontification
  ;; would be useful": `jit-lock-register' sets the buffer-local `t',
  ;; and `jit-lock-mode' arms the idle timer and seats the position at
  ;; `point-max' (`jit-lock.el:258-265').
  (jit-lock-unregister probe-fun)
  (jit-lock-register probe-fun #t)
  (test-equal "CONTEXTUAL sets the buffer-local t, arms the timer and sweeps from point-max"
    (list #t (point-max) #t)
    (list (eq? (jit-lock-contextually) #t)
          (jit-lock-context-unfontify-pos)
          (not (eq? jit-lock-context-timer #f))))

  ;; the buffer is empty of faces here, so fontify it all first: the
  ;; sweep must have something to take *off*.
  (jit-lock-fontify-now)
  (test-equal "everything is fontified before the edit"
    '(#t #t) (list (fontified-at (point-min))
                   (fontified-at (- (point-max) 1))))

  ;; "Mark the change for deferred contextual refontification"
  ;; (`:701-708'): the *start* of the change, because text between start
  ;; and end is usually refontified by being displayed.
  (goto-char 5)
  (insert "x")
  (test-equal "a change moves the sweep position back to the change's start"
    5 (jit-lock-context-unfontify-pos))

  (jit-lock-context-fontify)
  (test-equal "the context sweep marks everything after the position unfontified"
    (list #t #f #f)
    (list (fontified-at (- 5 1))
          (fontified-at 5)
          (fontified-at (- (point-max) 1))))
  (test-equal "and seats the position back at point-max"
    (point-max) (jit-lock-context-unfontify-pos))

  ;; "Cancel our idle timers" - "Only if there's no other buffer using
  ;; them" (`:286-302'). The test buffer is the only registered one with
  ;; the mode on, so turning it off takes the timer with it.
  (jit-lock-unregister probe-fun)
  (test-equal "turning the mode off cancels the context timer"
    #f jit-lock-context-timer)

  (test-end "schemacs_editor_jit_lock_context"))

;;; jit-lock-tests.scm ends here
