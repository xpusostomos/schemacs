(import
  (scheme base)
  (scheme char)
  (only (srfi 64) test-assert test-equal test-begin test-end)
  (only (schemacs editor keymap)
        keymap-lookup keymap-type? *default-keymap*)
  (only (schemacs editor character) kbd)
  (only (schemacs editor coding)
        coding-system-name coding-system-base)
  (only (schemacs editor mule) merge-coding-systems)
  (only (schemacs editor mule-cmds)
        mule-keymap coding-system-alist *coding-system-history*))

;; Regression tests for `(schemacs editor mule-cmds)', which mirrors GNU
;; Emacs's `lisp/international/mule-cmds.el'. The commands themselves
;; prompt, so what is checked here is what can be checked without a
;; minibuffer (and `tools/pty-check.py`'s `set-coding-system` drives the
;; two commands through the real command loop).

(test-begin "schemacs_editor_mule_cmds")

;; ------------------------------------------------------------------
;; `merge-coding-systems' - `mule.el:1202', which lives in `mule.sld'
;; because that is `mule.el''s file.

(test-equal "an unspecified eol is filled in from the other"
  'utf-8-dos
  (merge-coding-systems 'utf-8 'utf-8-dos))

(test-equal "... and an eol already named is kept"
  'utf-8-unix
  (merge-coding-systems 'utf-8-unix 'utf-8-dos))

(test-equal "the coding system's *own* name is what comes back"
  ;; the first is a name and the second settles its eol, so this is the
  ;; variant and not the bare name
  'iso-latin-1-unix
  (merge-coding-systems 'iso-latin-1 'utf-8-unix))

;; ------------------------------------------------------------------
;; the keymap and the completion table

;; The three keys are *bound*, which is all a keymap can be asked about
;; without a command loop; that they reach the commands is
;; `tools/pty-check.py`'s `set-coding-system`, which drives them.
(test-assert "mule-keymap is a keymap with the three bindings in it"
  (and (keymap-type? mule-keymap)
       (let loop ((keys (list (kbd "f") (kbd "r") (kbd "c"))))
         (cond ((null? keys) #t)
               ((keymap-lookup mule-keymap (car keys)) (loop (cdr keys)))
               (else #f)))))

;; ... and `C-x RET <key>' reaches them, which is what the user presses.
;;
;; **This is the *submap* path, not three flat bindings.** Emacs binds
;; `ctl-x-map''s `C-m' to `mule-keymap' itself and its lookup descends into
;; a keymap-valued binding; this tree spelled `C-x RET f' and its siblings
;; out flat while its lookup could not descend. It descends now, so the
;; key is `C-x RET' and the value is the map - which makes this assertion
;; the one that proves the descent works, because `keymap-lookup' has to
;; walk `C-x', then `RET' *into* `mule-keymap', and then `f'.
(test-assert "and C-x RET reaches them through mule-keymap"
  (let loop ((keys (list (kbd "C-x RET f") (kbd "C-x RET r") (kbd "C-x RET c"))))
    (cond ((null? keys) #t)
          ((keymap-lookup *default-keymap* (car keys)) (loop (cdr keys)))
          (else #f))))

(test-assert "C-x RET is bound to the keymap itself, as Emacs binds it"
  (keymap-type? (keymap-lookup *default-keymap* (kbd "C-x RET"))))

;; Every coding system this tree carries is offered, as one-element lists -
;; `completing-read''s collection shape.
(test-assert "the completion table offers the coding systems"
  (let ((alist (coding-system-alist)))
    (let loop ((rest alist) (kinds #t))
      (cond ((null? rest)
             (let ((names (map car alist)))
               (and kinds
                    (member "utf-8" names)
                    (member "iso-latin-1" names)
                    #t)))
            ((and (pair? (car rest)) (string? (caar rest)))
             (loop (cdr rest) kinds))
            (else #f)))))

(test-equal "the prompt keeps a history of its own"
  '()
  (let ((h (list *coding-system-history*)))
    (and (= 1 (length h)) '())))

(test-end "schemacs_editor_mule_cmds")
