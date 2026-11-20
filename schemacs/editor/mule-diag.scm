(define-library (schemacs editor mule-diag)
  ;; This library mirrors GNU Emacs's `lisp/international/mule-diag.el' -
  ;; the commands that *describe* coding systems, charsets and input
  ;; methods. What is here is the coding-system half: the ones the mode
  ;; line's coding-system item and `M-x describe-coding-system' use.
  ;;
  ;; **`princ` and `standard-output` are not ported**, so the printers
  ;; below `insert` into the help buffer where the C `princ`s to
  ;; `standard-output` captured by `with-output-to-temp-buffer`. Every
  ;; string they produce is Emacs 31.1's, measured with
  ;; `emacs -Q --batch` and a look at `*Help*`. The shape of each
  ;; function is Emacs's; only the printing primitive differs, and
  ;; `%princ` is the one place it does.
  ;;
  ;; **Not carried, each with what it waits for:**
  ;;
  ;;   - `coding-system-charset-list` and the "encodes the following
  ;;     charsets" block: the coding systems here carry no `:charset-list`
  ;;     attribute. `charset.scm` has the registry, so the day the
  ;;     attribute is transcribed the block is the C's loop.
  ;;   - the ISO-2022 branch of `describe-coding-system` (designations
  ;;     and flags): no ISO-2022 coding system is carried.
  ;;   - `:post-read-conversion` and `:pre-write-conversion`, which no
  ;;     coding system here has.
  ;;   - `describe-current-coding-system`'s process and
  ;;     `selection-coding-system` blocks: there are no subprocesses, and
  ;;     `selection-coding-system` is read but the C's `boundp` test has
  ;;     no counterpart - the variable is a parameter that is always
  ;;     bound here, so its block is printed.
  ;;   - `help-xref-button` in the charset list, and `print-coding-system`
  ;;     (the detailed printer) - nothing calls them yet.

  (import
    (scheme base)
    (only (guile) format string-prefix?)
    (only (schemacs editor coding)
          coding-system-p coding-system-aliases coding-system-eol-type
          coding-system-mnemonic coding-system-doc-string coding-system-base
          coding-system-change-eol-conversion)
    (only (schemacs editor files)
          buffer-file-coding-system default-buffer-file-coding-system)
    (only (schemacs editor mule) keyboard-coding-system
          terminal-coding-system)
    (only (schemacs editor select) *selection-coding-system*)
    (only (schemacs editor help)
          help-setup-xref with-help-window help-buffer
          substitute-command-keys)
    (only (schemacs editor command) define-command called-interactively?)
    (only (schemacs editor editfns) insert)
    (only (schemacs editor buffer) current-buffer local-variable-p)
    (only (schemacs editor xdisp) *describe-coding-system-function*))

  (export describe-coding-system describe-current-coding-system
          print-coding-system-briefly coding-system-type)

  (begin

    (define (%princ object)
      ;; The C's `(princ OBJECT)`: the printed form of OBJECT into the
      ;; help buffer. A string prints as itself, a symbol as its name -
      ;; which is `princ`'s whole difference from `prin1` - and a
      ;; character as the character.
      ;;--------------------------------------------------------------
      (insert (cond ((string? object) object)
                    ((symbol? object) (symbol->string object))
                    ((char? object) (string object))
                    (else (format #f "~a" object)))))

    (define (coding-system-type coding-system)
      ;; GNU Emacs's `coding-system-type` (`coding.c:10615`): "Return a
      ;; symbol representing the type of CODING-SYSTEM." Emacs stores it
      ;; as the coding system's `:coding-type` attribute; this tree's
      ;; record does not carry that field, so it is derived from the
      ;; *base* name - a departure, and the values are measured against
      ;; Emacs 31.1 (`utf-8`, `charset`, `raw-text`, `utf-16`,
      ;; `shift-jis`, `big5`, `undecided`).
      ;;--------------------------------------------------------------
      (let ((base (symbol->string (coding-system-base coding-system))))
        (cond
         ((string-prefix? "utf-8" base) 'utf-8)
         ((string-prefix? "utf-16" base) 'utf-16)
         ((or (string-prefix? "iso-8859" base)
              (string-prefix? "iso-latin" base)
              (string-prefix? "us-ascii" base))
          'charset)
         ((string-prefix? "japanese-shift-jis" base) 'shift-jis)
         ((string-prefix? "chinese-big5" base) 'big5)
         ((string=? base "undecided") 'undecided)
         (else 'raw-text))))

    (define (print-coding-system-briefly coding-system doc-string)
      ;; GNU Emacs's `print-coding-system-briefly` (`mule-diag.el:543`):
      ;; "Print symbol name and mnemonic letter of CODING-SYSTEM with
      ;; `princ'." DOC-STRING is nil, `tightly', or anything else.
      ;;--------------------------------------------------------------
      (if (not coding-system)
          (%princ "nil\n")
          (begin
            (%princ (format #f "~a -- ~a"
                            (coding-system-mnemonic coding-system)
                            coding-system))
            (let ((aliases (coding-system-aliases coding-system)))
              (cond ((eq? coding-system (car aliases))
                     (if (pair? (cdr aliases))
                         (%princ (format #f " ~s"
                                         (cons 'alias: (cdr aliases))))))
                    ((memq coding-system aliases)
                     (%princ (format #f " (alias of ~a)" (car aliases))))
                    (else
                     (let ((eol-type (coding-system-eol-type coding-system))
                           (base-eol-type
                            (coding-system-eol-type (car aliases))))
                       (if (and eol-type
                                (not base-eol-type)
                                (not (eq? coding-system
                                          (coding-system-change-eol-conversion
                                           (car aliases) eol-type))))
                           (%princ (format #f " (alias of ~a)"
                                           (coding-system-change-eol-conversion
                                            (car aliases) eol-type))))))))
            (%princ "\n")
            (or (eq? doc-string 'tightly)
                (%princ "\n"))
            (if doc-string
                (let ((doc (or (coding-system-doc-string coding-system) "")))
                  (when (eq? doc-string 'tightly)
                    (let search ((i 0))
                      (when (< i (string-length doc))
                        (if (char=? (string-ref doc i) #\newline)
                            (set! doc (substring doc 0 i))
                            (search (+ i 1))))))
                  (%princ (format #f "~a\n"
                                  (substitute-command-keys doc))))))))

    ;; The type words of `describe-coding-system`'s `cond`
    ;; (`mule-diag.el:424-453`), in the C's order. The ISO-2022 arm is
    ;; not carried - there is no such coding system here - and the
    ;; "invalid" arm is the else.
    (define %coding-type-description
      '((undecided . " (do automatic conversion)")
        (utf-8 . " (UTF-8: Emacs internal multibyte form)")
        (utf-16 . "")
        (shift-jis . " (Shift-JIS, MS-KANJI)")
        (charset . " (charset)")
        (ccl . " (do conversion by CCL program)")
        (raw-text . " (text with random binary characters)")
        (emacs-mule . " (Emacs 21 internal encoding)")
        (big5 . "")))

    (define (%print-coding-system-eol coding-system)
      ;; `describe-coding-system`'s "EOL type:" paragraph. Emacs's
      ;; `coding-system-eol-type` is an integer (0 LF, 1 CRLF, 2 CR) or
      ;; a *vector* of variants; this tree's answers `unix`/`dos`/`mac`
      ;; for the two, and `#f` for a base with variants - the shape its
      ;; own accessor settled on, mapped here.
      ;;--------------------------------------------------------------
      (let ((eol (coding-system-eol-type coding-system)))
        (cond
         ((not eol)
          (%princ "Automatic selection from:\n\t")
          (let ((base (coding-system-base coding-system)))
            (%princ (format #f "[~a ~a ~a]"
                            (coding-system-change-eol-conversion base 'unix)
                            (coding-system-change-eol-conversion base 'dos)
                            (coding-system-change-eol-conversion base 'mac))))
          (%princ "\n"))
         ((eq? eol 'unix) (%princ "LF\n"))
         ((eq? eol 'dos) (%princ "CRLF\n"))
         ((eq? eol 'mac) (%princ "CR\n"))
         (else (%princ "invalid\n")))))

    (define-command (describe-coding-system coding-system)
      "Display information about CODING-SYSTEM."
      (interactive "zDescribe coding system (default current choices): ")
      (if (not coding-system)
          (describe-current-coding-system)
          (begin
            (help-setup-xref (list describe-coding-system coding-system)
                             (called-interactively? describe-coding-system))
            (with-help-window (help-buffer)
              (print-coding-system-briefly coding-system 'doc-string)
              (let ((type (coding-system-type coding-system)))
                (%princ "Type: ")
                (%princ type)
                (cond
                 ((eq? type 'utf-8)
                  (%princ " (UTF-8: Emacs internal multibyte form)"))
                 ((not (memq type (map car %coding-type-description)))
                  (%princ ": invalid coding-system."))
                 (else
                  (%princ (cdr (assq type %coding-type-description)))))
                (%princ "\nEOL type: ")
                (%print-coding-system-eol coding-system))))))

    (define-command (describe-current-coding-system)
      "Display coding systems currently used, in detail."
      (interactive)
      (with-help-window (help-buffer)
        (let ((buffer (current-buffer)))
          (%princ "Coding system for saving this buffer:\n  ")
          (if (local-variable-p 'buffer-file-coding-system buffer)
              (print-coding-system-briefly
               (buffer-file-coding-system buffer) #f)
              (%princ "Not set locally, use the default.\n"))
          (%princ "Default coding system (for new files):\n  ")
          (print-coding-system-briefly default-buffer-file-coding-system #f)
          (%princ "Coding system for keyboard input:\n  ")
          (print-coding-system-briefly (keyboard-coding-system) #f)
          (%princ "Coding system for terminal output:\n  ")
          (print-coding-system-briefly (terminal-coding-system) #f)
          (%princ "Coding system for inter-client cut and paste:\n  ")
          (print-coding-system-briefly (*selection-coding-system*) #f))))

    ;; The seam `mouse.scm`'s coding-system item reaches this command
    ;; through - `bindings.el`'s map calls `describe-coding-system`
    ;; directly, and `xdisp.scm` is below this library.
    (*describe-coding-system-function* describe-coding-system)))
