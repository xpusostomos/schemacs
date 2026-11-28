;; Tests for `(schemacs core text-property-search)', which mirrors GNU
;; Emacs's `lisp/emacs-lisp/text-property-search.el'.
;;
;; This is a transcription of Emacs 31.1's own
;; `test/lisp/emacs-lisp/text-property-search-tests.el': the same
;; buffer fixture, the same searches, the same expected substrings and
;; the same `prop-match' fields. Nothing here is invented - the test
;; file is the specification.
;;-------------------------------------------------------------
(import
 (scheme base)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (schemacs buffer) get-buffer-create with-current-buffer erase-buffer)
 (only (schemacs editfns)
       insert point point-min point-max goto-char buffer-substring propertize)
 (only (schemacs fns) concat)
 (only (schemacs core text-property-search)
       make-prop-match prop-match-beginning prop-match-end prop-match-value
       text-property-search-forward text-property-search-backward))

(test-begin "schemacs_editor_text_property_search")

(define (setup!)
  ;; `text-property-setup' (`text-property-search-tests.el:34').
  (insert "This is "
          (propertize "bold1" 'face 'bold)
          " and this is "
          (propertize "italic1" 'face 'italic)
          (propertize "bold2" 'face 'bold)
          (propertize "i" 'face 'italic)
          " at the end")
  (goto-char (point-min)))

(define (collect-match-substrings thunk)
  ;; The tests' `(cl-loop for match = FORM while match collect ...)'.
  (let loop ((acc '()))
    (let ((match (thunk)))
      (if match
          (loop (append acc
                        (list (buffer-substring (prop-match-beginning match)
                                                (prop-match-end match)))))
          acc))))

(define (with-search point thunk)
  ;; Emacs's `with-test' puts `(point-max)' *inside* the temp buffer;
  ;; evaluating it at the call site (the test file's own buffer) gave 1
  ;; and every backward test started at bobp. The symbol `end' means the
  ;; fixture's `point-max', resolved here.
  (with-current-buffer (get-buffer-create " *text-property-search*")
    (erase-buffer)
    (setup!)
    (when point
      (goto-char (if (eq? point 'end) (point-max) point)))
    (thunk)))

;;----------------------------------------------------------------------
;; The collected substrings, exactly as Emacs's `with-test' asserts them.
(test-equal "forward bold, predicate t"
  '("bold1" "bold2")
  (with-search #f
    (lambda ()
      (collect-match-substrings
       (lambda () (text-property-search-forward 'face 'bold #t))))))

(test-equal "forward bold, predicate nil"
  '("This is " " and this is italic1" "i at the end")
  (with-search #f
    (lambda ()
      (collect-match-substrings
       (lambda () (text-property-search-forward 'face 'bold #f))))))

(test-equal "forward nil, predicate t"
  '("This is " " and this is " " at the end")
  (with-search #f
    (lambda ()
      (collect-match-substrings
       (lambda () (text-property-search-forward 'face #f #t))))))

(test-equal "forward nil, predicate nil"
  '("bold1" "italic1" "bold2" "i")
  (with-search #f
    (lambda ()
      (collect-match-substrings
       (lambda () (text-property-search-forward 'face #f #f))))))

(test-equal "forward partial bold, predicate t"
  '("old1" "bold2")
  (with-search 10
    (lambda ()
      (collect-match-substrings
       (lambda () (text-property-search-forward 'face 'bold #t))))))

(test-equal "forward partial non-current bold, predicate t"
  '("bold2")
  (with-search 10
    (lambda ()
      (collect-match-substrings
       (lambda () (text-property-search-forward 'face 'bold #t #t))))))

(test-equal "backward bold, predicate t"
  '("bold2" "bold1")
  (with-search 'end
    (lambda ()
      (collect-match-substrings
       (lambda () (text-property-search-backward 'face 'bold #t))))))

(test-equal "backward bold, predicate nil"
  '("i at the end" " and this is italic1" "This is ")
  (with-search 'end
    (lambda ()
      (collect-match-substrings
       (lambda () (text-property-search-backward 'face 'bold #f))))))

(test-equal "backward nil, predicate t"
  '(" at the end" " and this is " "This is ")
  (with-search 'end
    (lambda ()
      (collect-match-substrings
       (lambda () (text-property-search-backward 'face #f #t))))))

(test-equal "backward nil, predicate nil"
  '("i" "bold2" "italic1" "bold1")
  (with-search 'end
    (lambda ()
      (collect-match-substrings
       (lambda () (text-property-search-backward 'face #f #f))))))

(test-equal "backward partial bold, predicate t"
  '("b" "bold1")
  (with-search 35
    (lambda ()
      (collect-match-substrings
       (lambda () (text-property-search-backward 'face 'bold #t))))))

(test-equal "backward partial non-current bold, predicate t"
  '("bold1")
  (with-search 35
    (lambda ()
      (collect-match-substrings
       (lambda () (text-property-search-backward 'face 'bold #t #t))))))

;;----------------------------------------------------------------------
;; The `prop-match' fields.
(define (match-fields point thunk)
  (with-search point
    (lambda ()
      (let ((m (thunk)))
        (list (prop-match-beginning m)
              (prop-match-end m)
              (prop-match-value m))))))

(test-equal "forward prop-match, nil/nil"
  '(9 14 bold)
  (match-fields #f (lambda () (text-property-search-forward 'face #f #f))))

(test-equal "forward prop-match, bold/t"
  '(9 14 bold)
  (match-fields #f (lambda () (text-property-search-forward 'face 'bold #t))))

(test-equal "forward prop-match, bold/nil"
  '(1 9 #f)
  (match-fields #f (lambda () (text-property-search-forward 'face 'bold #f))))

(test-equal "backward prop-match, nil/nil"
  '(39 40 italic)
  (match-fields 'end
                (lambda () (text-property-search-backward 'face #f #f))))

(test-equal "backward prop-match, italic/t"
  '(39 40 italic)
  (match-fields 'end
                (lambda () (text-property-search-backward 'face 'italic #t))))

(test-equal "backward prop-match, italic/nil"
  '(40 51 #f)
  (match-fields 'end
                (lambda () (text-property-search-backward 'face 'italic #f))))

;;----------------------------------------------------------------------
;; Where point is left.
(test-equal "forward leaves point at the beginning of the match"
  5
  (with-current-buffer (get-buffer-create " *text-property-search-2*")
    (erase-buffer)
    (insert (concat "1234" (propertize "567" 'x #t) "890"))
    (goto-char (point-min))
    (text-property-search-forward 'x #t)
    (point)))

(test-equal "backward leaves point at the end of the match"
  8
  (with-current-buffer (get-buffer-create " *text-property-search-2*")
    (erase-buffer)
    (insert (concat "1234" (propertize "567" 'x #t) "890"))
    (goto-char (point-max))
    (text-property-search-backward 'x #t)
    (point)))

(test-end "schemacs_editor_text_property_search")
