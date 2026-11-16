(import
 (scheme base)
 (scheme write)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (guile) setvbuf)
 (only (ice-9 exceptions) exception-message)
 (only (schemacs editor command)
       define-command define-alias command-record-of command-procedure
       command-record-named *barf-if-buffer-read-only-function*
       *point-marker-function* *mark-marker-function*
       *read-string-function* *read-number-function*
       *format-message-function*
       *interactive-read-file-name-function*
       *interactive-read-directory-name-function*
       *interactive-read-existing-buffer-function*
       *interactive-read-buffer-function*
       *read-coding-system-function* *read-non-nil-coding-system-function*
       *read-command-function* *read-minibuffer-function*
       *eval-minibuffer-function* *read-variable-function*
       *read-char-event-function* *message-clear-function*
       *read-key-sequence-function* *read-key-sequence-vector-function*)
 (only (schemacs editor buffer)
       allocate-buffer with-current-buffer current-buffer
       set!buffer-read-only)
 (only (schemacs editor editfns) goto-char insert buffer-string
       mark-marker)
 (only (schemacs editor marker) marker-position marker-buffer)
 (only (schemacs editor simple) set-mark deactivate-mark region-active-p)
 ;; Loaded for its effect: the command loop installs the `*' check's
 ;; seam as it loads (`*barf-if-buffer-read-only-function*').
 (only (schemacs editor keyboard) dispatch-key-event))

;; Regression tests for `callint.c`'s interactive specifications as this
;; tree reads them (`command.scm`'s `interactive-proc`).
;;
;; The `*' marker - "an error is signaled if the buffer is read-only"
;; (`callint.c:98`, peeled with `@', `-', `+' and `^' before any code is
;; read, `:362') - is what `comment-indent' declares, and until it was
;; ported neither that command nor any other could carry it.
;;
;; Each test drives the *interactive entry* - the procedure
;; `register-command!` filed on the command's record - which is exactly
;; what the command loop calls for a keypress.

(setvbuf (current-output-port) 'none)

(define *got* (make-parameter 'none))

(define-command (star-command uarg)
  "A command whose specification is `*P': the raw prefix, and the
read-only check."
  (interactive "*P")
  (*got* uarg))

(define-command (star-only-command)
  "A command whose specification is `*' alone: no arguments, and the
read-only check."
  (interactive "*")
  (*got* 'ran))

(define-command (star-shift-command uarg)
  "A command whose specification stacks both leading markers, `*^P'."
  (interactive "*^P")
  (*got* uarg))

(define-command (region-args-command beg end)
  "A command whose specification is `r': the region's two positions."
  (interactive "r")
  (*got* (list beg end)))

(define-command (active-region-args-command beg end)
  "A command whose specification is `R': the region, or two nils."
  (interactive "R")
  (*got* (list beg end)))

(define-command (nil-arg-command arg)
  "A command whose specification is `i': always nil."
  (interactive "i")
  (*got* arg))

(define-command (region-and-prefix-command beg end uarg)
  "A command whose specification is `r\nP': region, then raw prefix."
  (interactive "r\nP")
  (*got* (list beg end uarg)))

(define-command (point-arg-command mark)
  "A command whose specification is `d': point, as a marker."
  (interactive "d")
  (*got* mark))

(define-command (mark-arg-command mark)
  "A command whose specification is `m': the mark, as a marker."
  (interactive "m")
  (*got* mark))

(define-command (bad-code-command)
  "A command with a code that is not one."
  (interactive "q")
  (*got* 'ran))

(define-command (string-arg-command text)
  "A command whose specification is `s': a string, prompted."
  (interactive "sYour name: ")
  (*got* text))

(define-command (symbol-arg-command sym)
  "A command whose specification is `S': the string read, interned."
  (interactive "SSymbol: ")
  (*got* sym))

(define-command (inherit-arg-command text)
  "A command whose specification is `M'."
  (interactive "MText: ")
  (*got* text))

(define-command (number-arg-command n)
  "A command whose specification is `n'."
  (interactive "nHow many: ")
  (*got* n))

(define-command (number-or-prefix-command n)
  "A command whose specification is `N': the prefix, else a read."
  (interactive "NHow many: ")
  (*got* n))

(define-command (two-reads-command first second)
  "A specification whose *second* prompt shows what the first read."
  (interactive "sFirst: \nsSecond %s: ")
  (*got* (list first second)))

(define-command (number-then-prompt-command n unit)
  "`n' then a prompt that shows the number read."
  (interactive "nWidth: \nsUnit %s: ")
  (*got* (list n unit)))

(define-command (existing-file-command name)
  "A command whose specification is `f': an existing file name."
  (interactive "fFile: ")
  (*got* name))

(define-command (new-file-command name)
  "A command whose specification is `F': a possibly nonexistent file."
  (interactive "FFile: ")
  (*got* name))

(define-command (initial-file-command name)
  "A command whose specification is `G'."
  (interactive "GDir: ")
  (*got* name))

(define-command (directory-command name)
  "A command whose specification is `D': a directory name."
  (interactive "DDir: ")
  (*got* name))

(define-command (existing-buffer-command name)
  "A command whose specification is `b': an existing buffer."
  (interactive "bBuffer: ")
  (*got* name))

(define-command (any-buffer-command name)
  "A command whose specification is `B': a possibly nonexistent buffer."
  (interactive "BBuffer: ")
  (*got* name))

(define-command (coding-system-command cs)
  "A command whose specification is `z': a coding system or nil."
  (interactive "zCoding: ")
  (*got* cs))

(define-command (non-nil-coding-command cs)
  "A command whose specification is `Z': a coding system, if a prefix."
  (interactive "ZCoding: ")
  (*got* cs))

(define-command (command-name-command cmd)
  "A command whose specification is `C': a command, by name."
  (interactive "CCommand: ")
  (*got* cmd))

(define-command (form-command form)
  "A command whose specification is `x': a form, unevaluated."
  (interactive "xForm: ")
  (*got* form))

(define-command (eval-form-command value)
  "A command whose specification is `X': a form, evaluated."
  (interactive "XForm: ")
  (*got* value))

(define-command (variable-command var)
  "A command whose specification is `v': a custom variable's name."
  (interactive "vVariable: ")
  (*got* var))

(define-command (char-command ch)
  "A command whose specification is `c': one character."
  (interactive "cChar: ")
  (*got* ch))

(define-command (key-command keys)
  "A command whose specification is `k': a key sequence."
  (interactive "kKey: ")
  (*got* keys))

(define-command (key-vector-command keys)
  "A command whose specification is `K': a key sequence as a vector."
  (interactive "KKey: ")
  (*got* keys))

(define-command (up-event-command ev)
  "A command whose specification is `U': the discarded up-event."
  (interactive "UUp: ")
  (*got* ev))

(define-command (dash-marker-command arg)
  "A command whose specification begins with `-', Lucid's no-op."
  (interactive "-P")
  (*got* arg))

(define-command (plus-marker-command)
  "A command whose specification begins with `+', which is an error."
  (interactive "+")
  (*got* 'ran))

(define-command (plain-command)
  "A command with no interactive arguments at all."
  (interactive)
  (*got* 'ran))

(define-command (aliased-command)
  "The target of `aliased-name'."
  (interactive)
  (*got* 'ran))

(define-alias aliased-name aliased-command)

(define (entry command)
  ;; The interactive entry the command loop would call.
  (command-procedure (command-record-of command)))

(define (message-of thunk)
  ;; What the echo area would show, irritants put back into the message
  ;; the way `keyboard.scm`'s `report-command-error!` does it.
  (guard (e (#t (let ((message (error-object-message e))
                      (irritants (error-object-irritants e)))
                  (if (and (list? irritants) (pair? irritants))
                      (apply format #f message irritants)
                      message))))
    (thunk)))

(define ed (allocate-buffer))

;;--------------------------------------------------------------
(test-begin "star-seam")
;;--------------------------------------------------------------
;; The seam is installed by the command loop's library, and without it a
;; `*' specification silently checks nothing.
(test-equal "the command loop installs the * check" #t
            (procedure? (*barf-if-buffer-read-only-function*)))
;; `d' and `m' reach `editfns.c`'s two marker functions the same way.
(test-equal "and editfns installs the d and m readers" '(#t #t)
            (list (procedure? (*point-marker-function*))
                  (procedure? (*mark-marker-function*))))
;; ...and the prompt formatter, which the read-codes group below relies
;; on: a specification's prompt is formatted with the arguments so far.
(test-equal "and format-message for the prompts" #t
            (procedure? (*format-message-function*)))
(test-end "star-seam")

(test-begin "star-marker")
;;--------------------------------------------------------------
;; "*" alone: no arguments, and the body runs on a writable buffer.
(with-current-buffer ed
  (test-equal "a * command runs on a writable buffer" 'ran
              (begin ((entry star-only-command) #f) (*got*)))
  (test-equal "and its body got no argument" 'ran (*got*)))

;; ...and refuses on a read-only one, *before* the body - which is the
;; whole point of `*' rather than a check the command writes itself.
(with-current-buffer ed
  (set!buffer-read-only (current-buffer) #t)
  (*got* 'none)
  (test-equal "a * command signals on a read-only buffer"
              "Buffer is read-only"
              (message-of (lambda () ((entry star-only-command) #f))))
  (test-equal "and its body never ran" 'none (*got*))
  (set!buffer-read-only (current-buffer) #f))

;; "*P": the marker is stripped and what follows is read as usual, so the
;; prefix still reaches the command.
(with-current-buffer ed
  (test-equal "a *P command still gets the raw prefix" '(4)
              (begin ((entry star-command) '(4)) (*got*)))
  (set!buffer-read-only (current-buffer) #t)
  (test-equal "and still checks the buffer first" "Buffer is read-only"
              (message-of (lambda () ((entry star-command) '(4)))))
  (set!buffer-read-only (current-buffer) #f))

;; The markers stack, one per recursion, as the C's loop over the
;; leading characters reads them: `*^P' is the check, then the `^'
;; marker (dropped here - there is no shift-select), then the prefix.
(with-current-buffer ed
  (test-equal "*^P reads the check, then the marker, then the code" '(4)
              (begin ((entry star-shift-command) '(4)) (*got*))))
(test-end "star-marker")

(test-begin "region-codes")
;;--------------------------------------------------------------
;; "r": the two positions, smaller first, whichever way round point
;; and mark are.
(with-current-buffer ed
  (insert "hello world\n")
  (goto-char 1)
  (set-mark 6)
  (test-equal "r gives the region's two positions" '(1 6)
              (begin ((entry region-args-command) #f) (*got*)))
  (goto-char 12)
  (test-equal "r sorts them, point above mark" '(6 12)
              (begin ((entry region-args-command) #f) (*got*)))
  ;; "R" is the same while the region is active...
  (goto-char 1)
  (test-equal "R gives the region while it is active" '(1 6)
              (begin ((entry active-region-args-command) #f) (*got*)))
  ;; ...and two nils once it is not, where "r" signals.
  (deactivate-mark)
  (test-equal "R gives two nils for an inactive region" '(#f #f)
              (begin ((entry active-region-args-command) #f) (*got*)))
  (test-equal "and r signals for one" "The mark is not active now"
              (message-of (lambda () ((entry region-args-command) #f))))
  ;; The mark being unset is the other error, and `check_mark`'s order
  ;; asks it first - which is why it is `callint.c`'s and not
  ;; `region_limit`'s.
  (set-mark #f)
  (test-equal "r with no mark set says there is no region"
              "The mark is not set now, so there is no region"
              (message-of (lambda () ((entry region-args-command) #f))))
  (test-equal "and R does not signal at all" '(#f #f)
              (begin ((entry active-region-args-command) #f) (*got*))))
(test-end "region-codes")

(test-begin "multi-code-specs")
;;--------------------------------------------------------------
;; "r\nP": the newline separates codes and contributes nothing, so the
;; three arguments arrive in the order the codes are written.
(with-current-buffer ed
  (goto-char 1)
  (set-mark 6)
  (test-equal "a newline separates codes" '(1 6 (4))
              (begin ((entry region-and-prefix-command) '(4)) (*got*)))
  ;; "i" ignores the prefix and supplies nil.
  (test-equal "i supplies nil" #f
              (begin ((entry nil-arg-command) '(4)) (*got*)))
  ;; "-" is Lucid's no-op marker, peeled with the others.
  (test-equal "- is ignored and the rest is read" '(4)
              (begin ((entry dash-marker-command) '(4)) (*got*)))
  ;; "+" is "not used in `interactive' for ordinary commands".
  (test-equal "+ is an error" "`+' is not used in `interactive' for ordinary commands"
              (message-of (lambda () ((entry plus-marker-command) #f)))))
(test-end "multi-code-specs")

(test-begin "no-io-codes")
;;--------------------------------------------------------------
;; "d" - "Value of point. Does not do I/O" (`callint.c:502') - is a
;; *marker* at point, which the command may keep, not a position.
(with-current-buffer ed
  (goto-char 4)
  (test-equal "d gives a marker at point" 4
              (begin ((entry point-arg-command) #f) (marker-position (*got*))))
  (test-equal "and it is attached to the buffer" (current-buffer)
              (marker-buffer (*got*)))
  (goto-char 7)
  (test-equal "the marker is a point in time, so it does not follow point" 4
              (marker-position (*got*)))

  ;; "m" - "Value of mark. Does not do I/O" (`:623') - is the buffer's
  ;; *own* mark marker, so moving the returned marker moves the mark.
  (set-mark 6)
  (test-equal "m gives the mark as a marker" 6
              (begin ((entry mark-arg-command) #f) (marker-position (*got*))))
  (test-equal "and it is the buffer's own mark marker" #t
              (eq? (*got*) (mark-marker)))

  ;; The mark check is `check_mark (false)': the no-region message is
  ;; "so there is no region" and this one is not.
  (set-mark #f)
  (*got* 'none)
  (test-equal "m with no mark set says only that the mark is not set"
              "The mark is not set now"
              (message-of (lambda () ((entry mark-arg-command) #f))))
  (test-equal "and the body never ran" 'none (*got*)))
(test-end "no-io-codes")

(test-begin "bad-code")
;;--------------------------------------------------------------
;; An unread code is Emacs's error, naming the letter and its two
;; numbers - "Invalid control letter `%c' (#o%03o, #x%04x) in
;; interactive calling string" (`callint.c:744'), measured on Emacs
;; 31.1 (which renders the quotes as `‘q’' on a terminal).
(with-current-buffer ed
  (test-equal "an unread code names the letter, its octal and its hex"
              "Invalid control letter `q' (#o161, #x0071) in interactive calling string"
              (message-of (lambda () ((entry bad-code-command) #f)))))
(test-end "bad-code")
;;--------------------------------------------------------------
(test-begin "read-codes")
;;--------------------------------------------------------------
;; `s', `S', `M', `n' and `N' read the minibuffer, which this suite does
;; not load - so the *readers* are stubs and what is under test is the
;; machinery around them: the prompt a code is given (the text after the
;; code up to the next newline, `callint.c:441`), the order the
;; arguments arrive in, and what a *later* prompt shows of an earlier
;; answer (`Fformat_message (i - 1, visargs + 1)`).
(define *prompts* (make-parameter '()))
(define *answers* (make-parameter '()))

(define (stub-reader)
  ;; Answers the next scripted value and records the prompt it was
  ;; asked with.
  (lambda (prompt)
    (*prompts* (append (*prompts*) (list prompt)))
    (let ((rest (*answers*)))
      (if (pair? rest)
          (begin (*answers* (cdr rest)) (car rest))
          #f))))

(define-syntax with-readers
  ;; Bind both readers to stubs, with a fresh script of ANSWERS. The
  ;; format-message seam is left alone: `editfns.scm` is in this suite's
  ;; import graph, so the *real* one formats the prompts - which is the
  ;; point of the two formatting tests below.
  (syntax-rules ()
    ((_ answers body ...)
     (parameterize ((*read-string-function* (stub-reader))
                    (*read-number-function* (stub-reader))
                    (*prompts* '())
                    (*answers* answers))
       body ...))))

(with-current-buffer ed
  (with-readers '("Alice")
    (test-equal "s reads a string" "Alice"
                (begin ((entry string-arg-command) #f) (*got*)))
    (test-equal "and its prompt is the text after the code"
                '("Your name: ") (*prompts*)))

  (with-readers '("alice")
    (test-equal "S interns what it read" 'alice
                (begin ((entry symbol-arg-command) #f) (*got*)))
    (test-equal "with the same prompt rule" '("Symbol: ") (*prompts*)))

  (with-readers '("some text")
    (test-equal "M reads a string too" "some text"
                (begin ((entry inherit-arg-command) #f) (*got*))))

  (with-readers '(42)
    (test-equal "n reads a number" 42
                (begin ((entry number-arg-command) #f) (*got*)))
    (test-equal "from its prompt" '("How many: ") (*prompts*)))

  ;; `N' is `p' when there is a prefix - "goto have_prefix_arg" - and a
  ;; read only when there is none.
  (with-readers '(7)
    (test-equal "N takes the prefix when there is one" 4
                (begin ((entry number-or-prefix-command) '(4)) (*got*)))
    (test-equal "and reads nothing" '() (*prompts*))
    (test-equal "N reads a number when there is no prefix" 7
                (begin ((entry number-or-prefix-command) #f) (*got*))))

  ;; The prompt of a later code is formatted with the arguments so far -
  ;; which is why a specification can say `"sQuery replace %s with: "'.
  (with-readers '("one" "two")
    (test-equal "the two reads, in order" '("one" "two")
                (begin ((entry two-reads-command) #f) (*got*)))
    (test-equal "and the second prompt shows the first answer"
                '("First: " "Second one: ") (*prompts*)))

  ;; `n`'s visible form is the number as a string (`Fnumber_to_string`),
  ;; not the number.
  (with-readers '(42 "px")
    (test-equal "a number read is shown as its string in a prompt"
                '(42 "px")
                (begin ((entry number-then-prompt-command) #f) (*got*)))
    (test-equal "so the unit prompt reads Unit 42:" '("Width: " "Unit 42: ")
                (*prompts*))))

;;--------------------------------------------------------------
;; The file codes. `files.scm` is *not* in this suite's import graph, so
;; both seams are stubs - and the stub records the whole call, which is
;; what pins the constants the C passes:
;;
;;   f -> read_file_name (prompt, Qnil, Qnil,       Qlambda, Qnil, Qnil)
;;   F -> read_file_name (prompt, Qnil, Qnil,       Qnil,    Qnil, Qnil)
;;   G -> read_file_name (prompt, Qnil, Qnil,       Qnil,    "",   Qnil)
;;   D -> read_file_name (prompt, Qnil, DIRECTORY,  Qlambda, Qnil, Qfile_directory_p)
;;
;; MUSTMATCH is the *symbol* `lambda', not t: `completing-read' binds
;; `minibuffer-completion-confirm' to anything that is not t, so the two
;; are not interchangeable.
(define *calls* (make-parameter '()))

(define (stub-file-reader)
  (lambda args
    (*calls* (append (*calls*) (list args)))
    "ANSWER"))

(define-syntax with-file-readers
  (syntax-rules ()
    ((_ body ...)
     (parameterize ((*interactive-read-file-name-function* (stub-file-reader))
                    (*interactive-read-directory-name-function* (stub-file-reader))
                    (*calls* '()))
       body ...))))

(with-current-buffer ed
  (with-file-readers
    (test-equal "f reads with MUSTMATCH the symbol lambda"
                (list (list "File: " 'lambda #f))
                (begin ((entry existing-file-command) #f) (*calls*)))
    (test-equal "and the command gets what it read" "ANSWER" (*got*)))

  (with-file-readers
    (test-equal "F reads with MUSTMATCH nil" (list (list "File: " #f #f))
                (begin ((entry new-file-command) #f) (*calls*))))

  (with-file-readers
    (test-equal "G reads with INITIAL the empty string"
                (list (list "Dir: " #f ""))
                (begin ((entry initial-file-command) #f) (*calls*))))

  (with-file-readers
    (test-equal "D reads with the prompt alone, the rest being files.scm's"
                (list (list "Dir: "))
                (begin ((entry directory-command) #f) (*calls*)))
    (test-equal "and the command still gets its name" "ANSWER" (*got*)))

  ;; The buffer codes, on the same two recorders. `minibuffer.scm` is not
  ;; in this suite's graph either, and `b` and `B` differ in the DEFAULT
  ;; and the MUSTMATCH the C passes, both of which the installer supplies.
  (parameterize ((*interactive-read-existing-buffer-function*
                  (stub-file-reader))
                 (*interactive-read-buffer-function* (stub-file-reader))
                 (*calls* '()))
    (test-equal "b reads with the prompt alone" (list (list "Buffer: "))
                (begin ((entry existing-buffer-command) #f) (*calls*)))
    (test-equal "and the command gets what was read" "ANSWER" (*got*))
    ;; a fresh recorder, or B's assertion would see b's call too
    (*calls* '())
    (test-equal "B reads with the prompt alone too" (list (list "Buffer: "))
                (begin ((entry any-buffer-command) #f) (*calls*))))

  ;; `z' always reads; `Z' reads only when there is a prefix, and
  ;; answers nil without one - the C's `varies[i] = -1' branch, which
  ;; touches the minibuffer not at all.
  ;; `read-coding-system` answers a *symbol* (or nil), which is what the
  ;; visible form converts back to a string.
  (define (stub-symbol-reader)
    (lambda args
      (*calls* (append (*calls*) (list args)))
      'utf-8))
  (parameterize ((*read-coding-system-function* (stub-symbol-reader))
                 (*read-non-nil-coding-system-function* (stub-symbol-reader))
                 (*calls* '()))
    (test-equal "z reads a coding system" 'utf-8
                (begin ((entry coding-system-command) #f) (*got*)))
    (test-equal "from its prompt" (list (list "Coding: ")) (*calls*))
    (*calls* '())
    (test-equal "Z with no prefix answers nil and reads nothing" #f
                (begin ((entry non-nil-coding-command) #f) (*got*)))
    (test-equal "so the reader was never called" '() (*calls*))
    (test-equal "Z with a prefix does read" 'utf-8
                (begin ((entry non-nil-coding-command) '(4)) (*got*)))
    (test-equal "and it was called once" (list (list "Coding: ")) (*calls*)))

  ;; `C', `x' and `X'. The `C' reader answers a symbol like
  ;; `read-command'; `x' and `X` answer the *form*, and `X`'s is already
  ;; evaluated when the code receives it - the difference between the two
  ;; codes is the reader, not anything `%interactive-args` does.
  (parameterize ((*read-command-function* (stub-symbol-reader))
                 (*read-variable-function* (stub-symbol-reader))
                 (*read-minibuffer-function* (stub-file-reader))
                 (*eval-minibuffer-function*
                  (lambda (prompt)
                    (*calls* (append (*calls*) (list (list prompt))))
                    42))
                 (*calls* '()))
    (test-equal "C reads a command name, as a symbol" 'utf-8
                (begin ((entry command-name-command) #f) (*got*)))
    (test-equal "from its prompt" (list (list "Command: ")) (*calls*))
    (*calls* '())
    (test-equal "x hands the command the form the reader answered" "ANSWER"
                (begin ((entry form-command) #f) (*got*)))
    (test-equal "X hands it the evaluated value" 42
                (begin ((entry eval-form-command) #f) (*got*)))
    (*calls* '())
    (test-equal "v reads a custom variable's name" 'utf-8
                (begin ((entry variable-command) #f) (*got*)))
    (test-equal "from its prompt" (list (list "Variable: ")) (*calls*)))

  ;; `c'. The reader answers a *character code* (the C's
  ;; `char_resolve_modifier_mask` result), the echo area is cleared
  ;; after it, and anything that is not a character is the C's
  ;; "Non-character input-event".
  (parameterize ((*read-char-event-function* (lambda (prompt)
                                               (*calls* (append (*calls*)
                                                                (list (list prompt))))
                                               113))
                 (*message-clear-function* (lambda ()
                                             (*got* 'cleared)))
                 (*calls* '())
                 (*got* 'none))
    (test-equal "c reads a character" 113
                (begin ((entry char-command) #f) (*got*)))
    (test-equal "from its prompt" (list (list "Char: ")) (*calls*))
    (parameterize ((*read-char-event-function* (lambda (prompt) #f)))
      (test-equal "a reader that answers no character is an error"
                  "Non-character input-event"
                  (message-of (lambda () ((entry char-command) #f))))))

  ;; `k', `K' and `U'. The readers answer the sequence; `K' is the same
  ;; read asked for a vector, and `U' reads nothing at all - its answer
  ;; is nil because the down-event discard that would fill it is not
  ;; carried.
  (parameterize ((*read-key-sequence-function* (lambda (prompt) "C-x C-c"))
                 (*read-key-sequence-vector-function*
                  (lambda (prompt) (vector 24 3)))
                 (*calls* '())
                 (*got* 'none))
    (test-equal "k reads a key sequence" "C-x C-c"
                (begin ((entry key-command) #f) (*got*)))
    (test-equal "K reads one as a vector" (vector 24 3)
                (begin ((entry key-vector-command) #f) (*got*)))
    (test-equal "U reads nothing and answers nil" #f
                (begin ((entry up-event-command) #f) (*got*)))))
(test-end "read-codes")
;;--------------------------------------------------------------
(test-begin "plain-specs")
;; `(interactive)` - the empty specification - is a thunk, which is why
;; the `*' marker had to decide its call shape from what remains of the
;; string rather than from the marker itself.
(with-current-buffer ed
  (test-equal "an empty specification runs with no arguments" 'ran
              (begin ((entry plain-command)) (*got*))))
(test-end "plain-specs")

(test-begin "define-alias")
;;--------------------------------------------------------------
;; One procedure, two names, one record - Emacs's `defalias'.
(test-equal '(#t #t)
  (list (eq? aliased-name aliased-command)
        (eq? (command-record-named "aliased-name")
             (command-record-named "aliased-command"))))
(test-end "define-alias")
