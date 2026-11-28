(import
 (only (schemacs insdel) *after-change-functions*)
 (scheme base)
 (scheme char)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 
 (only (schemacs frame) *current-frame* new-frame)
 (only (schemacs buffer) current-buffer erase-buffer allocate-buffer
       set-buffer set-buffer-local-value!)
 (only (schemacs editfns)
       buffer-string goto-char insert point point-max point-min)
 (only (schemacs textprop)
       get-text-property put-text-property remove-list-of-text-properties)
 ;; the global value the buffer's copy is made from
 (only (schemacs intervals) *char-property-alias-alist*)
 (only (schemacs search) match-beginning match-end re-search-forward)
 (schemacs font-lock)
 (schemacs font-core))

;; font-lock.el's tests: the keyword engine, driven the way a mode drives
;; it - `font-lock-defaults' (or `font-lock-add-keywords'), then
;; `font-lock-mode'.
;;
;; Every whole-buffer expectation below was taken from `emacs -Q --batch'
;; running the same sequence on the same text; the two that are derived
;; from the C instead of measured say so on the test.
;;
;; Positions are the buffer's own, one-based - the interval layer's are
;; Emacs's now, the same as the positions `font-lock' works in (point,
;; match-end, line-end-position). A test that says "at 5" means position
;; 5, which is the first character of "foo" in "aaa foo bbb".

;; One frame for the whole file, as the other editor suites have: without
;; it every command that reads the current buffer dies, and the failure is
;; a `struct-vtable' error on #f three frames away.
(*current-frame* (new-frame (allocate-buffer) 24 80))

(test-begin "schemacs_editor_font_lock")

;; the buffer the plain-keyword tests run in, and the two helper readings
(define (fresh text)
  ;; A buffer holding TEXT, current, with font-lock OFF.
  ;;
  ;; Turning it off is not tidiness: `font-lock-fontified' is a
  ;; buffer-local flag saying "this buffer is already fontified", and
  ;; `font-lock-initial-fontify' skips a buffer that has it - so a second
  ;; test in the same buffer, erased and refilled without ever having
  ;; been unfontified, would silently not fontify at all. Emacs has the
  ;; same flag and the same rule; what it does not have is a test that
  ;; reuses one buffer without turning the mode off between uses.
  (let ((ed (current-buffer)))
    (when (font-lock-mode-on?) (font-lock-mode -1))
    ;; `font-lock-set-defaults' is guarded by "have I set this buffer up
    ;; for this mode", which a fresh buffer has not - and this buffer is
    ;; reused by every test, so the setup is undone as a new buffer's
    ;; would be (`font-lock.el:1914').
    (set-buffer-local-value! ed *font-lock-set-defaults* #f)
    (set-buffer-local-value! ed *font-lock-major-mode* #f)
    (erase-buffer)
    (insert text)
    (goto-char (point-min))
    ed))

(define (face-at ed where) (get-text-property where 'face ed))

;; ------------------------------------------------------------------
;; the keyword forms

(test-equal "font-lock-compile-keywords: (t KEYWORDS COMPILED...)"
  '(#t (("foo" (0 bold))) ("foo" (0 bold)))
  (let ((compiled (font-lock-compile-keywords (list (list "foo" (list 0 'bold))))))
    (list (car compiled) (cadr compiled) (caddr compiled))))

(test-equal "font-lock-compile-keyword: the forms of the doc string"
  ;; MATCHER, (MATCHER . SUBEXP), (MATCHER . FACENAME), (MATCHER . HIGHLIGHT)
  (list (list "foo" (list 0 'font-lock-keyword-face))
        (list "f\\(o\\)o" (list 1 'font-lock-keyword-face))
        (list "foo" (list 0 'bold))
        (list "foo" (list 0 'bold)))
  (list (font-lock-compile-keyword "foo")
        (font-lock-compile-keyword (cons "f\\(o\\)o" 1))
        (font-lock-compile-keyword (cons "foo" 'bold))
        (font-lock-compile-keyword (cons "foo" (list 0 'bold)))))

;; ------------------------------------------------------------------
;; a mode's keywords, turned on the way a mode turns them on

;; measured: `plain: bold'
(test-equal "a plain keyword fontifies its match"
  'bold
  (let ((ed (fresh "aaa foo bbb\n")))
    (set!font-lock-defaults! (list (list (list "foo" (list 0 'bold)))))
    (font-lock-mode #t) (font-lock-ensure)
    (face-at ed 5)))

;; measured: `override prepend => (bold)' and `append => (bold)' - with
;; nothing on the text but the unfontified state, both make a ONE-element
;; list, which is `font-lock--add-text-property''s "property values are
;; always lists" showing through
(test-equal "an overriding keyword prepends into a face list"
  '(bold)
  (let ((ed (fresh "aaa foo bbb\n")))
    (set!font-lock-defaults!
     (list (list (list "foo" (list 0 'bold 'prepend)))))
    (font-lock-mode #t) (font-lock-ensure)
    (face-at ed 5)))

(test-equal "an overriding keyword appends into a face list"
  '(bold)
  (let ((ed (fresh "aaa foo bbb\n")))
    (set!font-lock-defaults!
     (list (list (list "foo" (list 0 'bold 'append)))))
    (font-lock-mode #t) (font-lock-ensure)
    (face-at ed 5)))

;; ------------------------------------------------------------------
;; the four OVERRIDE arms, called directly
;;
;; Derived from the C (font-lock.el:1645-1667) rather than measured: to
;; see them one has to have a face already on the text *after*
;; `font-lock-default-fontify-region' has unfontified, which no
;; whole-buffer sequence can produce. Each row is `(OVERRIDE . EXPECTED)'
;; with `underline' already on [4,7) and `bold' the new value.

(test-equal "font-lock-apply-highlight: the override arms"
  '(underline bold (bold underline) (underline bold) underline)
  (map (lambda (override)
         (let ((ed (fresh "aaa foo bbb\n")))
           (put-text-property 5 8 'face 'underline ed)
           (goto-char (point-min))
           (re-search-forward "foo")
           (font-lock-apply-highlight (list 0 'bold override))
           (face-at ed 5)))
       (list #f #t 'prepend 'append 'keep)))

(test-assert "font-lock-apply-highlight: a subexpression is highlighted, not the whole match"
  (let ((ed (fresh "aaa fubar bbb\n")))
    (goto-char (point-min))
    (re-search-forward "fu\\(bar\\)")
    (font-lock-apply-highlight (list 1 'bold))
    (list (face-at ed 4) (face-at ed 5) (face-at ed 8))))

;; ------------------------------------------------------------------
;; MATCH-ANCHORED: Dired's own keyword shape
;;
;; measured: `anchored: name=bold col0=nil' - the *name* is fontified and
;; the marker character is not, which is the whole point of the anchored
;; form and of `dired-font-lock-keywords''

(test-equal "MATCH-ANCHORED: the anchor's pre-match form sets where the name starts"
  '(#f bold)
  (let* ((ed (fresh "  -rw-r--r-- 1 x x 0 today a.txt\nD -rw-r--r-- 1 x x 0 today b.txt\n"))
         (keywords (list (list "^D"
                               (list ".+"
                                     (lambda ()
                                       (goto-char (match-end 0))
                                       (re-search-forward "[^ ]+" #f #t)
                                       (goto-char (match-beginning 0))
                                       (point))
                                     #f
                                     (list 0 'bold))))))
    (set!font-lock-defaults! (list keywords))
    (font-lock-mode #t) (font-lock-ensure)
    ;; the D line starts at Emacs position 34, its name at 44
    (list (face-at ed 34) (face-at ed 45))))

;; ------------------------------------------------------------------
;; adding and removing

(test-equal "font-lock-add-keywords 'set replaces the list"
  '(bold)
  (let ((ed (fresh "aaa foo bbb\n")))
    ;; `font-lock-set-defaults' re-derives `font-lock-keywords' from
    ;; `font-lock-defaults' whenever the mode comes on, so a test that
    ;; builds its keywords with `font-lock-add-keywords' has to have no
    ;; defaults - which is the state a mode that never set any is in.
    (set!font-lock-defaults! #f)
    (font-lock-add-keywords #f (list (list "bar" (list 0 'underline))) 'set)
    (font-lock-add-keywords #f (list (list "foo" (list 0 'bold))) 'set)
    (font-lock-mode #t) (font-lock-ensure)
    (list (face-at ed 5))))

(test-equal "font-lock-remove-keywords takes a keyword off again"
  '(bold #f)
  (let ((ed (fresh "aaa foo bbb\n")))
    (set!font-lock-defaults! #f)
    (font-lock-add-keywords #f (list (list "foo" (list 0 'bold))
                                     (list "bbb" (list 0 'underline))) 'set)
    (font-lock-mode #t) (font-lock-ensure)
    (let ((before (face-at ed 5)))
      (font-lock-remove-keywords #f (list (list "bbb" (list 0 'underline))))
      (font-lock-fontify-buffer)
      (list before (face-at ed 12)))))

;; ------------------------------------------------------------------
;; unfontifying, and the change hook

(test-assert "font-lock-flush takes the face off, font-lock-ensure puts it back"
  (let ((ed (fresh "aaa foo bbb\n")))
    (set!font-lock-defaults! (list (list (list "foo" (list 0 'bold)))))
    (font-lock-mode #t) (font-lock-ensure)
    (let ((on (face-at ed 5)))
      (font-lock-flush)
      (let ((off (face-at ed 5)))
        (font-lock-ensure)
        (list on off (face-at ed 5))))))

(test-assert "font-lock-after-change-function refontifies an edit"
  ;; The mode's hook is on `*after-change-functions*' while the mode is
  ;; on, so an insertion that makes a new match fontifies it - which is
  ;; what "text is fontified as you type it" means, without jit-lock.
  (let ((ed (fresh "aaa bbb\n")))
    (set!font-lock-defaults! (list (list (list "foo" (list 0 'bold)))))
    (font-lock-mode #t) (font-lock-ensure)
    (let ((hook-installed (memq font-lock-after-change-function
                                (*after-change-functions*))))
      (goto-char (point-max))
      (insert "foo")
      (list (and hook-installed #t) (face-at ed 5)))))

(test-assert "turning the mode off takes the hook and the faces off"
  (let ((ed (fresh "aaa foo bbb\n")))
    (set!font-lock-defaults! (list (list (list "foo" (list 0 'bold)))))
    (font-lock-mode #t) (font-lock-ensure)
    (let ((on (face-at ed 5)))
      (font-lock-mode -1)
      (list on
            (face-at ed 5)
            (memq font-lock-after-change-function (*after-change-functions*))))))

;; ------------------------------------------------------------------
;; `char-property-alias-alist` - `font-lock-default-function`'s edit
;; ------------------------------------------------------------------
;; `font-lock-face` is a *second name* for `face` while the mode is on:
;; the buffer gets its own `copy-tree` of the alist and `lookup_char_property`
;; consults it after a direct miss. That is how Occur's `list-matching-
;; lines-prefix-face` (written with `font-lock-face`, as Emacs writes it)
;; reaches the renderer, which asks only for `face`.
;;
;; Measured on Emacs 31.1 with the same buffer and property:
;;     (get-text-property 1 'face) with font-lock off => nil
;;     (get-text-property 1 'face) with font-lock on  => shadow

(test-equal '(#f shadow shadow #f)
  (let ((ed (fresh "aaa\n")))
    (put-text-property 1 4 'font-lock-face 'shadow)
    (let* ((off (get-text-property 1 'face ed)))
      (font-lock-mode #t)
      (let ((on (get-text-property 1 'face ed))
            (direct (get-text-property 1 'font-lock-face ed)))
        (font-lock-mode -1)
        (list off on direct (get-text-property 1 'face ed))))))

;; ...and the buffer's list is a *copy*: turning the mode on and off must
;; not add or remove anything in the global value, or every buffer would
;; share one edit.
(test-equal '(#f #f)
  (let ((ed (fresh "aaa\n")))
    (font-lock-mode #t)
    (let ((global (*char-property-alias-alist*)))
      (font-lock-mode -1)
      (list (assq 'face global)
            (assq 'face (*char-property-alias-alist*))))))

(test-end "schemacs_editor_font_lock")

;; ------------------------------------------------------------------
;; font-lock-fontify-region-function is buffer-local
;;
;; A major mode can install its own region fontifier for its buffers only
;; (`font-lock.el:958`: "major modes can modify the values of, e.g.,
;; font-lock-fontify-region-function"). cc-mode's `c-font-lock-init` is
;; the caller this exists for.

(test-begin "font_lock_region_function")
(let ((b1 (allocate-buffer)) (b2 (allocate-buffer)) (called '()))
  (set-buffer b1)
  (insert "abc")
  (let ((custom (lambda (beg end loudly)
                  (set! called (cons (list beg end) called)))))
    (set!font-lock-fontify-region-function! custom)
    (test-assert "the buffer's own function is what it answers"
                 (eq? (font-lock-fontify-region-function) custom))
    (font-lock-fontify-region 1 4)
    (test-equal "and font-lock-fontify-region calls it" '((1 4)) called)
    (set-buffer b2)
    (test-assert "another buffer keeps the global default"
                 (eq? (font-lock-fontify-region-function)
                      font-lock-default-fontify-region))
    (test-equal "and a buffer-local entry does not leak" '((1 4)) called)))
(test-end "font_lock_region_function")

;;----------------------------------------------------------------------
;; `font-lock-remove-keywords` in a buffer with NO defaults.  The
;; keyword list there is #f, not '(), and Emacs's `dolist` over nil
;; runs zero times where `(car #f)` raises.  The first
;; `compilation-shell-minor-mode` in a plain buffer found this:
;; `font-lock-add-keywords` calls the remover to avoid duplicates.
(test-begin "schemacs_font_lock_no_defaults")
(let ((b (allocate-buffer)))
  (set-buffer b)
  (insert "aaa foo")
  (set!font-lock-defaults! #f)
  (test-equal "add-keywords in a buffer with no defaults does not raise"
              #t
              (begin (font-lock-add-keywords
                      #f (list (list "foo" (list 0 'bold))))
                     #t))
  (font-lock-mode #t)
  (font-lock-ensure)
  (test-equal "and the keyword highlights the text"
              '(bold)
              (list (face-at b 5))))
(test-end "schemacs_font_lock_no_defaults")
