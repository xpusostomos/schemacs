(import
 (scheme base)
 (scheme char)
 (only (guile) getenv)
 (schemacs editor env)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 )

;; env.el's tests: `substitute-env-vars'. The expected answers are
;; Emacs's, taken from the docstring and from what the C does with the
;; regexp - `$NAME' terminated by a non-name character, `${NAME}',
;; `$$' for a literal dollar, and an undefined variable replaced by the
;; empty string unless the caller says otherwise.

(test-begin "env")

;; `$NAME' runs to the first character that is not a letter, digit or
;; underscore - so in "ab$cd-x" the variable is `cd', not `cd-x'.
(test-equal "a name ends at a non-name character"
  "ab-x-replaced"
  (substitute-env-vars "ab$cd-x-replaced"))

(test-equal "a defined variable is replaced"
  (string-append "ab" (or (getenv "HOME") "") "-x")
  (substitute-env-vars "ab$HOME-x"))

(test-equal "the braced form is replaced"
  (string-append (or (getenv "HOME") "") "/y")
  (substitute-env-vars "${HOME}/y"))

;; "Use `$$' to insert a single dollar sign."
(test-equal "$$ is one dollar sign" "$" (substitute-env-vars "$$"))
(test-equal "$$ among text" "a$b" (substitute-env-vars "a$$b"))

;; "references to undefined environment variables are replaced by the
;; empty string" when WHEN-UNDEFINED is nil
(test-equal "an undefined variable becomes empty"
  "a-b" (substitute-env-vars "a$nosuchvariable-b"))

;; "If it is non-nil and not a function, references to undefined
;; variables are left unchanged."
(test-equal "an undefined variable is left standing"
  "a$nosuchvariable-b" (substitute-env-vars "a$nosuchvariable-b" #t))

;; "if it is a function, the function is called with the variable's name
;; as argument, and should return the text with which to replace it"
(test-equal "a function decides what an undefined variable becomes"
  "a<nosuchvariable>-b"
  (substitute-env-vars "a$nosuchvariable-b"
                       (lambda (var) (string-append "<" var ">"))))

;; a value holding a `$' is not substituted again - the scan moves past
;; what it put in
(test-assert "a substituted value is not rescanned"
  (let ((home (getenv "HOME")))
    (string=? (substitute-env-vars "$HOME$HOME")
              (string-append home home))))

(test-end "env")