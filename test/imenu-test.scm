;; Tests for `(schemacs imenu)`, a port of GNU Emacs's `imenu.el'.
;; Every expectation is what `emacs -Q --batch' answers for the same
;; call, with `imenu-use-markers' bound to nil so the positions compare
;; as numbers.

(import
 (scheme base)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (schemacs buffer) allocate-buffer set-buffer current-local-map
       buffer-name)
 (only (schemacs editfns) insert point point-max goto-char)
 (only (schemacs marker) marker-position)
 (only (schemacs keymap) lookup-key keymapp keymap-prompt)
 (only (schemacs xdisp) *menu-bar-update-hook*)
 (only (schemacs imenu)
       *imenu-use-markers* imenu-generic-expression
       set!imenu-generic-expression imenu--generic-function
       imenu--split imenu--in-alist imenu--subalist-p imenu--make-index-alist
       imenu--cleanup imenu--index-alist set!imenu--index-alist
       imenu--rescan-item imenu-default-goto-function imenu
       imenu--create-keymap imenu--menubar-keymap imenu-add-to-menubar
       imenu-update-menubar imenu-flush-cache
       *imenu-allow-duplicate-menu-items*))

(define (fresh text)
  (let ((b (allocate-buffer)))
    (set-buffer b)
    (insert text)
    b))

(test-begin "schemacs_editor_imenu")

(parameterize ((*imenu-use-markers* #f))
  (let ((b (fresh "int foo;\nint bar;\n")))
    (test-equal "the generic function builds the alist"
                '(("foo" . 1) ("bar" . 10))
                (imenu--generic-function
                 (list (list #f "^\\s-*\\(int\\) \\([a-z]+\\);" 2))))
    (test-equal "a menu title nests its items"
                '(("Funcs" ("foo" . 1) ("bar" . 10)))
                (imenu--generic-function
                 (list (list "Funcs" "^\\s-*\\(int\\) \\([a-z]+\\);" 2))))
    (test-equal "the search is case-insensitive by default"
                '(("foo" . 1) ("bar" . 10))
                (imenu--generic-function
                 (list (list #f "^\\s-*\\(INT\\) \\([a-z]+\\);" 2))))))

(test-equal "imenu--split cuts into N-sized sublists"
            '((1 2 3) (4 5 6) (7 8))
            (imenu--split (list 1 2 3 4 5 6 7 8) 3))

(test-assert "a subalist is a list whose cadr is a list"
             (imenu--subalist-p '("Funcs" ("foo" . 1))))
(test-assert "a cons item is not"
             (not (imenu--subalist-p '("foo" . 1))))

(test-equal "imenu--in-alist finds a nested item"
            '("bar" . 10)
            (imenu--in-alist "bar"
                             (list (list "Funcs" (cons "foo" 1)
                                         (cons "bar" 10)))))
(test-equal "and answers nil for one that is not there" #f
            (imenu--in-alist "zzz" (list (list "Funcs" (cons "foo" 1)))))

;; The command jumps through a (NAME POSITION FUNCTION) item.
(let ((b (fresh "abcdefghij")))
  (imenu (list "foo" 5 imenu-default-goto-function))
  (test-equal "imenu jumps to the position" 5 (point)))

;; `imenu--make-index-alist` runs the mode's index function and adds the
;; rescan item.
(parameterize ((*imenu-use-markers* #f))
  (let ((b (fresh "int foo;\nint bar;\n")))
    (set!imenu-generic-expression
     (list (list #f "^\\s-*\\(int\\) \\([a-z]+\\);" 2)))
    (let ((index (imenu--make-index-alist)))
      (test-equal "the rescan item leads the index"
                  imenu--rescan-item (car index))
      (test-equal "and the definitions follow"
                  '(("foo" . 1) ("bar" . 10)) (cdr index)))))

;; `imenu--cleanup` detaches the markers in the index.
(let ((b (fresh "int foo;\n")))
  (set!imenu-generic-expression
   (list (list #f "^\\s-*\\(int\\) \\([a-z]+\\);" 2)))
  (let* ((index (imenu--make-index-alist))
         (item (cadr index))
         (marker (cdr item)))
    (test-assert "the index uses a marker by default"
                 (*imenu-use-markers*))
    (imenu--cleanup)
    (test-assert "and cleanup detaches it"
                 (not (marker-position marker)))))

(test-end "schemacs_editor_imenu")


;;------------------------------------------------------------------
;; The menu-bar index (`imenu.el:948').
;; Every expectation is `emacs -Q --batch''s:
;;   (imenu--create-keymap "T" '(("A" . 1) ("B" . 2))) with duplicates
;;   off keys the entries (A B); with them on it keys them ("A" "B").
;; This tree's events are integers and symbols, so a duplicate-allowed
;; entry is keyed by a fresh symbol and the name stays the string the
;; menu shows - the one representation departure here.
;;------------------------------------------------------------------

(test-begin "schemacs_editor_imenu_menubar")

(test-equal "create-keymap interns its keys when duplicates are off"
            '(A B)
            (parameterize ((*imenu-allow-duplicate-menu-items* #f))
              (map car (cddr (imenu--create-keymap
                              "T" '(("A" . 1) ("B" . 2)))))))

(test-equal "and carries each item's name"
            '("A" "B")
            (map cadr (cddr (imenu--create-keymap
                             "T" '(("A" . 1) ("B" . 2))))))

(test-assert "with duplicates allowed, two same-named keys are distinct"
             (let* ((km (imenu--create-keymap "T" '(("A" . 1) ("A" . 2))))
                    (keys (map car (cddr km))))
               (and (= (length keys) 2)
                    (symbol? (car keys))
                    (not (eq? (car keys) (cadr keys))))))

(define (entry-named name entries)
  (let loop ((rest entries))
    (cond ((null? rest) #f)
          ((equal? (cadr (car rest)) name) (car rest))
          (else (loop (cdr rest))))))

(define (menu-names km)
  (map cadr (cddr km)))

(let ((b (fresh "alpha\nbeta\n")))
  (set!imenu-generic-expression
   '(("Names" "^\\(alpha\\|beta\\|delta\\)$" 1)))
  (parameterize ((*imenu-use-markers* #f))
    (imenu-add-to-menubar "Index")
    ;; Emacs 31.1 measured: `(lookup-key (current-local-map)
    ;; [menu-bar index])` answers the *keymap* - `access_keymap`'s
    ;; `get_keyelt` unwraps the `menu-item` - so this is the same
    ;; answer the probe above dumped from a live Emacs.
    (test-assert "the bar's item is keymap-valued"
                 (keymapp (lookup-key (current-local-map)
                                      (vector 'menu-bar 'index))))
    (test-assert "and the update hook is installed"
                 (and (memq imenu-update-menubar (*menu-bar-update-hook*))
                      #t))
    (imenu-update-menubar)
    (test-equal "the bar's menu is titled with the buffer name"
                (buffer-name)
                (keymap-prompt (imenu--menubar-keymap)))
    (test-equal "its top level is the rescan item and the submenu"
                '("*Rescan*" "Names")
                (menu-names (imenu--menubar-keymap)))
    (let* ((sub-entry (entry-named "Names"
                                   (cddr (imenu--menubar-keymap))))
           (sub (cddr sub-entry)))
      (test-equal "the submenu lists the definitions"
                  '("alpha" "beta")
                  (menu-names sub))
      (let ((leaf (cddr (entry-named "alpha" (cddr sub)))))
        (test-assert "a leaf is a procedure" (procedure? leaf))
        (goto-char (point-max))
        (leaf)
        (test-equal "and running it jumps to the definition" 1 (point))))
    ;; Emacs 31.1's measured update rule: an edit alone does not rescan
    ;; the cached index, so the menu stays as it was; after
    ;; `imenu-flush-cache' a further edit rebuilds it.
    (let ((d1 (menu-names (imenu--menubar-keymap))))
      (goto-char (point-max))
      (insert "delta\n")
      (imenu-update-menubar)
      (test-equal "an edit alone leaves the cached menu alone"
                  d1
                  (menu-names (imenu--menubar-keymap)))
      (imenu-flush-cache)
      (goto-char (point-max))
      (insert "beta\n")
      (imenu-update-menubar)
      (test-equal "after a flush, a further edit rebuilds it"
                  '("*Rescan*" "Names")
                  (menu-names (imenu--menubar-keymap)))
      (let ((sub (cddr (entry-named "Names"
                                    (cddr (imenu--menubar-keymap))))))
        (test-equal "with the new definitions in the submenu"
                    '("alpha" "beta" "delta" "beta")
                    (menu-names sub))))
    ;; The rescan item's own action.
    (let ((rescan (cddr (entry-named "*Rescan*"
                                     (cddr (imenu--menubar-keymap))))))
      (test-assert "the rescan entry's action answers t"
                   (eq? (rescan) #t)))))

(test-end "schemacs_editor_imenu_menubar")
