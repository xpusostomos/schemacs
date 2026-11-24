;; Tests for `(schemacs elec-pair)' - `elec-pair.el''s automatic pairing,
;; the balance predicates, the filtered DEL, and the two modes. Every
;; expectation below was measured on GNU Emacs 31.1 first, driving
;; `self-insert-command' with `last-command-event' bound (the same path a
;; typed key takes), then reading `buffer-string' and point.

(import (scheme base)
        (only (srfi 64) test-assert test-equal test-eq test-begin test-end)
        (schemacs elec-pair)
        (schemacs buffer)
        (schemacs editfns)
        (schemacs cmds)
        (schemacs command)
        (schemacs simple)
        (schemacs keyboard)
        (schemacs character)
        (schemacs keymap)
        (schemacs data))

(define (type char)
  (parameterize ((*last-command-event* (char->integer char)))
    (self-insert-command 1 (char->integer char))))

(define (with-pair-buffer name thunk)
  (let ((buffer (get-buffer-create name)))
    (set-buffer buffer)
    (erase-buffer)
    (set!buffer-overwrite-mode buffer #f)
    (parameterize ((*electric-pair-preserve-balance* #t)
                   (*electric-pair-skip-whitespace* #t)
                   (*electric-pair-skip-self* electric-pair-default-skip-self)
                   (*electric-pair-inhibit-predicate*
                    electric-pair-default-inhibit)
                   (*electric-pair-delete-adjacent-pairs* #t)
                   (*electric-pair-open-newline-between-pairs* #t)
                   (*electric-pair-skip-whitespace-chars*
                    (list #\tab #\space #\newline))
                   (current-prefix-arg #f))
      (electric-pair-mode 1)
      (dynamic-wind
       (lambda () #f)
       thunk
       (lambda () (electric-pair-mode -1))))))

(test-begin "schemacs_elec_pair_pairs")

(with-pair-buffer "ep-test-open"
  (lambda ()
    (type #\()
    (test-equal "()" (buffer-string))
    (test-equal 2 (point))))

(with-pair-buffer "ep-test-pair"
  (lambda ()
    (type #\() (type #\))
    (test-equal "()" (buffer-string))
    (test-equal 3 (point))))

(with-pair-buffer "ep-test-quote"
  (lambda ()
    (type #\") (type #\a) (type #\b) (type #\")
    (test-equal "\"ab\"" (buffer-string))
    (test-equal 5 (point))))

(with-pair-buffer "ep-test-braces"
  (lambda ()
    (type #\{) (type #\})
    (test-equal "{}" (buffer-string))
    (type #\[) (type #\])
    ;; point is after the brace pair when the bracket pair is typed there
    (test-equal "{}[]" (buffer-string))))

(with-pair-buffer "ep-test-nested"
  (lambda ()
    (type #\() (type #\x) (type #\))
    (test-equal "(x)" (buffer-string))
    (test-equal 4 (point))))

;; The alist's default pairs include the curved quotes, from
;; `electric-quote-chars'.
(with-pair-buffer "ep-test-curly"
  (lambda ()
    (type #\‘) (type #\a) (type #\’)
    (test-equal "‘a’" (buffer-string))
    (test-equal 4 (point))))

;; String pairs, the two spellings: `(REGEXP . CLOSER)' inserts no space,
;; `(REGEXP CLOSER SPC)' inserts one.
(with-pair-buffer "ep-test-string-pair"
  (lambda ()
    (parameterize ((*electric-pair-pairs*
                    (cons (cons "/\\*" "*/") (list (cons 34 34)))))
      (type #\/) (type #\*)
      (test-equal "/**/" (buffer-string))
      (test-equal 3 (point)))))

(with-pair-buffer "ep-test-string-pair-spc"
  (lambda ()
    (parameterize ((*electric-pair-pairs*
                    (cons (list "/\\*" "*/" #t) (list (cons 34 34)))))
      (type #\/) (type #\*)
      (test-equal "/* */" (buffer-string))
      (test-equal 4 (point)))))

(test-end "schemacs_elec_pair_pairs")

(test-begin "schemacs_elec_pair_options")

;; `electric-pair-skip-whitespace' nil still skips the auto-inserted
;; closer (the whitespace is behind point, so nothing is moved).
(with-pair-buffer "ep-test-skip"
  (lambda ()
    (type #\() (type #\space) (type #\space) (type #\))
    (test-equal "(  )" (buffer-string))
    (test-equal 5 (point))))

(with-pair-buffer "ep-test-chomp"
  (lambda ()
    (parameterize ((*electric-pair-skip-whitespace* 'chomp))
      (type #\() (type #\space) (type #\space) (type #\))
      (test-equal "(  )" (buffer-string))
      (test-equal 5 (point)))))

;; With balancing off the conservative predicate decides: a lone closer
;; pairs with nothing.
(with-pair-buffer "ep-test-conservative"
  (lambda ()
    (parameterize ((*electric-pair-preserve-balance* #f))
      (type #\)) (type #\))
      (test-equal "))" (buffer-string)))))

(with-pair-buffer "ep-test-conservative2"
  (lambda ()
    (parameterize ((*electric-pair-preserve-balance* #f))
      (type #\() (type #\)) (type #\))
      (test-equal "())" (buffer-string)))))

;; In overwrite mode no pair is inserted.
(with-pair-buffer "ep-test-overwrite"
  (lambda ()
    (set!buffer-overwrite-mode (current-buffer) 'overwrite-mode-textual)
    (type #\() (type #\a)
    (test-equal "(a" (buffer-string))
    (test-equal 3 (point))))

;; An escaped delimiter is inserted without pairing.
(with-pair-buffer "ep-test-backslash"
  (lambda ()
    (type #\\) (type #\() (type #\))
    (test-equal "\\()" (buffer-string))
    (test-equal 4 (point))))

;; `electric-pair-open-newline-between-pairs': a newline between the
;; auto-paired delimiters gets a second one after point.
(with-pair-buffer "ep-test-newline"
  (lambda ()
    (type #\() (type #\newline)
    (test-equal "(\n\n)" (buffer-string))
    (test-equal 3 (point))))

(with-pair-buffer "ep-test-newline-off"
  (lambda ()
    (parameterize ((*electric-pair-open-newline-between-pairs* #f))
      (type #\() (type #\newline)
      (test-equal "(\n)" (buffer-string))
      (test-equal 3 (point)))))

(test-end "schemacs_elec_pair_options")

(test-begin "schemacs_elec_pair_region")

;; An active region is wrapped in the pair, and point stays where it was.
(with-pair-buffer "ep-test-region"
  (lambda ()
    (insert "abc")
    (goto-char 1)
    (set-mark 4)
    (activate-mark)
    (type #\()
    (test-equal "(abc)" (buffer-string))
    (test-equal 2 (point))))

(with-pair-buffer "ep-test-region-back"
  (lambda ()
    (insert "abc")
    (goto-char 4)
    (set-mark 1)
    (activate-mark)
    (type #\))
    (test-equal "(abc)" (buffer-string))
    (test-equal 6 (point))))

(with-pair-buffer "ep-test-region-quote"
  (lambda ()
    (insert "abc")
    (goto-char 1)
    (set-mark 4)
    (activate-mark)
    (type #\")
    (test-equal "\"abc\"" (buffer-string))
    (test-equal 2 (point))))

(test-end "schemacs_elec_pair_region")

(test-begin "schemacs_elec_pair_map")

;; The DEL map's `:filter' asks whether point is between a paired
;; delimiter, and a declined filter falls through to the global binding.
(with-pair-buffer "ep-test-map"
  (lambda ()
    (insert "()")
    (goto-char 2)
    (test-assert "between the pair DEL is electric-pair-delete-pair"
      (eq? (key-binding (kbd "DEL")) electric-pair-delete-pair))
    (goto-char 3)
    (test-assert "after the pair DEL falls through"
      (eq? (key-binding (kbd "DEL"))
           (lookup-key *default-keymap* (kbd "DEL"))))
    ;; a function-valued option is called, and its nil declines
    (parameterize ((*electric-pair-delete-adjacent-pairs* (lambda () #f)))
      (goto-char 2)
      (test-assert "a function option can decline"
        (eq? (key-binding (kbd "DEL"))
             (lookup-key *default-keymap* (kbd "DEL")))))))

;; `electric-pair-delete-pair` deletes the pair when point is between
;; them, and otherwise just the two characters around point.
(with-pair-buffer "ep-test-delete-pair"
  (lambda ()
    (insert "()")
    (goto-char 2)
    (electric-pair-delete-pair 1 #f)
    (test-equal "" (buffer-string))
    (test-equal 1 (point))))

(with-pair-buffer "ep-test-delete-pair-none"
  (lambda ()
    (insert "xy")
    (goto-char 2)
    (electric-pair-delete-pair 1 #f)
    (test-equal "" (buffer-string))
    (test-equal 1 (point))))

(test-end "schemacs_elec_pair_map")

(test-begin "schemacs_elec_pair_local_mode")

;; A buffer-local mode pairs in its own buffer only, with the global mode
;; off; turning it off kills the local binding.
(set-default 'electric-pair-mode #f)
(let ((a (get-buffer-create "ep-test-local-a"))
      (b (get-buffer-create "ep-test-local-b")))
  (set-buffer a)
  (erase-buffer)
  (electric-pair-local-mode 1)
  (test-assert "the local binding is set"
    (buffer-local-value a 'electric-pair-mode #f))
  (test-assert "the global value stays off"
    (not (default-value 'electric-pair-mode #f)))
  (type #\()
  (test-equal "()" (buffer-string))
  (set-buffer b)
  (erase-buffer)
  (type #\()
  (test-equal "(" (buffer-string))
  (set-buffer a)
  (electric-pair-local-mode -1)
  (test-assert "turning the local mode off kills the binding"
    (not (local-variable-p 'electric-pair-mode a))))

;; Enabling adds the three hooks; disabling removes them.
(set-default 'electric-pair-mode #f)
(electric-pair-mode 1)
(test-assert "the post-self-insert hooks are installed"
  (and (memq electric-pair-post-self-insert-function
             (*post-self-insert-hook*))
       (memq electric-pair-open-newline-between-pairs-psif
             (*post-self-insert-hook*))
       (memq electric-pair-will-use-region
             (*self-insert-uses-region-functions*))))
(electric-pair-mode -1)
(test-assert "disabling removes them"
  (and (not (memq electric-pair-post-self-insert-function
                  (*post-self-insert-hook*)))
       (not (memq electric-pair-open-newline-between-pairs-psif
                  (*post-self-insert-hook*)))
       (not (memq electric-pair-will-use-region
                  (*self-insert-uses-region-functions*)))))

(test-end "schemacs_elec_pair_local_mode")
