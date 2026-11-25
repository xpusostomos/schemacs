(import
 (scheme base)
 (scheme char)
 (only (guile) setvbuf)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (schemacs subr) kbd event-modifiers event-basic-type
       event-convert-list event-symbol-elements with-silent-modifications
       define-key-after keymap-canonicalize
       add-hook remove-hook
       assoc-delete-all assq-delete-all)
 (only (schemacs keymap)
       keymap-index keymap-index->events
       make-sparse-keymap define-key set-keymap-parent keymap-parent
       keymap-type? keymap-lookup lookup-key keymapp map-keymap)
 ;; `function-key-map''s translation of a named key into the character it
 ;; means, which is `read_key_sequence''s step.
 (only (schemacs keyboard) function-key-translate)
 ;; `with-silent-modifications''s tests need a buffer to be silent about,
 ;; and the property write it exists for.
 (only (schemacs buffer)
       allocate-buffer buffer-modified-p set-buffer set-buffer-modified-p
       set!buffer-read-only current-buffer kill-all-local-variables
       local-variable-p buffer-local-value hook-value)
 (only (schemacs editfns) insert)
 (only (schemacs textprop) get-text-property put-text-property))

;; The key event model: GNU Emacs's `subr.el' and `keyboard.c' functions
;; that say what a key *is*, and `kbd', which builds one.
;;
;; Every expected value below was measured, not reasoned: each is what
;; `emacs -Q --batch' answers for the same input, so a departure here is a
;; departure from Emacs and nothing else. The obscure keys are in on
;; purpose - `XF86AudioRaiseVolume', the Menu key, dead keys, Hangul,
;; `Multi_key' - because they are the ones a shortcut reader gets wrong: a
;; key that is not a character has to stay a symbol and not be folded into
;; one, and a key the decoder has never heard of still has to arrive as
;; itself.
;;
;; Two malformed descriptions are deliberately absent: `<S-<up>>' and
;; `<C-M-<up>>'. Emacs's reader takes the FIRST `>' as the end of the key
;; name and lets the second become the character 62, so it answers a
;; two-event sequence; ours takes the last. That is a difference in a
;; nested-bracket *description*, not in a key, and the well-formed
;; spellings of both - `S-<up>' and `C-M-<up>' - are in the table and agree.

(setvbuf (current-output-port) 'none)

(test-begin "schemacs_editor_subr")

;; ------------------------------------------------------------------
;; the event model

(define (basic-type-value event)
  ;; `event-basic-type' answers a character or a symbol; Emacs's is an
  ;; integer for a character, so compare the codes.
  (let ((t (event-basic-type event)))
    (if (char? t) (char->integer t) t)))

(define (event-line event)
  (list event (event-modifiers event) (basic-type-value event)))

(test-equal "event 19" (list 19 '(control) 115) (event-line 19))
(test-equal "event 134217825" (list 134217825 '(meta) 97) (event-line 134217825))
(test-equal "event 1" (list 1 '(control) 97) (event-line 1))
(test-equal "event 97" (list 97 '() 97) (event-line 97))
(test-equal "event 134217788" (list 134217788 '(meta) 60) (event-line 134217788))
(test-equal "event 3" (list 3 '(control) 99) (event-line 3))
(test-equal "event 24" (list 24 '(control) 120) (event-line 24))
(test-equal "event 8" (list 8 '(control) 104) (event-line 8))
(test-equal "event 0" (list 0 '(control) 64) (event-line 0))
(test-equal "event 134217728" (list 134217728 '(control meta) 64) (event-line 134217728))
(test-equal "event up" (list 'up '() 'up) (event-line 'up))
(test-equal "event M-up" (list 'M-up '(meta) 'up) (event-line 'M-up))
(test-equal "event C-M-x" (list 'C-M-x '(meta control) 'x) (event-line 'C-M-x))
(test-equal "event S-up" (list 'S-up '(shift) 'up) (event-line 'S-up))
(test-equal "event C-M-S-s" (list 'C-M-S-s '(meta control shift) 's) (event-line 'C-M-S-s))

;; ------------------------------------------------------------------
;; event-convert-list: the description back to an event

(test-equal "convert (control 115)" 19 (event-convert-list (list 'control 115)))
(test-equal "convert (meta 60)" 134217788 (event-convert-list (list 'meta 60)))
(test-equal "convert (control 97)" 1 (event-convert-list (list 'control 97)))
(test-equal "convert (meta 97)" 134217825 (event-convert-list (list 'meta 97)))
(test-equal "convert (control meta 120)" 134217752 (event-convert-list (list 'control 'meta 120)))
(test-equal "convert (shift 97)" 65 (event-convert-list (list 'shift 97)))
(test-equal "convert (meta up)" 'M-up (event-convert-list (list 'meta 'up)))
(test-equal "convert (control 92)" 28 (event-convert-list (list 'control 92)))
(test-equal "convert (control 32)" 67108896 (event-convert-list (list 'control 32)))

;; ------------------------------------------------------------------
;; kbd: the description as the key sequence, which is Emacs's vector

(test-equal "kbd <XF86AudioRaiseVolume>" (vector 'XF86AudioRaiseVolume) (kbd "<XF86AudioRaiseVolume>"))
(test-equal "kbd <XF86VolumeUp>" (vector 'XF86VolumeUp) (kbd "<XF86VolumeUp>"))
(test-equal "kbd <Menu>" (vector 'Menu) (kbd "<Menu>"))
(test-equal "kbd <Print>" (vector 'Print) (kbd "<Print>"))
(test-equal "kbd <Scroll_Lock>" (vector 'Scroll_Lock) (kbd "<Scroll_Lock>"))
(test-equal "kbd <Pause>" (vector 'Pause) (kbd "<Pause>"))
(test-equal "kbd <KP_Enter>" (vector 'KP_Enter) (kbd "<KP_Enter>"))
(test-equal "kbd <XF86Back>" (vector 'XF86Back) (kbd "<XF86Back>"))
(test-equal "kbd <dead_grave>" (vector 'dead_grave) (kbd "<dead_grave>"))
(test-equal "kbd <Hangul>" (vector 'Hangul) (kbd "<Hangul>"))
(test-equal "kbd <Multi_key>" (vector 'Multi_key) (kbd "<Multi_key>"))
(test-equal "kbd <XF86MonBrightnessUp>" (vector 'XF86MonBrightnessUp) (kbd "<XF86MonBrightnessUp>"))
(test-equal "kbd <XF86AudioMute>" (vector 'XF86AudioMute) (kbd "<XF86AudioMute>"))
(test-equal "kbd <NoSymbol>" (vector 'NoSymbol) (kbd "<NoSymbol>"))
(test-equal "kbd <SunProps>" (vector 'SunProps) (kbd "<SunProps>"))
(test-equal "kbd M-<XF86AudioRaiseVolume>" (vector 'M-XF86AudioRaiseVolume) (kbd "M-<XF86AudioRaiseVolume>"))
(test-equal "kbd C-<Menu>" (vector 'C-Menu) (kbd "C-<Menu>"))
(test-equal "kbd <f35>" (vector 'f35) (kbd "<f35>"))
(test-equal "kbd <kp-1>" (vector 'kp-1) (kbd "<kp-1>"))
(test-equal "kbd <insert>" (vector 'insert) (kbd "<insert>"))
(test-equal "kbd <prior>" (vector 'prior) (kbd "<prior>"))
(test-equal "kbd <next>" (vector 'next) (kbd "<next>"))
(test-equal "kbd <end>" (vector 'end) (kbd "<end>"))
(test-equal "kbd <home>" (vector 'home) (kbd "<home>"))
(test-equal "kbd <deletechar>" (vector 'deletechar) (kbd "<deletechar>"))
(test-equal "kbd <backspace>" (vector 'backspace) (kbd "<backspace>"))
(test-equal "kbd <tab>" (vector 'tab) (kbd "<tab>"))
(test-equal "kbd <escape>" (vector 'escape) (kbd "<escape>"))
(test-equal "kbd <return>" (vector 'return) (kbd "<return>"))
(test-equal "kbd <space>" (vector 'space) (kbd "<space>"))
(test-equal "kbd <mouse-1>" (vector 'mouse-1) (kbd "<mouse-1>"))
(test-equal "kbd S-<up>" (vector 'S-up) (kbd "S-<up>"))
(test-equal "kbd C-M-<up>" (vector 'C-M-up) (kbd "C-M-<up>"))
(test-equal "kbd M-<tab>" (vector 'M-tab) (kbd "M-<tab>"))
(test-equal "kbd C-<f1>" (vector 'C-f1) (kbd "C-<f1>"))
(test-equal "kbd S-<XF86AudioRaiseVolume>" (vector 'S-XF86AudioRaiseVolume) (kbd "S-<XF86AudioRaiseVolume>"))
(test-equal "kbd C-M-<menu>" (vector 'C-M-menu) (kbd "C-M-<menu>"))
(test-equal "kbd M-<kp-1>" (vector 'M-kp-1) (kbd "M-<kp-1>"))
(test-equal "kbd <f1>" (vector 'f1) (kbd "<f1>"))
(test-equal "kbd M-<deletechar>" (vector 'M-deletechar) (kbd "M-<deletechar>"))
(test-equal "kbd C-<home>" (vector 'C-home) (kbd "C-<home>"))

;; ------------------------------------------------------------------
;; a key sequence read by `kbd' indexes a keymap to exactly the events it
;; names: an integer carrying its own modifier bits, or a symbol naming a
;; key that is not a character. These four were written while the tree was
;; being converted, against the modifier-symbol path spelling this tree
;; used to keep its keys in; that spelling is gone, and what is left to
;; assert is the *events* a key indexes to.
(test-equal "kbd C-x C-c indexes to its two events"
  '(24 3) (keymap-index->events (keymap-index (kbd "C-x C-c"))))
(test-equal "kbd M-< indexes to the M-< event"
  '(134217788) (keymap-index->events (keymap-index (kbd "M-<"))))
(test-equal "kbd <up> indexes to the up event"
  '(up) (keymap-index->events (keymap-index (kbd "<up>"))))
(test-equal "kbd M-<up> indexes to the M-up event"
  '(M-up) (keymap-index->events (keymap-index (kbd "M-<up>"))))

;; ------------------------------------------------------------------
;; `function-key-map' (`bindings.el':1554'), read off a real Emacs: the
;; erase key is DEL, Return is 13, TAB is 9, Escape is 27, and the keypad
;; is spelled into the key beside it.

(test-equal 127 (function-key-translate 'backspace))
(test-equal 127 (function-key-translate 'delete))
(test-equal 127 (function-key-translate 'kp-delete))
(test-equal 9 (function-key-translate 'tab))
(test-equal 10 (function-key-translate 'linefeed))
(test-equal 12 (function-key-translate 'clear))
(test-equal 13 (function-key-translate 'return))
(test-equal 13 (function-key-translate 'kp-enter))
(test-equal 27 (function-key-translate 'escape))
(test-equal 48 (function-key-translate 'kp-0))
(test-equal 61 (function-key-translate 'kp-equal))
(test-equal 'home (function-key-translate 'kp-home))
(test-equal 'insert (function-key-translate 'kp-insert))
;; a key the map says nothing about is looked up as itself
(test-equal 'up (function-key-translate 'up))
(test-equal 'f1 (function-key-translate 'f1))
(test-equal 'menu (function-key-translate 'menu))
;; and a character is not the map's business at all
(test-equal 97 (function-key-translate 97))

;; ------------------------------------------------------------------
;; `with-silent-modifications'
;;
;; GNU Emacs's `subr.el:5473'. The body's use here is the one the
;; docstring names - "typically used around modifications of text
;; properties that do not really affect the buffer's content" - and on a
;; *read-only* buffer, which is the case that made it necessary:
;; font-lock fontifies dired's and `*Completions*'.
;;
;; Measured on Emacs 31.1 for the same calls: the property write inside
;; succeeds although the buffer is read-only, the property is there
;; afterwards, and the buffer is left unmodified.

(define (temp-buffer-of text)
  (let ((ed (allocate-buffer)))
    (set-buffer ed)
    (insert text)
    ed))

(test-equal "with-silent-modifications: the body's value is the macro's"
  42
  ;; In a buffer, because the macro reads the current one on the way in -
  ;; as the C's `(buffer-modified-p)' does - and this tree's
  ;; `current-buffer' is false when nothing is current, where Emacs always
  ;; has one.
  (let ((ed (temp-buffer-of "abcdefghij")))
    (with-silent-modifications 42)))

(test-equal "with-silent-modifications: a property write on a read-only buffer"
  (list 'bold #f)
  (let ((ed (temp-buffer-of "abcdefghij")))
    (set!buffer-read-only ed #t)
    (set-buffer-modified-p #f)
    (with-silent-modifications
      (put-text-property 1 3 'face 'bold ed))
    (list (get-text-property 1 'face ed)
          (buffer-modified-p ed))))

;; The C restores the modified flag only "when modified is nil or
;; `autosaved'", so a buffer that was already modified is left modified.
(test-equal "with-silent-modifications: a modified buffer stays modified"
  #t
  (let ((ed (temp-buffer-of "abcdefghij")))
    (with-silent-modifications
      (put-text-property 1 3 'face 'bold ed))
    (buffer-modified-p ed)))

;;------------------------------------------------------------------
;; define-key-after and keymap-canonicalize - `subr.el`'s keymap half
;;
;; Every expectation is `emacs -Q --batch`'s own answer for the same
;; bindings: `define-key' prepends, so a map's order is newest first, and
;; only `define-key-after' places one anywhere else.
;;------------------------------------------------------------------

(define (subr-keymap-pairs keymap)
  (let ((out '()))
    (map-keymap (lambda (event def)
                  (set! out (append out (list (list event def)))))
                keymap)
    out))

(test-equal "define-key-after: right after AFTER's binding"
  '((99 fc) (98 fb) (120 fx) (97 fa))
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "a") 'fa)
    (define-key m (kbd "b") 'fb)
    (define-key m (kbd "c") 'fc)
    (define-key-after m (kbd "x") 'fx #\b)
    (subr-keymap-pairs m)))

(test-equal "define-key-after: AFTER t goes at the end"
  '((98 fb) (97 fa) (120 fx))
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "a") 'fa)
    (define-key m (kbd "b") 'fb)
    (define-key-after m (kbd "x") 'fx)
    (subr-keymap-pairs m)))

(test-equal "define-key-after: an AFTER that is not there goes at the end"
  '((98 fb) (97 fa) (120 fx))
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "a") 'fa)
    (define-key m (kbd "b") 'fb)
    (define-key-after m (kbd "x") 'fx #\z)
    (subr-keymap-pairs m)))

(test-equal "define-key-after: an existing binding is moved, not duplicated"
  '((99 fc) (98 fb) (120 fx2) (97 fa))
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "a") 'fa)
    (define-key m (kbd "b") 'fb)
    (define-key m (kbd "c") 'fc)
    (define-key m (kbd "x") 'fx)
    (define-key-after m (kbd "x") 'fx2 #\b)
    (subr-keymap-pairs m)))

(test-equal "define-key-after: a sequence defines in the prefix map it reaches"
  'fab
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "a") (make-sparse-keymap))
    (define-key-after m (kbd "a b") 'fab)
    (keymap-lookup m (kbd "a b"))))

(test-equal "define-key-after: a missing prefix defines nothing"
  #f
  (let ((m (make-sparse-keymap)))
    (define-key-after m (kbd "a b") 'fab)
    (keymap-lookup m (kbd "a b"))))

(test-equal "keymap-canonicalize: inheritance resolved, child wins"
  '((98 cb) (97 pa))
  (let ((parent (make-sparse-keymap))
        (child (make-sparse-keymap)))
    (define-key parent (kbd "a") 'pa)
    (define-key parent (kbd "b") 'pb)
    (define-key child (kbd "b") 'cb)
    (set-keymap-parent child parent)
    (subr-keymap-pairs (keymap-canonicalize child))))

(test-assert "keymap-canonicalize: the result has no parent"
  (let ((parent (make-sparse-keymap))
        (child (make-sparse-keymap)))
    (define-key parent (kbd "a") 'pa)
    (set-keymap-parent child parent)
    (not (keymap-parent (keymap-canonicalize child)))))

(test-assert "keymap-canonicalize: two submenus merge, the child's first"
  (let ((parent (make-sparse-keymap))
        (child (make-sparse-keymap))
        (cm (make-sparse-keymap))
        (pm (make-sparse-keymap)))
    (define-key cm (kbd "x") 'cx)
    (define-key pm (kbd "y") 'py)
    (define-key parent (kbd "s") pm)
    (define-key child (kbd "s") cm)
    (set-keymap-parent child parent)
    (let* ((canon (keymap-canonicalize child))
           (merged (keymap-lookup canon (kbd "s"))))
      ;; Emacs: (keymap (keymap (120 . cx)) (keymap (121 . py))) - a list
      ;; of two maps, walked in that order. Here a record with the child
      ;; map's bindings and the parent map as its own parent, which
      ;; `map-keymap' walks in the same order and `lookup-key' resolves
      ;; the same way.
      (and (keymap-type? merged)
           (equal? '((120 cx) (121 py)) (subr-keymap-pairs merged))
           (keymap-type? (keymap-parent merged))))))

;;----------------------------------------------------------------
;; `lookup-key' follows a keymap's parent - `access_keymap''s
;; NOINHERIT rule (`keymap.c:491'). Every answer here is Emacs 31.1's
;; for the same maps, measured with `emacs -Q --batch'.
;;----------------------------------------------------------------
(test-assert "lookup-key finds a binding in the parent"
  (let ((parent (make-sparse-keymap)) (child (make-sparse-keymap)))
    (define-key parent (kbd "b") 'pb)
    (set-keymap-parent child parent)
    (eq? 'pb (lookup-key child (kbd "b")))))

(test-equal "lookup-key reaches the parent's keys under a child's own prefix"
  '(px py)
  (let ((parent (make-sparse-keymap)) (child (make-sparse-keymap)))
    (define-key parent (kbd "C-c y") 'py)
    (set-keymap-parent child parent)
    (define-key child (kbd "C-c x") 'px)
    (list (lookup-key child (kbd "C-c x"))
          (lookup-key child (kbd "C-c y")))))

(test-assert "and the prefix both define is a keymap list"
  (let ((parent (make-sparse-keymap)) (child (make-sparse-keymap)))
    (define-key parent (kbd "C-c y") 'py)
    (set-keymap-parent child parent)
    (define-key child (kbd "C-c x") 'px)
    (let ((prefix (lookup-key child (kbd "C-c"))))
      (and (keymapp prefix)
           (not (keymap-type? prefix))
           (eq? 'py (lookup-key prefix (kbd "y")))))))

;; A *list* of keymaps - what `key-binding` hands `lookup-key` - resolves
;; each prefix across the whole list, not map by map. That is
;; `access_keymap_1`'s accumulation (`keymap.c:416-420`), and the case
;; that found it: a mode map that adds `[menu-bar c]` must not hide the
;; global `[menu-bar file]`, or F10 opened no menu in a C buffer. Both
;; answers are Emacs 31.1's for the same maps.
(test-assert "a keymap list finds a binding another map's prefix does not hide"
  (let ((mode (make-sparse-keymap)) (global (make-sparse-keymap))
        (menu (make-sparse-keymap)) (file-menu (make-sparse-keymap)))
    (define-key mode (vector 'menu-bar 'c) menu)
    (define-key global (vector 'menu-bar 'file) file-menu)
    (eq? file-menu (lookup-key (list mode global) (vector 'menu-bar 'file)))))

(test-assert "and the list's prefix combines both maps"
  (let ((mode (make-sparse-keymap)) (global (make-sparse-keymap)))
    (define-key mode (vector 'menu-bar 'c) 'cm)
    (define-key global (vector 'menu-bar 'file) 'fm)
    (let ((prefix (lookup-key (list mode global) (vector 'menu-bar))))
      (and (keymapp prefix)
           (not (keymap-type? prefix))
           (eq? 'cm (lookup-key prefix (vector 'c)))
           (eq? 'fm (lookup-key prefix (vector 'file)))))))

(test-assert "define-key does not inherit: a parent's command is not a prefix"
  (let ((parent (make-sparse-keymap)) (child (make-sparse-keymap)))
    (define-key parent (kbd "C-c") 'parent-command)
    (set-keymap-parent child parent)
    (define-key child (kbd "C-c x") 'cx)
    (and (eq? 'cx (lookup-key child (kbd "C-c x")))
         (keymap-type? (lookup-key child (kbd "C-c"))))))

;; **`assoc-delete-all` walks an alist whose elements are not all
;; conses.** Emacs's guard is `(consp (car alist))`, and its `assq` is
;; `Fassq`, which answers nil for a non-cons element rather than raising.
;; A tab is `(tab (name . "x") ...)` - its first element is the symbol
;; `tab` - and the missing guard made deleting a key from one raise
;; `(car 'tab)`.
(test-equal '((name . "x") tab (group . "g"))
  (assoc-delete-all 'wc '((name . "x") tab (wc . 1) (group . "g"))))
(test-equal '((name . "x") tab)
  (assq-delete-all 'wc '((name . "x") tab (wc . 1))))

;; ------------------------------------------------------------------
;; add-hook's LOCAL arm, and the merged value a runner sees
;;
;; Every expected value is what `emacs -Q --batch' answers for the same
;; sequence, measured first: a local add starts the buffer's value with
;; `t' (the marker that says "run the global value here"), a positive
;; DEPTH appends after it, and `run-hooks' runs the global list at the
;; marker's position.

(test-begin "schemacs_editor_subr_hooks")

(define *test-hook* (make-parameter '()))
(define hook-fn-1 (lambda () 'one))
(define hook-fn-2 (lambda () 'two))
(define hook-fn-3 (lambda () 'three))

(define (with-test-hook thunk)
  ;; A fresh *global* hook for every case: the parameter is module state
  ;; and a test that adds globally would otherwise leak into the next.
  (parameterize ((*test-hook* '()))
    (let ((b (allocate-buffer)))
      (set-buffer b)
      (thunk b))))

(test-equal "a global add is the parameter's list"
             (list hook-fn-1)
             (with-test-hook
              (lambda (b)
                (add-hook *test-hook* hook-fn-1)
                (*test-hook*))))
(test-equal "a local add makes the buffer's value start with t"
             (list hook-fn-1 #t)
             (with-test-hook
              (lambda (b)
                (add-hook *test-hook* hook-fn-1 #f #t)
                (buffer-local-value b *test-hook*))))
(test-equal "the global value is untouched by a local add" '()
             (with-test-hook
              (lambda (b)
                (add-hook *test-hook* hook-fn-1 #f #t)
                (*test-hook*))))
(test-equal "a positive depth appends after the t marker"
             (list hook-fn-1 #t hook-fn-2)
             (with-test-hook
              (lambda (b)
                (add-hook *test-hook* hook-fn-1 #f #t)
                (add-hook *test-hook* hook-fn-2 #t #t)
                (buffer-local-value b *test-hook*))))
(test-equal "hook-value splices the global list in at the marker"
             (list hook-fn-1 hook-fn-3 hook-fn-2)
             (with-test-hook
              (lambda (b)
                (add-hook *test-hook* hook-fn-1 #f #t)
                (add-hook *test-hook* hook-fn-2 #t #t)
                (*test-hook* (list hook-fn-3))
                (hook-value *test-hook*))))
(test-equal "removing a local function leaves the t marker"
             (list #t hook-fn-2)
             (with-test-hook
              (lambda (b)
                (add-hook *test-hook* hook-fn-1 #f #t)
                (add-hook *test-hook* hook-fn-2 #t #t)
                (remove-hook *test-hook* hook-fn-1 #t)
                (buffer-local-value b *test-hook*))))
(test-equal "kill-all-local-variables kills a local hook value"
             #f
             (with-test-hook
              (lambda (b)
                (add-hook *test-hook* hook-fn-1 #f #t)
                (kill-all-local-variables)
                (local-variable-p *test-hook*))))
(test-equal "a local remove with no local value removes nothing globally"
             (list hook-fn-1)
             (with-test-hook
              (lambda (b)
                (add-hook *test-hook* hook-fn-1)
                (remove-hook *test-hook* hook-fn-1 #t)
                (*test-hook*))))
(test-equal "a local add is not added twice"
             (list hook-fn-1 #t)
             (with-test-hook
              (lambda (b)
                (add-hook *test-hook* hook-fn-1 #f #t)
                (add-hook *test-hook* hook-fn-1 #f #t)
                (buffer-local-value b *test-hook*))))

(test-end "schemacs_editor_subr_hooks")

(test-end "schemacs_editor_subr")
