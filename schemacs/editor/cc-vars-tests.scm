;; Tests for `(schemacs editor cc-vars)', the variables cc-langs and
;; cc-fonts need first. Every default is Emacs 31.1's own value,
;; measured with `(symbol-value V)' in `emacs -Q --batch'.
;;--------------------------------------------------------------

(import
 (scheme base)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (schemacs editor buffer) allocate-buffer set-buffer)
 (schemacs editor cc-vars))

(test-begin "schemacs_editor_cc_vars")

(test-equal "c-syntactic-indentation defaults on" #t
            (*c-syntactic-indentation*))
(test-equal "c-syntactic-indentation-in-macros defaults on" #t
            (*c-syntactic-indentation-in-macros*))
(test-equal "c-warn-ids-with-dollar defaults off" #f
            (*c-warn-ids-with-dollar*))
(test-equal "c-mark-wrong-style-of-comment defaults off" #f
            (*c-mark-wrong-style-of-comment*))
(test-equal "c-asymmetry-fontification-flag defaults on" #t
            (*c-asymmetry-fontification-flag*))
(test-equal "c-indentation-style starts unset" #f c-indentation-style)

(test-equal "the C extra types are Emacs's default"
            '("\\sw+_t" "bool" "complex" "imaginary"
              "FILE" "lconv" "tm" "va_list" "jmp_buf" "Lisp_Object")
            (*c-font-lock-extra-types*))
(test-equal "the C++ list is Emacs's default"
            '("\\sw+_t" "FILE" "lconv" "tm" "va_list" "jmp_buf"
              "istream" "istreambuf" "ostream" "ostreambuf"
              "ifstream" "ofstream" "fstream"
              "strstream" "strstreambuf" "istrstream" "ostrstream"
              "ios" "string" "rope" "list" "slist"
              "deque" "vector" "bit_vector" "set" "multiset"
              "map" "multimap" "hash"
              "hash_set" "hash_multiset" "hash_map" "hash_multimap"
              "stack" "queue" "priority_queue" "type_info"
              "iterator" "const_iterator"
              "reverse_iterator" "const_reverse_iterator"
              "reference" "const_reference")
            (*c++-font-lock-extra-types*))
(test-equal "ObjC starts empty" '() (*objc-font-lock-extra-types*))
(test-equal "Java's is a capitalized-word matcher"
            '("[[:upper:]]\\sw*[[:lower:]]\\sw")
            (*java-font-lock-extra-types*))
(test-equal "IDL starts empty" '() (*idl-font-lock-extra-types*))
(test-equal "Pike's is a capitalized-word matcher"
            '("[[:upper:]]\\sw*[[:lower:]]\\sw*")
            (*pike-font-lock-extra-types*))

;; The variables are options: readable and bindable as parameters.
(parameterize ((*c-syntactic-indentation* #f))
  (test-equal "a parameter can be bound" #f (*c-syntactic-indentation*)))
(test-equal "and restored after" #t (*c-syntactic-indentation*))

;; The buffer-local ones are per buffer.
(define b1 (allocate-buffer))
(define b2 (allocate-buffer))
(set-buffer b1)
(set!c-current-comment-prefix "//+")
(set!c-macro-with-semi-re "Q_[A-Z]+")
(test-equal "the comment prefix is set in its buffer" "//+"
            (c-current-comment-prefix))
(test-equal "the macro regexp is set in its buffer" "Q_[A-Z]+"
            (c-macro-with-semi-re))
(set-buffer b2)
(test-equal "a second buffer has its own comment prefix" #f
            (c-current-comment-prefix))
(test-equal "and its own macro regexp" #f (c-macro-with-semi-re))
(set-buffer b1)
(test-equal "the first buffer kept its comment prefix" "//+"
            (c-current-comment-prefix))

(test-assert "c-string-list-p accepts a list of strings"
             (c-string-list-p '("a" "b")))
(test-assert "and an empty list" (c-string-list-p '()))
(test-assert "and rejects a non-string element"
             (not (c-string-list-p (list "a" 1))))
(test-assert "and a non-list" (not (c-string-list-p "a")))

(test-end "schemacs_editor_cc_vars")
