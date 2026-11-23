;; Tests for `(schemacs core easymenu)': `easy-menu-define`, the item
;; conversion every menu goes through, and the add/remove/change API.
;;
;; Group 1 compares the converter's *printed* answer with GNU Emacs
;; 31.1's for the same 18 item specs - exactly what
;; `tools/easymenu-diff''s differential compares, where the two sides
;; agree. Printing rather than comparing values is deliberate: Elisp's
;; nil is both `#f` and `'()` here, and `(cons key nil)` is the same
;; list as `(cons key '())` there but a different pair from `(cons key
;; #f)` here; the printed forms are what a menu shows either way.
;;
;; Group 2 pins the mechanics Emacs measured on this same definition:
;; the menu variable's prompt, the `[menu-bar test]` binding (the
;; downcased key easy-menu-define makes from a string menu name), the
;; display order after `easy-menu-add-item`-with-BEFORE, present/remove,
;; and `easy-menu-change` replacing a submenu's items.
(import
 (scheme base)
 (scheme write)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (guile) 1+ 1-)
 (schemacs buffer) (schemacs editfns)
 (schemacs keymap) (schemacs command)
 (schemacs menu-bar)
 (schemacs core easymenu))

(define (pr-to-string x)
  (let ((port (open-output-string)))
    (define (pr x)
      (cond ((or (null? x) (eq? x #f)) (display "nil" port))
            ((eq? x #t) (display "t" port))
            ((symbol? x) (display (symbol->string x) port))
            ((number? x) (display (number->string x) port))
            ((string? x) (write x port))
            ((vector? x)
             (display "[" port)
             (let loop ((i 0))
               (unless (>= i (vector-length x))
                 (if (> i 0) (display " " port))
                 (pr (vector-ref x i))
                 (loop (+ i 1))))
             (display "]" port))
            ((pair? x)
             (display "(" port) (pr (car x))
             (let loop ((t (cdr x)))
               (cond ((pair? t) (display " " port) (pr (car t)) (loop (cdr t)))
                     ((or (null? t) (eq? t #f)) #f)
                     (else (display " . " port) (pr t))))
             (display ")" port))
            (else (display "proc" port))))
    (pr x)
    (get-output-string port)))

(define specs
  (list (vector "Simple" 'simple-cmd #t)
        (vector "Keys" 'my-cmd ':keys "C-c k")
        (vector "Active" 'my-cmd ':active '(list 'fboundp 'x))
        (vector "Visible" 'my-cmd ':visible #f)
        (vector "Visible2" 'my-cmd ':visible #t)
        (vector "Toggle" 'my-cmd ':style 'toggle ':selected 'my-var)
        (vector "Radio" 'my-cmd ':style 'radio ':selected 'my-var)
        (vector "Button" 'my-cmd ':style 'button)
        (vector "Label" 'my-cmd ':label "Shown")
        (vector "Suffix" 'my-cmd ':suffix "!")
        (vector "Suffix2" 'my-cmd ':suffix 'my-suffix-var)
        (vector "Help" 'my-cmd ':help "help text")
        (vector "Cache" 'my-cmd ':key-sequence "C-c c")
        "---"
        "Plain string"
        (vector "KeysMarked" 'my-cmd ':keys "C-c \\[next-line]")
        (vector "Active2" 'my-cmd ':active 'my-flag)
        (vector "LabelForm" 'my-cmd ':label '(list 'my-label))))

(define expected-conversions
  (list
   "(Simple menu-item \"Simple\" simple-cmd)" ; (Simple menu-item "Simple" simple-cmd)
   "(Keys menu-item \"Keys\" my-cmd :keys \"C-c k\")" ; (Keys menu-item "Keys" my-cmd :keys "C-c k")
   "(Active menu-item \"Active\" my-cmd :enable (list (quote fboundp) (quote x)))" ; (Active menu-item "Active" my-cmd :enable (list (quote fboundp) (quote x)))
   "(Visible)" ; (Visible)
   "(Visible2 menu-item \"Visible2\" my-cmd)" ; (Visible2 menu-item "Visible2" my-cmd)
   "(Toggle menu-item \"Toggle\" my-cmd :button (:toggle . my-var))" ; (Toggle menu-item "Toggle" my-cmd :button (:toggle . my-var))
   "(Radio menu-item \"Radio\" my-cmd :button (:radio . my-var))" ; (Radio menu-item "Radio" my-cmd :button (:radio . my-var))
   "(Button menu-item \"[Button]\" my-cmd)" ; (Button menu-item "[Button]" my-cmd)
   "(Label menu-item \"Shown\" my-cmd)" ; (Label menu-item "Shown" my-cmd)
   "(Suffix menu-item \"Suffix !\" my-cmd)" ; (Suffix menu-item "Suffix !" my-cmd)
   "(Suffix2 menu-item (concat \"Suffix2 \" my-suffix-var) my-cmd)" ; (Suffix2 menu-item (concat "Suffix2 " my-suffix-var) my-cmd)
   "(Help menu-item \"Help\" my-cmd :help \"help text\")" ; (Help menu-item "Help" my-cmd :help "help text")
   "(Cache menu-item \"Cache\" my-cmd :key-sequence \"C-c c\")" ; (Cache menu-item "Cache" my-cmd :key-sequence "C-c c")
   "(nil \"--\")" ; (nil "--")
   "(nil menu-item \"Plain string\")" ; (nil menu-item "Plain string")
   "(KeysMarked menu-item \"KeysMarked\" my-cmd :keys (next-line \"C-c \"))" ; (KeysMarked menu-item "KeysMarked" my-cmd :keys (next-line "C-c "))
   "(Active2 menu-item \"Active2\" my-cmd :enable my-flag)" ; (Active2 menu-item "Active2" my-cmd :enable my-flag)
   "(LabelForm menu-item (list (quote my-label)) my-cmd)" ; (LabelForm menu-item (list (quote my-label)) my-cmd)
   ))

(define always-true-inputs
  (list #t #f 'foo '(quote x) '(quote (a)) 5 "s"))

(define expected-always-true
  (list
   "t"
   "nil"
   "nil"
   "x"
   "(a)"
   "t"
   "t"))

(define name-match-inputs
  (list "Label" 'Label '(quote Label) '(quote Nothing)))

(define expected-name-match
  (list
   "(\"Label\" . def)"
   "nil"
   "nil"
   "nil"))

(test-begin "schemacs_editor_easymenu_convert")

(for-each
 (lambda (spec expected)
   (test-equal (pr-to-string spec)
               expected
               (pr-to-string (easy-menu-convert-item spec))))
 specs expected-conversions)

(for-each
 (lambda (x expected)
   (test-equal (pr-to-string x) expected
               (pr-to-string (easy-menu-always-true-p x))))
 always-true-inputs expected-always-true)

(for-each
 (lambda (name expected)
   (test-equal (pr-to-string name) expected
               (pr-to-string (easy-menu-name-match
                              name (cons 'labelkey '("Label" . def))))))
 name-match-inputs expected-name-match)

(test-end "schemacs_editor_easymenu_convert")

;;----------------------------------------------------------------------
;; `easy-menu-define` and the add/remove/change API (Emacs-measured)
;;----------------------------------------------------------------------
(test-begin "schemacs_editor_easymenu_define")

(define test-map (make-sparse-keymap))
(easy-menu-define test-menu (list test-map) "Test doc."
  (list "Test"
        (vector "One" 'one-cmd #t)
        (vector "Two" 'two-cmd ':active 'my-flag)
        (list "Sub" (vector "Inner" 'inner-cmd #t))))

(test-equal "the variable holds the menu keymap" "Test"
            (keymap-prompt test-menu))
(test-assert "the popup command is registered under the menu's name"
             (command-record-named "test-menu"))
(test-equal "with the variable's docstring as its own" "Test doc."
            (command-doc-string (command-record-named "test-menu")))
(test-assert "and a key event as its interactive specification"
             (command-interactive-spec (command-record-named "test-menu")))

(test-assert "the bar binding is at the downcased name, as Emacs makes it"
             (keymap-type? (keymap-lookup test-map (vector 'menu-bar 'test))))
(test-equal "and is this menu" "Test"
            (keymap-prompt (keymap-lookup test-map (vector 'menu-bar 'test))))

(test-equal "a leaf lookup gives the command, as Emacs's get_keyelt does"
            'one-cmd (keymap-lookup test-menu (vector 'One)))
(test-equal "a submenu lookup gives its keymap" "Sub"
            (keymap-prompt (keymap-lookup test-menu (vector 'Sub))))
(test-equal "and a submenu leaf its command" 'inner-cmd
            (keymap-lookup test-menu (vector 'Sub 'Inner)))

(define (menu-order menu)
  ;; `keymap-order`'s front is the display front, as Emacs's alist is.
  (keymap-order menu))

(test-equal "the display order is the written order"
            '(One Two Sub) (menu-order test-menu))

(easy-menu-add-item test-menu #f (vector "Three" 'three-cmd #t))
(test-equal "an added item is at the end" '(One Two Sub Three)
            (menu-order test-menu))
(test-equal "and its command is findable" 'three-cmd
            (keymap-lookup test-menu (vector 'Three)))

(easy-menu-add-item test-menu #f (vector "Zero" 'zero-cmd #t) "One")
(test-equal "BEFORE places an added item before its named neighbour"
            '(Zero One Two Sub Three) (menu-order test-menu))

(test-assert "item-present-p finds it"
             (easy-menu-item-present-p test-menu #f "Zero"))
(test-assert "and does not find another"
             (not (easy-menu-item-present-p test-menu #f "Nope")))
(easy-menu-remove-item test-menu #f "Zero")
(test-assert "remove-item takes it out"
             (not (easy-menu-item-present-p test-menu #f "Zero")))
(test-equal "leaving the rest in place" '(One Two Sub Three)
            (menu-order test-menu))

(easy-menu-change #f "Sub" (list (vector "Inner2" 'inner2-cmd #t)) #f test-menu)
(test-equal "change replaces a submenu's items" 'inner2-cmd
            (keymap-lookup test-menu (vector 'Sub 'Inner2)))
(test-assert "and the old item is gone"
             (not (keymap-lookup test-menu (vector 'Sub 'Inner))))
(test-equal "the submenu keeps its prompt" "Sub"
            (keymap-prompt (keymap-lookup test-menu (vector 'Sub))))

;; A menu-level :visible nil form makes the menu invisible: create-menu
;; answers nil, as Emacs's `(if (equal visible ''nil) nil ...)' does.
(test-assert "a :visible nil menu is not created"
             (not (easy-menu-create-menu "Gone"
                                         (list ':visible #f
                                               (vector "A" 'a-cmd #t)))))

;; The filter wrapper: a box, whose :filter is what the popup command
;; calls with the item list.
(define filtered
  (easy-menu-create-menu
   "Filtered"
   (list ':filter (lambda (items)
                    (easy-menu-filter-return items "Filtered"))
         (vector "A" 'a-cmd #t))))
(test-assert "a menu with :filter is a box" (easy-menu-box? filtered))
(test-equal "and resolving it runs the filter into a keymap" "Filtered"
            (keymap-prompt (easy-menu-resolve-menu filtered)))

(test-end "schemacs_editor_easymenu_define")
