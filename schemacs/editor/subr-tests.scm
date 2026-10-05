(import
 (scheme base)
 (scheme char)
 (only (guile) setvbuf)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (schemacs editor subr) kbd event-modifiers event-basic-type
       event-convert-list event-symbol-elements)
 (only (schemacs keymap) keymap-index mod-index char-index))

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
;; an event indexes a keymap exactly as the path spelling it replaces,
;; which is what let the two forms live side by side while the tree was
;; converted.

(define (same-index? a b)
  (let ((x (keymap-index a)) (y (keymap-index b)))
    (and (= (mod-index x) (mod-index y))
         (equal? (char-index x) (char-index y)))))

(test-assert "kbd C-x C-c indexes as the path spelling"
  (same-index? (kbd "C-x C-c") '((ctrl #\x) (ctrl #\c))))
(test-assert "kbd M-< indexes as the path spelling"
  (same-index? (kbd "M-<") '((meta #\<))))
(test-assert "kbd <up> indexes as the path spelling"
  (same-index? (kbd "<up>") '(("up"))))
(test-assert "kbd M-<up> indexes as the path spelling"
  (same-index? (kbd "M-<up>") '((meta "up"))))

(test-end "schemacs_editor_subr")
