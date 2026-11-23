;; Tests for `(schemacs progmodes cc-langs)' - the language-variable
;; system ported from `lisp/progmodes/cc-langs.el'. The behaviour the
;; rest of cc-mode leans on: a `c-lang-defvar' becomes a buffer-local
;; value per language (with the constant's fallback chain applied),
;; `c-lang-setvar' does the same for a standard variable, values that
;; are not literal data are evaluated at run time, and a literal value
;; is baked into the generated init function at expansion time.
;;--------------------------------------------------------------

(import
 (scheme base)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (schemacs buffer) allocate-buffer set-buffer current-buffer
       buffer-local-value set-buffer-local-value!)
 (only (schemacs progmodes cc-defs) c-add-language c-lang-defconst c-lang-const
       c-mode-symbol c-mode-var c-make-keywords-re *c-buffer-is-cc-mode*)
 (only (schemacs syntax) char-syntax-in)
 (schemacs progmodes cc-langs))

(test-begin "schemacs_editor_cc_langs")

;; `eval-when (expand ...)': Emacs's own derived modes call
;; `c-add-language' inside `eval-and-compile', because the compiler
;; bakes `c-lang-const' values in later forms before any top-level call
;; has run. Without it, a *compiled* test file bakes c-mode's fallback
;; away and gets the `t' values.
(eval-when (expand load eval)
  (c-add-language 'cclangs-test-mode 'c-mode))

;; t holds the general value; c-mode, the base of cclangs-test-mode,
;; overrides it - so the test also exercises the fallback chain.
(c-lang-defconst cclangs-keywords
  t '("if" "else")
  c '("if" "else" "restrict"))

(c-lang-defvar cclangs-keywords-re (c-lang-const cclangs-keywords))
(c-lang-defvar cclangs-prefix "x-")
(c-lang-defvar cclangs-fn (lambda (n) (* n 2)))   ; not literal data
(c-lang-setvar comment-start "; ")

(define (run-init!) (c-init-language-vars cclangs-test-mode))

;;----------------------------------------------------------------------
;; Per-buffer values, with the constant's fallback chain applied
;;----------------------------------------------------------------------
(define b1 (allocate-buffer))
(set-buffer b1)
(run-init!)

(test-equal "a language variable is set in the buffer"
            '("if" "else" "restrict")
            (buffer-local-value b1 'cclangs-keywords-re))
(test-equal "a plain literal variable" "x-"
            (buffer-local-value b1 'cclangs-prefix))
(test-equal "c-lang-setvar sets the standard variable" "; "
            (buffer-local-value b1 'comment-start))
(test-assert "a non-literal value is a procedure"
             (procedure? (buffer-local-value b1 'cclangs-fn)))
(test-equal "and it works" 8
            ((buffer-local-value b1 'cclangs-fn) 4))

(define b2 (allocate-buffer))
(set-buffer b2)
(run-init!)
(test-equal "a second buffer gets its own value"
            '("if" "else" "restrict")
            (buffer-local-value b2 'cclangs-keywords-re))
(set-buffer-local-value! b1 'cclangs-prefix "changed-")
(test-equal "the first buffer's value is its own" "changed-"
            (buffer-local-value b1 'cclangs-prefix))
(test-equal "and the second's is untouched" "x-"
            (buffer-local-value b2 'cclangs-prefix))

;;----------------------------------------------------------------------
;; `c-mode-symbol' and `c-mode-var'
;;----------------------------------------------------------------------
(parameterize ((*c-buffer-is-cc-mode* 'c-mode))
  (test-equal "the mode prefix makes the symbol" 'c-something
              (c-mode-symbol "something")))
(set-buffer b1)
(set-buffer-local-value! b1 'c-something 42)
(parameterize ((*c-buffer-is-cc-mode* 'c-mode))
  (test-equal "and c-mode-var reads its buffer-local slot" 42
              (c-mode-var "something")))

;;----------------------------------------------------------------------
;; Baking: a generated init function keeps the values it was expanded
;; with, as compiled Emacs does.
;;----------------------------------------------------------------------
(c-lang-defconst cclangs-baked t 'old-value)
(c-lang-defvar cclangs-baked-var (c-lang-const cclangs-baked))
(define (init-early!) (c-init-language-vars cclangs-test-mode))
(c-lang-defconst cclangs-baked t 'new-value)

(define b3 (allocate-buffer))
(set-buffer b3)
(init-early!)
(test-equal "values are baked into the generated init" 'old-value
            (buffer-local-value b3 'cclangs-baked-var))
(test-equal "the constant itself has the new value" 'new-value
            (c-lang-const cclangs-baked c))

;;----------------------------------------------------------------------
;; The syntax tables: classes 0..255 against Emacs 31.1's c-mode
;; (measured with `(char-syntax i)` in a real c-mode buffer; the runs
;; are its answer, run-length encoded).
;;----------------------------------------------------------------------
(define c-table ((c-lang-const c-make-mode-syntax-table c)))

(define (syntax-runs table)
  (let loop ((i 0) (runs '()))
    (if (>= i 256)
        (reverse runs)
        (let ((c (char->integer (char-syntax-in table (integer->char i))))
              (j (+ i 1)))
          (let scan ()
            (if (and (< j 256)
                     (= (char->integer (char-syntax-in table (integer->char j))) c))
                (begin (set! j (+ j 1)) (scan))
                (loop j (cons (list i (- j 1) c) runs))))))))

(test-equal "c-mode's syntax classes match Emacs's"
            '((0 8 46) (9 9 32) (10 10 62) (11 11 46) (12 12 32) (13 13 62)
              (14 31 46) (32 32 32) (33 33 46) (34 34 34) (35 35 46)
              (36 36 119) (37 38 46) (39 39 34) (40 40 40) (41 41 41)
              (42 47 46) (48 57 119) (58 64 46) (65 90 119) (91 91 40)
              (92 92 92) (93 93 41) (94 94 46) (95 95 95) (96 96 46)
              (97 122 119) (123 123 40) (124 124 46) (125 125 41)
              (126 127 46) (128 159 119) (160 160 32) (161 161 46)
              (162 164 95) (165 165 119) (166 166 95) (167 167 46)
              (168 170 95) (171 171 46) (172 177 95) (178 179 119)
              (180 180 95) (181 181 119) (182 184 95) (185 185 119)
              (186 186 95) (187 187 46) (188 190 95) (191 191 46)
              (192 214 119) (215 215 95) (216 246 119) (247 247 95)
              (248 255 119))
            (syntax-runs c-table))

;; The per-language `@' modification: symbol syntax in ObjC and Java,
;; punctuation in Pike, unchanged (punctuation) in C.
(test-equal "@ is a symbol constituent in ObjC" #\_
            (char-syntax-in ((c-lang-const c-make-mode-syntax-table objc))
                            #\@))
(test-equal "@ is punctuation in Pike" #\.
            (char-syntax-in ((c-lang-const c-make-mode-syntax-table pike))
                            #\@))
(test-equal "@ is punctuation in C" #\.
            (char-syntax-in c-table #\@))

;;----------------------------------------------------------------------
;; `c-make-keywords-re' with the mode's own syntax table: operators are
;; non-symbols in c-mode, which is what the standard table gets wrong.
;; Every expectation is Emacs 31.1's in a c-mode buffer.
;;----------------------------------------------------------------------
(parameterize ((*c-buffer-is-cc-mode* 'c-mode))
  (test-equal "a symbol-only list" "\\_<\\(else\\|if\\|while\\)\\_>"
              (c-make-keywords-re #t '("if" "else" "while")))
  (test-equal "an operator-only list is non-symbols" "\\(\\+\\+\\|->\\)"
              (c-make-keywords-re #t '("++" "->")))
  (test-equal "a mixed list brackets each part" 
              "\\(\\_<\\(if\\|x\\)\\_>\\|\\(\\+\\+\\)\\)"
              (c-make-keywords-re #t '("if" "++" "x")))
  (test-equal "an empty list is unmatchable" "\\(\\`a\\`\\)"
              (c-make-keywords-re #t '()))
  (test-equal "nil elements are removed"
              "\\_<\\(if\\|while\\)\\_>"
              (c-make-keywords-re #t (list "if" #f "while"))))

;;----------------------------------------------------------------------
;; The language data (`cc-langs.el''s `c-lang-defconst' tables).
;;
;; Every value here is Emacs 31.1's own, measured in `emacs -Q --batch'
;; with `(c-get-lang-constant NAME nil MODE)'; `cc-langs.el' is the same
;; source the installed Emacs's own cc-langs was byte-compiled from. A
;; whole-file differential (354 constants x 7 languages) was run the
;; same way, and the only answers that differ are list *orders* that come
;; from Emacs's obarray walk - see DEPARTURES.md.
;;----------------------------------------------------------------------
(parameterize ((*c-buffer-is-cc-mode* 'c-mode))
  (test-equal "primitive type keywords, in the order Emacs has them"
              '("_Bool" "_Complex" "_Imaginary" "_Decimal32" "_Decimal64"
                "_Decimal128" "bool" "char8_t" "char16_t" "char32_t"
                "nullptr_t" "char" "double" "float" "int" "long" "short"
                "signed" "unsigned" "void")
              (c-lang-const c-primitive-type-kwds c))
  (test-equal "c-stmt-delim-chars" "^;{}?:" (c-lang-const c-stmt-delim-chars c))
  (test-equal "the block prefix charset compresses its runs"
              "^!%&(-/:-@[-^`{-~"
              (c-lang-const c-block-prefix-charset c))
  (test-equal "the multichar ':' token regexp"
              "\\(?:\\(?:%:%\\|[%<]\\):\\)"
              (c-lang-const c-:$-multichar-token-regexp c))
  (test-equal "type-internal paren keywords"
              '("_BitInt" "alignof" "alignas" "_Alignas" "_Alignof")
              (c-lang-const c-type-internal-paren-kwds c))
  (test-equal "a language that sets nothing is nil (#f)"
              #f (c-lang-const c-opt-identifier-prefix-key c))
  (test-equal "a fallback value is nil too: c-special-brace-lists"
              #f (c-lang-const c-special-brace-lists c))
  (test-equal "Emacs's own c-keywords length"
              66 (length (c-lang-const c-keywords c)))
  (test-equal "c-keywords-regexp byte for byte"
              "\\_<\\(NULL\\|_\\(?:Align\\(?:as\\|of\\)\\|B\\(?:itInt\\|ool\\)\\|Complex\\|Decimal\\(?:128\\|32\\|64\\)\\|Generic\\|Imaginary\\|Static_assert\\|Thread_local\\|_\\(?:a\\(?:\\(?:sm\\|ttribute\\)__\\)\\|declspec\\)\\)\\|a\\(?:lign\\(?:as\\|of\\)\\|sm\\|uto\\)\\|b\\(?:ool\\|reak\\)\\|c\\(?:ase\\|har\\(?:\\(?:16\\|32\\|8\\)_t\\)?\\|on\\(?:st\\(?:expr\\)?\\|tinue\\)\\)\\|d\\(?:efault\\|o\\(?:uble\\)?\\)\\|e\\(?:lse\\|num\\|xtern\\)\\|f\\(?:alse\\|loat\\|or\\)\\|goto\\|i\\(?:f\\|n\\(?:line\\|t\\)\\)\\|long\\|nullptr\\(?:_t\\)?\\|re\\(?:gister\\|strict\\|turn\\)\\|s\\(?:hort\\|i\\(?:gned\\|zeof\\)\\|t\\(?:atic\\(?:_assert\\)?\\|ruct\\)\\|witch\\)\\|t\\(?:hread_local\\|rue\\|ype\\(?:def\\|of\\(?:_unqual\\)?\\)\\)\\|un\\(?:ion\\|signed\\)\\|vo\\(?:id\\|latile\\)\\|while\\)\\_>"
              (c-lang-const c-keywords-regexp c)))

;; The keyword membership table: a keyword's cdr is the `*-kwds' lists it
;; belongs to. Emacs 31.1's answers for three keys, in any order.
(parameterize ((*c-buffer-is-cc-mode* 'c-mode))
  (let* ((alist (c-lang-const c-keyword-member-alist c))
         (entry (assoc "int" alist)))
    (test-assert "int is in the membership table" entry)
    (test-equal "int is a primitive type, a type start and a bitfield"
                '(c-bitfield-kwds c-primitive-type-kwds c-type-start-kwds)
                (sort (cdr entry)
                      (lambda (a b) (string<? (symbol->string a)
                                              (symbol->string b)))))
    (test-equal "_Generic is a generic keyword and nothing else"
                '(c-generic-kwds)
                (cdr (assoc "_Generic" alist)))
    (test-assert "a made-up name is not a keyword" (not (assoc "no_such_kw" alist)))))

;; c++ is where the template machinery differs.
(parameterize ((*c-buffer-is-cc-mode* 'c++-mode))
  (test-equal "C++ recognizes <> arglists" #t
              (c-lang-const c-recognize-<>-arglists c++))
  (test-equal "C++'s ':' multichar token regexp has the extra '<'"
              "\\(?:\\(?:%:%\\|[%:<]\\):\\)"
              (c-lang-const c-:$-multichar-token-regexp c++))
  (test-equal "C++ delimiters are the C ones" "^;{}?:"
              (c-lang-const c-stmt-delim-chars c++)))

(test-end "schemacs_editor_cc_langs")
