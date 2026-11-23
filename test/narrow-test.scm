;; -*- mode: scheme; -*-
;; Tests for the narrowing *commands* - `narrow-to-region', `widen',
;; `narrow-to-defun' and `narrow-to-page' - and for their keys.
;;
;; **Every expectation is Emacs 31.1's own answer** for the same buffer
;; and the same command call, measured with `emacs -Q --batch' (the
;; positions and the narrowed string are printed side by side in
;; DEPARTURES.md). The primitive (`BEGV`/`ZV`) is `editfns-tests.scm`'s
;; `narrowing` group; this file is the commands on top of it, which were
;; missing until 2026-11-17 - `C-x n n` did nothing because nothing had
;; bound it.

(import (scheme base) (scheme write) (srfi 64)
        (only (schemacs buffer)
              allocate-buffer get-buffer-create set-buffer erase-buffer)
        (only (schemacs frame) *current-frame* new-frame)
        (only (schemacs editfns)
              insert point point-min point-max goto-char buffer-string
              narrow-to-region widen narrow-map)
        (only (schemacs command) command-record-named command-procedure)
        (only (schemacs simple) set-mark)
        (only (schemacs keymap) keymap-lookup)
        (only (schemacs keyboard) key-binding)
        (only (schemacs subr) kbd)
        (only (schemacs core lisp) narrow-to-defun)
        (only (schemacs pages) narrow-to-page)
        (only (schemacs progmodes elisp-mode) emacs-lisp-mode))

(define (with-buffer thunk)
  (parameterize ((*current-frame* (new-frame (allocate-buffer) 24 80)))
    (let ((b (get-buffer-create "*narrow-tests*")))
      (set-buffer b)
      (erase-buffer)
      (thunk b))))

(define (region-of b)
  (list (point-min) (point-max) (buffer-string)))

(test-begin "schemacs_editor_narrow_commands")

;; `narrow-to-region' is a command in `editfns.c' (`:2948', interactive
;; spec "r"); calling its interactive entry narrows to the region.
;; Emacs on "aaa\n..." with point 3 and mark 5 narrows to [3,5) - "a\n".
(test-equal "narrow-to-region narrows to the region, through its spec"
  (list 3 5 "a\n")
  (with-buffer
   (lambda (b)
     (insert "aaa\n\fb\n\fccc\nddd\n")
     (goto-char 3)
     (set-mark 5)
     ((command-procedure (command-record-named "narrow-to-region")) #f)
     (region-of b))))

;; `widen' puts the whole buffer back, and does not move point.
(test-equal "widen restores the whole buffer"
  (list 1 17 "aaa\n\fb\n\fccc\nddd\n" 6)
  (with-buffer
   (lambda (b)
     (insert "aaa\n\fb\n\fccc\nddd\n")
     (narrow-to-region 3 6)
     (goto-char 6)
     (widen)
     (append (region-of b) (list (point))))))

;; `narrow-to-defun' around point - the defun that contains point.
;; Emacs at 25 in this buffer narrows to [14,26): the `foo' defun.
(test-equal "narrow-to-defun narrows to the defun at point"
  (list 14 37 "(defun foo ()\n  (bar))\n")
  (with-buffer
   (lambda (b)
     (insert ";; c1\n;; c2\n\n(defun foo ()\n  (bar))\n\n(defun baz ()\n  1)\n")
     (emacs-lisp-mode)
     (goto-char 25)
     (narrow-to-defun)
     (region-of b))))

;; ... and with INCLUDE-COMMENTS it takes the comments before it too.
(test-equal "narrow-to-defun with INCLUDE-COMMENTS starts at the comments"
  (list 1 37 ";; c1\n;; c2\n\n(defun foo ()\n  (bar))\n")
  (with-buffer
   (lambda (b)
     (insert ";; c1\n;; c2\n\n(defun foo ()\n  (bar))\n\n(defun baz ()\n  1)\n")
     (emacs-lisp-mode)
     (goto-char 25)
     (narrow-to-defun #t)
     (region-of b))))

;; `narrow-to-page' - the page is between form feeds. Emacs at 8, at 1
;; and at 15 in this buffer.
(test-equal "narrow-to-page at a page boundary"
  (list 6 8 "b\n")
  (with-buffer
   (lambda (b)
     (insert "aaa\n\fb\n\fccc\nddd\n")
     (goto-char 8)
     (narrow-to-page)
     (region-of b))))

(test-equal "narrow-to-page at the first page"
  (list 1 5 "aaa\n")
  (with-buffer
   (lambda (b)
     (insert "aaa\n\fb\n\fccc\nddd\n")
     (goto-char 1)
     (narrow-to-page)
     (region-of b))))

(test-equal "narrow-to-page at the last page"
  (list 9 17 "ccc\nddd\n")
  (with-buffer
   (lambda (b)
     (insert "aaa\n\fb\n\fccc\nddd\n")
     (goto-char 15)
     (narrow-to-page)
     (region-of b))))

;; A second `narrow-to-page' from a position that is only correct in the
;; widened buffer: `(set-match-data nil)' clears the *registers*, and
;; `forward-page' on the last page does not match - so the stale-match
;; bug here was a `match-beginning' that answered an old match's start.
(test-equal "narrow-to-page after widening a previous narrowing"
  (list 9 17 "ccc\nddd\n")
  (with-buffer
   (lambda (b)
     (insert "aaa\n\fb\n\fccc\nddd\n")
     (goto-char 1)
     (narrow-to-page)
     (widen)
     (goto-char 15)
     (narrow-to-page)
     (region-of b))))

(test-end "schemacs_editor_narrow_commands")

;;--------------------------------------------------------------------
;; The keys - `narrow-map` (`bindings.el:1214`) and the two that
;; `bindings.el` puts outside it
;;--------------------------------------------------------------------

(test-begin "schemacs_editor_narrow_keys")

(define (name-of key)
  (let ((r (key-binding (kbd key))))
    (and (procedure? r) (procedure-name r))))

(test-equal "C-x n n is narrow-to-region"
  'narrow-to-region (name-of "C-x n n"))
(test-equal "C-x n w is widen"
  'widen (name-of "C-x n w"))
(test-equal "C-x n d is narrow-to-defun"
  'narrow-to-defun (name-of "C-x n d"))
(test-equal "C-x n p is narrow-to-page"
  'narrow-to-page (name-of "C-x n p"))
(test-equal "C-x n g is goto-line-relative"
  'goto-line-relative (name-of "C-x n g"))

;; `narrow-map` exists as Emacs's object too, with `n` and `w` in it.
(test-equal "narrow-map has n, w and g"
  (list 'narrow-to-region 'widen 'goto-line-relative)
  (map (lambda (k)
         (procedure-name (keymap-lookup narrow-map (kbd k))))
       '("n" "w" "g")))

;; A non-narrowing command is not on these keys.
(test-equal "C-x n a is not a narrowing command"
  #f (name-of "C-x n a"))

(test-end "schemacs_editor_narrow_keys")
