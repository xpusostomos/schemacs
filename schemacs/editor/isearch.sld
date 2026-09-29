(define-library (schemacs editor isearch)
  ;; This library mirrors GNU Emacs's `isearch.el': the incremental
  ;; search - `isearch-forward' (C-s) and `isearch-backward' (C-r), the
  ;; search string as it is typed, the states DEL takes back, and the
  ;; message in the echo area.
  ;;
  ;; It is a command that reads its own keys rather than going through the
  ;; command loop, exactly as Emacs's isearch does: isearch is entered by
  ;; one command and reads keys until a key ends it, so each of its keys
  ;; is handled here rather than dispatched from a keymap.
  ;;
  ;; It publishes `*search-highlight*' (which lives with the display,
  ;; `(schemacs editor xdisp)') so that what it found is drawn - the same
  ;; fact that GNU Emacs records as the `isearch' and `lazy-highlight'
  ;; faces on the match. Keeping those two in step is the one thing here
  ;; that nothing else would notice going wrong, which is why
  ;; `tools/pty-check.py isearch-highlight' exists.
  ;;
  ;; See LAYOUT-PLAN.txt for the rule this library is a step of.

  (import
    (scheme base)
    (scheme char)
    (scheme case-lambda)
    ;; `caddr' and `cadddr' are `(scheme cxr)'s, not `(scheme base)''s.
    ;; Without this the file loads and the failure waits for the first
    ;; search that reads a match: "Unbound variable: caddr" at run time,
    ;; which is the class of bug this project keeps meeting.
    (only (scheme cxr) caddr cadddr)
    ;; isearch reads its keys itself, so it needs the terminal - and only
    ;; these three names of it. Guile-ncurses exports a `define-key' of its
    ;; own, so importing the whole module would put that name in the same
    ;; library as `(schemacs editor keymap)'s, and the winner would be
    ;; whichever import came last.
    (only (ncurses curses) getch KEY_BACKSPACE stdscr ungetch)
    ;; `define-key' and the global map: the keys C-s and C-r are stated
    ;; here, beside the commands they run.
    (only (schemacs editor keymap)
         define-key
         *default-keymap*)
    (only (schemacs editor engine)
         set!text-editor-mark text-editor-char-count
         text-editor-get-char-index text-editor-get-cursor
         text-editor-search-backward text-editor-search-forward
         text-editor-set-cursor
          )
    (only (schemacs editor frame)
         *current-frame* current-editor set!ncurses-frame-message
          )
    (only (schemacs editor command) defcommand)
    (only (schemacs editor simple)
         current-kill word-char?
          )
    (only (schemacs editor xdisp)
         *search-highlight* render!
          )
    )

  (export
   *search-case-fold?* *search-pattern* isearch isearch-backward isearch-find
   isearch-forward isearch-message isearch-pop-state isearch-pop-to-success
   isearch-repeat isearch-search! isearch-word-at-point
   )

  (begin

    ;;----------------------------------------------------------------
    ;; Incremental search
    ;;
    ;; GNU Emacs's `isearch-forward' (C-s) and `isearch-backward' (C-r),
    ;; and mg's isearch(dir): a search that runs again on every key, so
    ;; that the match follows what is being typed. The two references
    ;; agree on the parts that are easy to get wrong, and both were
    ;; checked against the running Emacs:
    ;;
    ;;  - each search runs from the START of the current match, so that
    ;;    extending the pattern re-tries it where the last one began
    ;;    rather than past its end (mg's is_find backs up by the length
    ;;    of the pattern; Emacs reaches the same place by retrying);
    ;;  - point ends at the far end of the match: past it when searching
    ;;    forward, at its start when searching backward. Emacs's
    ;;    `isearch-search-string' says so - "If found, move point to the
    ;;    end of the occurrence" - and mg's forwsrch leaves dot there
    ;;    too;
    ;;  - a search that fails leaves point where it was;
    ;;  - C-s at the last match fails first, and wraps on the NEXT C-s
    ;;    (Emacs's `isearch-wrap-pause' is t by default). mg wraps on the
    ;;    first failing C-s, which is the one place the two differ;
    ;;  - DEL takes back the last thing typed, and C-g while the search
    ;;    is failing takes back characters until it succeeds again; C-g
    ;;    on a successful search abandons it and puts point back where
    ;;    the search started;
    ;;  - leaving the search sets the mark where it started, so there is
    ;;    a way back to it (Emacs's `isearch-done').
    ;;------------------------------------------------------------------

    (define (isearch-message pattern direction success? wrapped? case-fold? point opoint)
      ;; The echo area during a search: GNU Emacs's
      ;; `isearch-message-prefix' followed by the search string. Emacs
      ;; builds the words in lower case and capitalises the first letter,
      ;; so "failing I-search" is shown as "Failing I-search".
      ;;--------------------------------------------------------------
      (let* ((forward? (eq? direction 'forward))
             (over? (and wrapped?
                         (if forward? (< opoint point) (> opoint point))))
             (text (string-append
                    (if success? "" "failing ")
                    (if over? "over" "")
                    (if wrapped? "wrapped " "")
                    (if (and (not success?) (not case-fold?))
                        "case-sensitive " "")
                    (if forward? "I-search" "I-search backward")
                    ": "
                    pattern)))
        (string-append (string-upcase (substring text 0 1))
                       (substring text 1))))

    (define (isearch-find ed pattern direction case-fold? step?)
      ;; Where the search for PATTERN should leave point, or #f when it
      ;; is not found. When STEP? the search starts one character on in
      ;; DIRECTION, which is how a repeated search finds the next match
      ;; instead of the one it is already on (mg's isearch moves a
      ;; character before each repeat).
      ;;--------------------------------------------------------------
      (let* ((forward? (eq? direction 'forward))
             (count (text-editor-char-count ed))
             (point (text-editor-get-cursor ed))
             (len (string-length pattern))
             (start (if step?
                        (if forward? (+ point 1) (- point 1))
                        point)))
        (and (<= 0 start count)
             (let ((from (if forward?
                             (max 0 (- start len))
                             (min count (+ start len)))))
               (if forward?
                   (text-editor-search-forward
                    ed pattern from case-fold?)
                   (text-editor-search-backward
                    ed pattern from case-fold?))))))

    (define (isearch-search! ed pattern direction case-fold?)
      ;; Run the search for PATTERN and move point to the match, the way
      ;; GNU Emacs's `isearch-search' does on every keystroke that
      ;; changes the search string. Reports whether it was found; when it
      ;; was not, point is left where it was.
      ;;--------------------------------------------------------------
      (let ((found (isearch-find ed pattern direction case-fold? #f)))
        (when found (text-editor-set-cursor ed found))
        (and found #t)))

    (define *search-case-fold?*
      ;; Whether the search in progress folds case, GNU Emacs's
      ;; `isearch-case-fold-search'. The renderer needs it as well as the
      ;; pattern, so that it highlights exactly what the search matched.
      ;;--------------------------------------------------------------
      (make-parameter #t))

    (define *search-pattern*
      ;; The search string of the search in progress, or false when there
      ;; is none: what the renderer highlights matches with. GNU Emacs
      ;; keeps the same thing in `isearch-string'.
      ;;--------------------------------------------------------------
      (make-parameter #f))

    (define (isearch forward?)
      ;; The incremental search itself: read a key, act on it, search
      ;; again, and keep going until a key ends the search. Returns
      ;; nothing; point and the mark are left as the search left them.
      ;;--------------------------------------------------------------
      (let* ((frame (*current-frame*))
             (ed (current-editor))
             (opoint (text-editor-get-cursor ed)))
        (let loop ((pattern "")
                   (direction (if forward? 'forward 'backward))
                   (states '())
                   (success? #t)
                   (wrapped? #f)
                   ;; a search folds case until an upper-case letter is
                   ;; typed into it (Emacs's `search-upper-case')
                   (case-fold? #t))
          (*search-pattern* (and (< 0 (string-length pattern)) pattern))
          (*search-case-fold?* case-fold?)
          ;; and tell the renderer what to draw as matches. In GNU Emacs
          ;; this is not a variable at all: isearch puts the `isearch'
          ;; face on the match point is on and `lazy-highlight' on the
          ;; others, and the display finds them as text properties. With
          ;; no properties here, the search publishes the same fact for
          ;; the display to read.
          (*search-highlight* (and (< 0 (string-length pattern))
                                   (cons pattern case-fold?)))
          (set!ncurses-frame-message
           frame
           (isearch-message pattern direction success? wrapped? case-fold?
                            (text-editor-get-cursor ed) opoint))
          (render! frame)
          (let* ((raw (getch (stdscr)))
                 ;; the keypad sends Backspace as a key code, not as the
                 ;; character the search's DEL key is
                 (ev (if (and (integer? raw) (= raw KEY_BACKSPACE))
                         #\backspace
                         raw)))
            (cond
             ;; ---- keys that end the search ----
             ((and (char? ev) (char=? ev #\return))          ; isearch-exit
              (*search-pattern* #f)
              (*search-highlight* #f)
              (set!ncurses-frame-message frame "")
              (when (not (= (text-editor-get-cursor ed) opoint))
                (set!text-editor-mark ed opoint)
                (set!ncurses-frame-message
                 frame "Mark saved where search started")))
             ;; isearch-abort: give up the search if it found something,
             ;; otherwise take back what was typed until it finds again
             ((and (char? ev) (= (char->integer ev) 7))
              (if success?
                  (begin
                    (text-editor-set-cursor ed opoint)
                    (*search-pattern* #f)
                    (*search-highlight* #f)
                    (set!ncurses-frame-message frame "Quit"))
                  (let ((popped (isearch-pop-to-success ed states)))
                    (loop (car popped) direction (cdr popped) #t #f
                          case-fold?))))
             ;; ---- keys that move the search on ----
             ((and (char? ev) (= (char->integer ev) 19))     ; C-s
              (let ((next (isearch-repeat ed states pattern direction
                                          case-fold? success? wrapped?
                                          'forward)))
                (loop (car next) 'forward (cadr next) (caddr next)
                      (cadddr next) case-fold?)))
             ((and (char? ev) (= (char->integer ev) 18))     ; C-r
              (let ((next (isearch-repeat ed states pattern direction
                                          case-fold? success? wrapped?
                                          'backward)))
                (loop (car next) 'backward (cadr next) (caddr next)
                      (cadddr next) case-fold?)))
             ((and (char? ev)
                   (or (char=? ev #\backspace) (= (char->integer ev) 127)))
              ;; isearch-delete-char: take back the last thing typed
              (if (null? states)
                  (loop pattern direction states success? wrapped? case-fold?)
                  (let ((popped (isearch-pop-state ed states)))
                    (loop (car popped) direction (cdr popped) #t #f
                          case-fold?))))
             ;; ---- keys that add to the search string ----
             ((and (char? ev) (= (char->integer ev) 23))     ; C-w
              ;; isearch-yank-word-or-char: the word (or character) at
              ;; point joins the search string
              (let ((new (string-append pattern (isearch-word-at-point ed))))
                (loop new direction
                      (cons (list pattern (text-editor-get-cursor ed) success?)
                            states)
                      (isearch-search! ed new direction case-fold?)
                      #f case-fold?)))
             ((and (char? ev) (= (char->integer ev) 25))     ; C-y
              ;; `isearch-yank-kill': "the latest kill joins the search
              ;; string" - Emacs's `(isearch-yank-string (current-kill 0))',
              ;; which also moves the ring's yank pointer.
              (let ((new (string-append pattern (current-kill 0))))
                (loop new direction
                      (cons (list pattern (text-editor-get-cursor ed) success?)
                            states)
                      (isearch-search! ed new direction case-fold?)
                      #f case-fold?)))
             ;; isearch-printing-char: the character joins the search
             ;; string. C-j and TAB count as characters to search for,
             ;; as they do in Emacs's isearch keymap.
             ((and (char? ev)
                   (or (char<=? #\space ev)
                       (char=? ev #\tab) (char=? ev #\newline)))
              (let* ((new (string-append pattern (string ev)))
                     ;; Emacs's `search-upper-case': an upper-case
                     ;; letter TYPED into the search string turns case
                     ;; folding off; one yanked with C-w or C-y does not.
                     (fold? (and case-fold?
                                      (not (char-upper-case? ev)))))
                (loop new direction
                      (cons (list pattern (text-editor-get-cursor ed) success?)
                            states)
                      (isearch-search! ed new direction fold?)
                      #f fold?)))
             ;; a control character the search does not use ends it and gives
             ;; the key back to the command loop: GNU Emacs's
             ;; `isearch-other-control-char' exits the search
             ;; (`isearch-exit') and re-executes the key, so `C-s C-s
             ;; C-x C-c' quits the editor instead of eating the `C-x'
             ;; and leaving `C-c' as an undefined key. The mark is left
             ;; alone, as it is on this exit.
             ((and (char? ev) (char<? ev #\space))
              (*search-pattern* #f)
              (*search-highlight* #f)
              (set!ncurses-frame-message frame "")
              (ungetch ev))
             ;; anything else (a keypad key, end of input) is not an
             ;; answer to the search
             (else
              (loop pattern direction states success? wrapped? case-fold?)))))))

    (define (isearch-pop-state ed states)
      ;; Take back the last state the search pushed, as DEL does.
      ;; Returns (pattern . states-left), with point put back where that
      ;; state was. A state is (pattern point success?).
      ;;--------------------------------------------------------------
      (if (null? states)
          (cons "" '())
          (let ((state (car states)))
            (text-editor-set-cursor ed (cadr state))
            (cons (car state) (cdr states)))))

    (define (isearch-pop-to-success ed states)
      ;; Take back states until the search was succeeding again, which is
      ;; what C-g does while a search is failing (GNU Emacs's
      ;; `isearch-abort': "rub out until it is once more successful").
      ;; Returns (pattern . states-left).
      ;;--------------------------------------------------------------
      (let loop ((states states))
        (let ((popped (isearch-pop-state ed states)))
          (if (or (null? (cdr popped)) (caddr (car states)))
              popped
              (loop (cdr popped))))))

    (define (isearch-repeat ed states pattern direction case-fold?
                            success? wrapped? new-direction)
      ;; A repeated search: C-s or C-r while searching. Turning the search
      ;; around just searches the other way from where point is; the same
      ;; direction again moves on to the next match, and when there is
      ;; none the search fails - and only the repeat AFTER that one wraps
      ;; to the far end of the buffer (Emacs's `isearch-wrap-pause' is t:
      ;; pause first, then wrap). Returns
      ;; (pattern states success? wrapped?).
      ;;--------------------------------------------------------------
      (let* ((turning? (not (eq? direction new-direction)))
             (forward? (eq? new-direction 'forward))
             (here (text-editor-get-cursor ed))
             (found (cond
                     (turning?
                      (isearch-find ed pattern new-direction case-fold? #f))
                     (success?
                      (isearch-find ed pattern new-direction case-fold? #t))
                     (else
                      ;; the search was failing, so this repeat wraps
                      (text-editor-set-cursor
                       ed (if forward? 0 (text-editor-char-count ed)))
                      (isearch-find ed pattern new-direction
                                    case-fold? #f)))))
        (if found
            (begin
              (text-editor-set-cursor ed found)
              (list pattern
                    (cons (list pattern here success?) states)
                    #t
                    ;; the wrap is reported for the search that wrapped,
                    ;; not for the next match found after it
                    (if (or turning? success?) #f #t)))
            (list pattern states #f wrapped?))))

    (define (isearch-word-at-point ed)
      ;; The word at point, or the character at point when it is not part
      ;; of one - GNU Emacs's `isearch-yank-word-or-char'.
      ;;--------------------------------------------------------------
      (let* ((point (text-editor-get-cursor ed))
             (count (text-editor-char-count ed))
             (c (and (< point count) (text-editor-get-char-index ed point))))
        (cond
         ((not c) "")
         ((word-char? c)
          (let loop ((i point) (acc '()))
            (let ((ch (and (< i count) (text-editor-get-char-index ed i))))
              (if (and ch (word-char? ch))
                  (loop (+ 1 i) (cons ch acc))
                  (list->string (reverse acc))))))
         (else (string c)))))

    (defcommand isearch-forward ()
      "Search forward incrementally (bound to C-s)."
      (interactive)
      (isearch #t))

    (defcommand isearch-backward ()
      "Search backward incrementally (bound to C-r)."
      (interactive)
      (isearch #f))

    ;; The keys GNU Emacs binds the search to, beside the commands.
    (define-key *default-keymap* (list (list 'ctrl #\s)) isearch-forward)
    (define-key *default-keymap* (list (list 'ctrl #\r)) isearch-backward)

    ))
