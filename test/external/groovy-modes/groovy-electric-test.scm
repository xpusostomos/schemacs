;; Tests for `(schemacs external groovy-modes groovy-electric)', against
;; the upstream `groovy-electric.el'. The expectations are the C's
;; behaviour measured on Emacs 31.1 with the package's own
;; `groovy-electric-mode': the opener is inserted by
;; `self-insert-command', and the closer follows when the mode is on and
;; the position is code (read off the font-lock faces, as upstream
;; does).
(import
 (scheme base)
 (scheme write)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (schemacs buffer) generate-new-buffer current-buffer set-buffer
       buffer-local-value)
 (only (schemacs editfns) insert point point-min point-max goto-char
       buffer-substring-no-properties buffer-string forward-line
       char-after)
 (only (schemacs files) insert-file-contents)
 (only (schemacs font-lock) font-lock-ensure)
 (only (schemacs keymap) lookup-key)
 (only (schemacs command) *last-command-event*)
 (only (schemacs cmds) backward-char)
 (only (schemacs subr) *minor-mode-alist*)
 (schemacs external groovy-modes groovy-mode)
 (schemacs external groovy-modes groovy-electric))

(define (fresh-groovy src)
  (let ((b (generate-new-buffer "*ge-test*")))
    (set-buffer b)
    (insert src)
    (groovy-mode)
    b))

(define (type-char n)
  ;; Call the command a key would, with `last-command-event' set as the
  ;; command loop sets it.
  (parameterize ((*last-command-event* n))
    (groovy-electric-matching-char #f)))

(test-begin "schemacs_external_groovy_electric")

;; **The variable is `groovy-electric-mode-variable`** here: in a
;; Lisp-1 the mode's command owns the bare name, and the generated
;; accessor pair is how Emacs's variable half is spelled.
(test-assert "the mode is off until it is enabled"
  (begin (fresh-groovy "") (not (groovy-electric-mode-variable))))

(test-assert "the mode toggles on and off"
  (begin (fresh-groovy "")
         (groovy-electric-mode 1)
         (and (groovy-electric-mode-variable)
              (begin (groovy-electric-mode 0)
                     (not (groovy-electric-mode-variable))))))

;; **With `electric-indent-mode' on, which is Emacs's default and now
;; this tree's** (`(schemacs electric)` carries the mode, and groovy-mode
;; installs its electric characters): after the insert
;; `electric-indent-post-self-insert-function` reindents the line with
;; `groovy-indent-line`, so the brace comes out at column 4 - exactly the
;; answer the note here predicted for Emacs with the mode on. (The old
;; expectation was measured with the mode off, before it was ported.)
(test-assert "curly: the closer is inserted, with a space"
  (begin (fresh-groovy "def foo() {\n  \n}\n")
         (groovy-electric-mode 1)
         (goto-char 1)
         (forward-line 1)
         (parameterize ((*last-command-event* (char->integer #\{)))
           (groovy-electric-curlies #f))
         (equal? "def foo() {\n    { }  \n}\n"
                 (buffer-substring-no-properties (point-min) (point-max)))))

;; Emacs leaves point after the inserted space and before the closer:
;; `groovy-electric-curlies` inserts "{", " ", then "}" in a
;; `save-excursion`, so point is between the space and the brace.
(test-assert "curly: point is between the space and the closer"
  (begin (fresh-groovy "x = ")
         (groovy-electric-mode 1)
         (parameterize ((*last-command-event* (char->integer #\{)))
           (groovy-electric-curlies #f))
         (and (= (char->integer #\space) (char->integer (char-after (- (point) 1))))
              (= (char->integer #\}) (char->integer (char-after (point))))
              (equal? "x = { }"
                      (buffer-substring-no-properties (point-min) (point-max))))))

(test-assert "round paren: the closer is inserted"
  (begin (fresh-groovy "x = ")
         (groovy-electric-mode 1)
         (type-char (char->integer #\())
         (equal? "x = ()"
                 (buffer-substring-no-properties (point-min) (point-max)))))

(test-assert "square bracket: the closer is inserted"
  (begin (fresh-groovy "x = ")
         (groovy-electric-mode 1)
         (type-char (char->integer #\[))
         (equal? "x = []"
                 (buffer-substring-no-properties (point-min) (point-max)))))

(test-assert "a quote pairs with itself"
  (begin (fresh-groovy "x = ")
         (groovy-electric-mode 1)
         (type-char (char->integer #\"))
         (equal? "x = \"\""
                 (buffer-substring-no-properties (point-min) (point-max)))))

(test-assert "a dollar in a GString expands to ${}"
  (begin (fresh-groovy "x = \"hello \"")
         (groovy-electric-mode 1)
         (font-lock-ensure)
         (goto-char 11)                 ; before the closing quote
         (parameterize ((*last-command-event* (char->integer #\$)))
           (groovy-electric-pound #f))
         (equal? "x = \"hello${} \""
                 (buffer-substring-no-properties (point-min) (point-max)))))

(test-assert "a dollar in a single-quoted string does not expand"
  (begin (fresh-groovy "x = 'hello '")
         (groovy-electric-mode 1)
         (font-lock-ensure)
         (goto-char 11)                 ; before the closing quote
         (parameterize ((*last-command-event* (char->integer #\$)))
           (groovy-electric-pound #f))
         (equal? "x = 'hello$ '"
                 (buffer-substring-no-properties (point-min) (point-max)))))

(test-assert "with the mode off a brace is just a brace"
  (begin (fresh-groovy "x = ")
         (parameterize ((*last-command-event* (char->integer #\{)))
           (groovy-electric-curlies #f))
         (equal? "x = {"
                 (buffer-substring-no-properties (point-min) (point-max)))))

(test-assert "the mode binds the keys in groovy-mode-map"
  (begin (fresh-groovy "")
         (groovy-electric-mode 1)
         (eq? (lookup-key groovy-mode-map "{") groovy-electric-curlies)))

(test-assert "the mode line lighter is registered"
  (begin (fresh-groovy "")
         (and (assq 'groovy-electric-mode (*minor-mode-alist*))
              (equal? " Ge"
                      (cadr (assq 'groovy-electric-mode
                                  (*minor-mode-alist*)))))))

(test-end "schemacs_external_groovy_electric")
