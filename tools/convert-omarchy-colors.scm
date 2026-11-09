#!/usr/bin/env guile
!#
;;; convert-omarchy-colors.scm --- an Omarchy `colors.toml' to a theme
;;;
;;; Omarchy's themes are 25-odd colour keys in a `colors.toml' and
;;; nothing else; omarchy.el's `themes/*.el' are hand-tuned per Neovim
;;; scheme. This is the other route: the mapping Omarchy itself gives
;;; `aether.nvim' (`default/themed/neovim.lua.tpl' hands those keys
;;; straight to the scheme) turned into a Modus palette, so a theme
;;; Omarchy ships but omarchy.el has not ported - `jade-horse',
;;; `starship', or one added tomorrow - can still be followed.
;;;
;;;     guile -L . -s tools/convert-omarchy-colors.scm jade-horse
;;;     guile -L . -s tools/convert-omarchy-colors.scm starship --out DIR
;;;
;;; **One theme, named on the command line.** The colours are the
;;; theme's own; the face expansion is still Modus's - the palette and
;;; the semantic mappings are written into a temporary `-theme.el' and
;;; expanded by `modus-themes-theme' in a real Emacs, exactly as
;;; `convert-omarchy-themes.scm' does for omarchy.el's files. So the
;;; result has the same face coverage as the bundled themes.
;;;
;;; It is a *generic derivation*, not a reproduction. The slot rules
;;; below are the majority answer across omarchy.el's 22 hand-written
;;; themes, and the counts in the comments say so; where those themes
;;; disagree with each other - the surface shades especially - this
;;; cannot match any one of them. The diff backgrounds and foregrounds
;;; are not in `colors.toml' at all and are blended from the theme's
;;; green/red/yellow and its surfaces.
;;;
;;; The Elisp this runs prints the `theme-settings' in *Scheme* syntax
;;; (vectors as `#(...)', nil as the symbol `nil'), so this reads it
;;; with Scheme's own reader instead of an Elisp one. That is the half
;;; `convert-omarchy-themes.scm' cannot share: it has the Elisp reader,
;;; this does not need it.

;; The `except's are the warning fix, not a preference: a script is
;; loaded into `(guile-user)', whose parent already binds these six, and
;; importing `(scheme base)' over them prints "overrides core binding"
;; the first time each is looked up - which for a run is on every run.
;; Same names, same procedures; only the warning differs.
(import (except (scheme base) map for-each assoc vector->list string-for-each
                        error)
        (scheme file)
        (scheme read)
        (scheme write)
        (except (scheme process-context) exit)
        (ice-9 format)
        (only (guile) sort getpid system copy-file string-index mkdir)
        (only (srfi srfi-1) filter find fold))

;;------------------------------------------------------------------
;; Reading a colors.toml
;;
;; The subset Omarchy ships is `KEY = "VALUE"' and whole-line `#'
;; comments. A `#' inside a value is the start of a hex colour, so only
;; a line whose first non-space character is `#' is a comment.
;;------------------------------------------------------------------

(define (string-trim-left* s)
  (let loop ((i 0))
    (cond ((= i (string-length s)) "")
          ((char-whitespace? (string-ref s i)) (loop (+ i 1)))
          (else (substring s i (string-length s))))))

(define (string-trim-right* s)
  (let loop ((i (string-length s)))
    (cond ((= i 0) "")
          ((char-whitespace? (string-ref s (- i 1))) (loop (- i 1)))
          (else (substring s 0 i)))))

(define (string-trim* s)
  (string-trim-right* (string-trim-left* s)))

(define (read-lines path)
  (call-with-input-file path
    (lambda (port)
      (let loop ((out '()))
        (let ((line (read-line port)))
          (if (eof-object? line)
              (reverse out)
              (loop (cons line out))))))))

(define (unquote-value s)
  (if (and (>= (string-length s) 2)
           (char=? (string-ref s 0) #\")
           (char=? (string-ref s (- (string-length s) 1)) #\"))
      (substring s 1 (- (string-length s) 1))
      (error "colors.toml value is not a quoted string" s)))

(define (parse-colors path)
  "Answer (values ALIST MODE): the colour keys in file order, and `dark' or `light'."
  (let* ((lines (read-lines path))
         (colours
          (filter (lambda (cell) (not (string=? (car cell) "mode")))
                  (filter
                   (lambda (cell) cell)
                   (map
                    (lambda (line)
                      (let ((trimmed (string-trim-left* line)))
                        (cond
                         ((or (string=? trimmed "")
                              (char=? #\# (string-ref trimmed 0)))
                          #f)
                         (else
                          (let ((eq (string-index line #\=)))
                            (unless eq
                              (error "colors.toml line has no =: " line))
                            (cons (string-trim* (substring line 0 eq))
                                  (unquote-value
                                   (string-trim* (substring line (+ eq 1)
                                                            (string-length line))))))))))
                    lines))))
         (mode-cell (find (lambda (cell)
                            (and cell (string=? (car cell) "mode")))
                          (map (lambda (line)
                                 (let ((trimmed (string-trim-left* line)))
                                   (if (or (string=? trimmed "")
                                           (char=? #\# (string-ref trimmed 0)))
                                       #f
                                       (let ((eq (string-index line #\=)))
                                         (and eq
                                              (cons (string-trim* (substring line 0 eq))
                                                    (unquote-value
                                                     (string-trim* (substring line (+ eq 1)
                                                                              (string-length line))))))))))
                               lines))))
    (values colours (if mode-cell (cdr mode-cell) "dark"))))

(define (colour-of colours key)
  (let ((cell (assoc key colours)))
    (and cell (cdr cell))))

(define (pick colours keys)
  (let loop ((rest keys))
    (cond ((null? rest) #f)
          ((colour-of colours (car rest)) => (lambda (v) v))
          (else (loop (cdr rest))))))

;;------------------------------------------------------------------
;; Colour arithmetic - only the diff slots need it
;;------------------------------------------------------------------

(define (hex-rgb colour)
  (let ((c (if (char=? (string-ref colour 0) #\#) (substring colour 1) colour)))
    (list (string->number (substring c 0 2) 16)
          (string->number (substring c 2 4) 16)
          (string->number (substring c 4 6) 16))))

(define (rgb-hex rgb)
  (string-append "#"
                 (apply string-append
                        (map (lambda (c)
                               (let ((n (min 255 (max 0 (round c)))))
                                 (if (< n 16)
                                     (string-append "0" (number->string n 16))
                                     (number->string n 16))))
                             rgb))))

(define (mix a b t)
  "T of the way from colour A to colour B."
  (rgb-hex (map (lambda (x y) (+ (* x (- 1 t)) (* y t)))
                (hex-rgb a) (hex-rgb b))))

;;------------------------------------------------------------------
;; The slot rules - see the header. Counts are how many of omarchy.el's
;; 22 themes take that key for that slot.
;;------------------------------------------------------------------

(define surfaces
  '((bg-main       "background")                            ; 19
    (bg-dim        "dark_background" "darker_background")   ; 4 + 7
    (bg-inactive   "darker_background" "dark_background")   ; 10
    (bg-alt        "lighter_background" "selection")        ; 10
    (bg-active     "selection" "muted")                     ; 12
    (border        "muted" "dark_foreground")               ; 13
    (fg-main       "bright_foreground" "foreground")        ; 11
    (fg-alt        "light_foreground" "bright_foreground")  ; 12
    (fg-dim        "dark_foreground" "muted")               ; 11
    (cursor        "bright_foreground" "foreground")))      ; 14

(define primary
  '((red             "red")
    (red-warmer      "orange" "red")
    (red-cooler      "red")
    (red-faint       "red")
    (red-intense     "bright_red" "red")
    (green           "green" "bright_green")
    (green-warmer    "green" "bright_green")
    (green-cooler    "cyan" "bright_cyan")                  ; 9
    (green-faint     "green")
    (green-intense   "bright_green" "green")                ; 10
    (yellow          "yellow" "bright_yellow")
    (yellow-warmer   "orange" "yellow")
    (yellow-cooler   "yellow")
    (yellow-faint    "yellow")
    (yellow-intense  "bright_yellow" "yellow")
    (blue            "blue" "bright_blue")
    (blue-warmer     "magenta" "bright_magenta")            ; 11
    (blue-cooler     "cyan" "bright_cyan")                  ; 10
    (blue-faint      "blue" "bright_blue")
    (blue-intense    "bright_blue" "blue")                  ; 7
    (magenta         "magenta" "bright_magenta")
    (magenta-warmer  "bright_magenta" "magenta")
    (magenta-cooler  "magenta" "bright_magenta")
    (magenta-faint   "magenta" "bright_magenta")
    (magenta-intense "bright_magenta" "magenta")
    (cyan            "cyan" "bright_cyan")
    (cyan-warmer     "bright_cyan" "cyan")
    (cyan-cooler     "blue" "bright_blue")                  ; 7
    (cyan-faint      "cyan" "bright_cyan")
    (cyan-intense    "bright_cyan" "cyan")))

;; Semantic slots `modus-themes-theme' reads - the same names the
;; hand-written themes' `*-palette-mappings-partial' use.
(define semantic
  '((keyword              "bright_magenta")   ; 8
    (builtin              "orange")
    (constant             "bright_yellow")    ; 9
    (number               "orange")           ; 5
    (fnname               "bright_blue")      ; 7
    (fnname-call          "bright_blue")
    (name                 "bright_blue")
    (type                 "bright_yellow")    ; 8
    (variable             "bright_foreground") ; 11
    (variable-use         "bright_foreground")
    (identifier           "bright_foreground") ; 10
    (property             "bright_cyan")      ; 7
    (property-use         "bright_cyan")
    (string               "bright_green")     ; 9
    (docstring            "bright_green")     ; 6
    (comment              "dark_foreground")  ; 6
    (preprocessor         "cyan")             ; tied 4/4/4
    (operator             "bright_foreground") ; 5
    (punctuation          "light_foreground") ; 8
    (rx-construct         "bright_magenta")   ; 8
    (rx-backslash         "bright_cyan")      ; tied 3/3/3/3
    (err                  "bright_red")       ; 14
    (warning              "bright_yellow")    ; 10
    (info                 "bright_blue")      ; 9
    (note                 "bright_cyan")      ; 7
    (success              "bright_green")     ; 7
    (bg-mode-line-active        "selection")          ; 7
    (fg-mode-line-active        "bright_foreground")  ; 12
    (border-mode-line-active    "border")
    (bg-mode-line-inactive      "background")         ; 5
    (fg-mode-line-inactive      "dark_foreground")    ; 11
    (border-mode-line-inactive  "dark_background")
    (modeline-err               "bright_red")         ; 9
    (modeline-warning           "bright_yellow")      ; 9
    (modeline-info              "blue")               ; 9
    (fg-line-number-inactive    "muted")              ; 10
    (fg-line-number-active      "accent")
    (bg-line-number-inactive    "background")         ; 19
    (bg-line-number-active      "lighter_background") ; 10
    (bg-region                  "selection")          ; 10
    (fg-region                  "bright_foreground")  ; 12
    (bg-hl-line                 "lighter_background") ; 8
    (bg-paren-match             "selection")          ; 12
    (fg-paren-match             "bright_blue")
    (bg-search-current          "yellow")             ; 6
    (bg-search-lazy             "selection")          ; 10
    (bg-completion              "lighter_background") ; 10
    (bg-hover                   "selection")          ; 12
    (bg-hover-secondary         "lighter_background") ; 9
    (link                       "blue")               ; 9
    (link-symbolic              "cyan")               ; 6
    (cursor                     "bright_foreground")  ; 8
    (prompt                     "bright_blue")        ; 7
    (fg-heading-0               "bright_cyan")
    (fg-heading-1               "bright_green")
    (fg-heading-2               "bright_yellow")
    (fg-heading-3               "bright_blue")
    (fg-heading-4               "magenta")
    (fg-heading-5               "bright_cyan")
    (fg-heading-6               "orange")
    (fg-heading-7               "bright_red")
    (fg-heading-8               "dark_foreground")))

;; The diff slots colors.toml has nothing to say about: (slot surface
;; accent strength) - blended from the theme's background toward the
;; colour that means added (green), removed (red), changed (yellow).
(define diff-blends
  '((bg-added            "background" "green"  0.16)
    (bg-added-faint      "background" "green"  0.10)
    (bg-added-refine     "background" "green"  0.24)
    (bg-added-intense    "background" "green"  0.34)
    (bg-removed          "background" "red"    0.16)
    (bg-removed-faint    "background" "red"    0.10)
    (bg-removed-refine   "background" "red"    0.24)
    (bg-removed-intense  "background" "red"    0.34)
    (bg-changed          "background" "yellow" 0.16)
    (bg-changed-faint    "background" "yellow" 0.10)
    (bg-changed-refine   "background" "yellow" 0.24)
    (bg-changed-intense  "background" "yellow" 0.34)))

(define diff-foregrounds
  '((fg-added           "bright_green" "green")
    (fg-added-intense   "bright_green" "green")
    (fg-removed         "bright_red"   "red")
    (fg-removed-intense "bright_red"   "red")
    (fg-changed         "bright_yellow" "yellow")
    (fg-changed-intense "bright_yellow" "yellow")))

;;------------------------------------------------------------------
;; The palette and mappings
;;------------------------------------------------------------------

(define (symbol-name-of key)
  "`bright_magenta' -> `bright-magenta', the symbol Modus sees."
  (list->string (map (lambda (c) (if (char=? c #\_) #\- c))
                     (string->list key))))

(define (build-palette colours)
  (let* ((named (map (lambda (cell)
                       (cons (symbol-name-of (car cell)) (cdr cell)))
                     colours))
         (surface-entries
          (filter (lambda (entry) entry)
                  (map (lambda (rule)
                         (let ((value (pick colours (cdr rule))))
                           (and value (cons (car rule) value))))
                       surfaces)))
         (primary-entries
          (filter (lambda (entry) entry)
                  (map (lambda (rule)
                         (let ((value (pick colours (cdr rule))))
                           (and value (cons (car rule) value))))
                       primary)))
         (blend-entries
          (filter (lambda (entry) entry)
                  (map (lambda (rule)
                         (let ((surface (colour-of colours (cadr rule)))
                               (accent (colour-of colours (caddr rule))))
                           (and surface accent
                                (cons (car rule)
                                      (mix surface accent (cadddr rule))))))
                       diff-blends)))
         (fg-entries
          (filter (lambda (entry) entry)
                  (map (lambda (rule)
                         (let ((value (or (colour-of colours (cadr rule))
                                          (colour-of colours (caddr rule)))))
                           (and value (cons (car rule) value))))
                       diff-foregrounds))))
    (append named surface-entries primary-entries blend-entries fg-entries)))

(define (build-mappings colours)
  (filter (lambda (entry) entry)
          (map (lambda (rule)
                 (let ((key (cadr rule)))
                   (and (colour-of colours key)
                        (cons (car rule) (symbol-name-of key)))))
               semantic)))

(define (render-pairs pairs value-writer)
  (fold (lambda (pair out)
          (string-append out
                         (format #f "    (~a ~a)~%" (car pair)
                                 (value-writer (cdr pair)))))
        "" pairs))

;;------------------------------------------------------------------
;; The temporary `-theme.el'
;;------------------------------------------------------------------

(define (theme-elisp name display mode partial mappings)
  (let* ((base (if (string=? mode "dark")
                   "modus-themes-vivendi-palette"
                   "modus-themes-operandi-palette"))
         (var (list->string (map (lambda (c)
                                   (if (char=? c #\-) #\_ c))
                                 (string->list name))))
         (quoted (lambda (v) (format #f "\"~a\"" v))))
    (format #f "\
;;; ~a-theme.el --- ~a, from Omarchy's colors.toml  -*- lexical-binding: t; -*-
;; Generated by schemacs' tools/convert-omarchy-colors.scm; do not edit.
;; The lexical-binding cookie is Emacs's: without it every load prints
;; the 'add one' notice on stderr, once per run.

;;; Code:

(require 'omarchy-themes)

(defconst ~a-palette-partial
  '(
~a    )
  \"Core, primary and diff slots derived from Omarchy's colors.toml.\")

(defconst ~a-palette-mappings-partial
  '(
~a    )
  \"Semantic slots derived from Omarchy's colors.toml.\")

(defconst ~a-palette
  (modus-themes-generate-palette
   ~a-palette-partial
   nil
   ~a
   ~a-palette-mappings-partial)
  \"Complete ~a palette for use with `modus-themes-theme'.\")

(defcustom ~a-palette-overrides nil
  \"User-level palette overrides for the ~a theme.\"
  :type '(repeat (list symbol (choice symbol string)))
  :group 'omarchy-themes)

(defvar ~a-custom-faces nil
  \"Additional face specs layered on top of the Modus-generated faces.\")

(defvar ~a-custom-variables nil
  \"Custom-variable specs layered on top of Modus defaults.\")

(modus-themes-theme
   '~a
   'omarchy-themes
   \"~a, derived from Omarchy's colors.toml.\"
   '~a
   '~a
   '~a-palette
   '~a-palette-overrides
   '~a-custom-faces
   '~a-custom-variables)

(provide '~a-theme)
;;; ~a-theme.el ends here
"
            name display
            var (render-pairs partial quoted)
            var (render-pairs mappings (lambda (v) v))
            var var base var display
            var display
            var
            var
            name display mode base
            var var var var
            name name)))

;;------------------------------------------------------------------
;; Running Emacs, and the Scheme-syntax dump
;;------------------------------------------------------------------

(define (shell-quote s)
  (string-append "'" (string-replace* s "'" "'\\''") "'"))

(define (string-replace* s from to)
  (let ((out (open-output-string)) (n (string-length s))
        (f (string-length from)))
    (let loop ((i 0))
      (cond ((>= i n) (get-output-string out))
            ((and (<= (+ i f) n) (string=? (substring s i (+ i f)) from))
             (display to out) (loop (+ i f)))
            (else (display (string-ref s i) out) (loop (+ i 1)))))))

(define dump-elisp
  ";;; -*- lexical-binding: t; -*-
;; Generated by tools/convert-omarchy-colors.scm.
(defun schemacs-dump (obj)
  \"Insert OBJ in a form Scheme's reader accepts: `#(' vectors, `nil' a symbol.\"
  (cond
   ;; `nil' is the empty list, exactly as the Python converter's Elisp
   ;; reader makes it; `render-spec' and `render-data' then differ only
   ;; in what they do with it (nil in an attribute value is `#f').
   ((null obj) (insert \"()\"))
   ((eq obj t) (insert \"t\"))
   ((symbolp obj) (insert (symbol-name obj)))
   ((stringp obj) (prin1 obj (current-buffer)))
   ((integerp obj) (insert (number-to-string obj)))
   ((floatp obj) (insert (number-to-string obj)))
   ((vectorp obj)
    (insert \"#(\")
    (dotimes (i (length obj))
      (when (> i 0) (insert \" \"))
      (schemacs-dump (aref obj i)))
    (insert \")\"))
   ((consp obj)
    (insert \"(\")
    (schemacs-dump (car obj))
    (let ((rest (cdr obj)))
      (while (consp rest)
        (insert \" \")
        (schemacs-dump (car rest))
        (setq rest (cdr rest)))
      (unless (null rest)
        (insert \" . \")
        (schemacs-dump rest)))
    (insert \")\"))
   ((characterp obj) (error \"character in theme dump: %S\" obj))
   (t (error \"unprintable object in theme dump: %S\" obj))))

(add-to-list 'load-path \"~a\")
(add-to-list 'load-path \"~a\")
(add-to-list 'custom-theme-load-path \"~a\")
(with-temp-file \"~a\"
  (dolist (file (directory-files \"~a\" nil \"-theme\\\\.el\\\\'\"))
    (let ((name (intern (substring file 0 (- (length file) 9)))))
      (condition-case err
          (progn
            (load-theme name t)
            (schemacs-dump (list name
                                 (get name 'theme-documentation)
                                 (get name 'theme-properties)
                                 (get name 'theme-settings)))
            (insert \"\\n\"))
        (error (message \"skip %s: %s\" name (error-message-string err)))))))
")

(define (find-modus-themes)
  (let ((candidates (list (or (getenv "EMACS_ETC_THEMES") "")
                          (expand-user "~/GITE/emacs/etc/themes")
                          "/usr/share/emacs/31.1/etc/themes")))
    (find (lambda (d) (and d (not (string=? d "")) (file-exists? d)))
          candidates)))

(define (expand-user path)
  (if (and (> (string-length path) 1)
           (char=? (string-ref path 0) #\~))
      (string-append (or (getenv "HOME") "")
                     (substring path 1 (string-length path)))
      path))

(define (run-emacs emacs root themes-dir dump-path)
  (let* ((modus (find-modus-themes))
         (script (string-append
                  "/tmp/schemacs-omarchy-colors-"
                  (number->string (getpid)) ".el")))
    (when (not modus)
      (error "no modus-themes.el found; set EMACS_ETC_THEMES"))
    (call-with-output-file script
      (lambda (port)
        (format port dump-elisp root modus themes-dir dump-path themes-dir)))
    (system (string-append (shell-quote emacs) " -Q --batch -l "
                           (shell-quote script)))
    (delete-file script)
    (unless (file-exists? dump-path)
      (error "Emacs produced no dump"))
    (let ((forms (call-with-input-file dump-path
                   (lambda (port)
                     (let loop ((out '()))
                       (let ((form (read port)))
                         (if (eof-object? form)
                             (reverse out)
                             (loop (cons form out)))))))))
      (delete-file dump-path)
      forms)))

;;------------------------------------------------------------------
;; Writing the tree's theme file
;;------------------------------------------------------------------

(define (scheme-string s)
  (let ((out (open-output-string)))
    (display "\"" out)
    (string-for-each
     (lambda (c)
       (cond ((char=? c #\\) (display "\\\\" out))
             ((char=? c #\") (display "\\\"" out))
             ((char=? c #\newline) (display "\\n" out))
             ((char=? c #\tab) (display "\\t" out))
             ((char=? c #\return) (display "\\r" out))
             (else (display c out))))
     s)
    (display "\"" out)
    (get-output-string out)))

(define (join-with strings separator)
  (let loop ((rest strings) (out ""))
    (cond ((null? rest) out)
          ((string=? out "") (loop (cdr rest) (car rest)))
          (else (loop (cdr rest)
                      (string-append out separator (car rest)))))))

(define (render-data v)
  "A value as Scheme *data* (as inside a quote)."
  (cond ((null? v) "()")
        ((symbol? v) (symbol->string v))
        ((string? v) (scheme-string v))
        ((boolean? v) (if v "#t" "#f"))
        ((number? v) (number->string v))
        ((char? v) (format #f "(integer->char ~a)" (char->integer v)))
        ((vector? v) (string-append "#("
                                    (join-with (map render-data
                                                    (vector->list v))
                                               " ")
                                    ")"))
        ((pair? v) (render-pair v render-data))
        (else (error "cannot emit" v))))

(define (render-spec v)
  "A face spec: nil in an attribute value is Emacs's false and is #f."
  (cond ((null? v) "#f")
        ((symbol? v) (symbol->string v))
        ((string? v) (scheme-string v))
        ((boolean? v) (if v "#t" "#f"))
        ((number? v) (number->string v))
        ((char? v) (format #f "(integer->char ~a)" (char->integer v)))
        ((vector? v) (string-append "#("
                                    (join-with (map render-spec
                                                    (vector->list v))
                                               " ")
                                    ")"))
        ((pair? v) (render-pair v render-spec))
        (else (error "cannot emit spec" v))))

(define (render-pair v writer)
  (let loop ((rest v) (parts '()))
    (cond ((null? rest) (string-append "(" (join-with (reverse parts) " ") ")"))
          ((pair? rest) (loop (cdr rest) (cons (writer (car rest)) parts)))
          (else (string-append "(" (join-with (reverse parts) " ")
                               " . " (writer rest) ")")))))

(define (render-spec-entry v)
  ;; One `(DISPLAY . ATTRS)' entry. A nil display matches every display
  ;; and is `()', not `#f' - which is the whole reason this is not just
  ;; `render-spec'.
  (if (and (pair? v) (null? (car v)))
      (string-append "(()"
                     (if (null? (cdr v))
                         ""
                         (string-append " "
                                        (join-with (map render-spec (cdr v)) " ")))
                     ")")
      (render-spec v)))

(define (emit-theme name dialogue header)
  (let ((doc (cadr dialogue))
        (props (caddr dialogue))
        (settings (cadddr dialogue)))
    (let ((faces '()) (variables '()))
      (for-each
       (lambda (s)
         (when (and (pair? s) (>= (length s) 4))
           (let ((prop (car s)) (symbol (cadr s)) (value (cadddr s)))
             (cond ((eq? prop 'theme-face) (set! faces (cons (cons symbol value) faces)))
                   ((eq? prop 'theme-value) (set! variables (cons (cons symbol value) variables)))))))
       settings)
      (let ((out (open-output-string)))
        (define (line s) (display s out) (newline out))
        (line header)
        (line "")
        (line "(import (schemacs editor theme))")
        (line "")
        (line (format #f "(define-theme ~a" name))
        (line (string-append "  " (scheme-string (or doc ""))))
        (if (null? props)
            (line "  ())")
            (let loop ((rest props) (parts '()))
              (cond ((or (null? rest) (null? (cdr rest)))
                     (line (string-append "  (" (join-with (reverse parts) " ") "))")))
                    (else (loop (cddr rest)
                                (cons (render-spec (cadr rest))
                                      (cons (symbol->string (car rest)) parts)))))))
        (line "")
        (line "(custom-theme-set-faces")
        (line (format #f " '~a" name))
        (for-each
         (lambda (entry)
           (let ((symbol (car entry)) (value (cdr entry)))
             (cond
              ((null? value)
               (line (format #f " '(~a ())" symbol)))
              ((pair? value)
               (line (format #f " '(~a (~a))" symbol
                             (join-with (map render-spec-entry value) " "))))
              (else
               (line (format #f " '(~a (~a))" symbol (render-spec value)))))))
         (reverse faces))
        (line ")")
        (line "")
        (when (pair? variables)
          (line "(custom-theme-set-variables")
          (line (format #f " '~a" name))
          (for-each
           (lambda (entry)
             (let* ((symbol (car entry)) (value (cdr entry))
                    (exp (cond ((vector? value) (render-data value))
                               ((and (pair? value) (eq? (car value) 'quote))
                                (string-append "'" (render-data (cadr value))))
                               ((pair? value)
                                (error "unquoted form as theme variable value" value))
                               (else (render-data value)))))
               (line (format #f " '(~a ~a)" symbol exp))))
           (reverse variables))
          (line ")"))
        (get-output-string out)))))

;;------------------------------------------------------------------
;; Command line
;;------------------------------------------------------------------

(define (usage)
  (format (current-error-port)
          "usage: convert-omarchy-colors.scm THEME [--out DIR] [--emacs PATH] [--themes-dir DIR]~%")
  (exit 2))

(define (main args)
  (let loop ((rest (cdr args))
             (theme #f) (out #f) (emacs "emacs")
             (themes-dir "/usr/share/omarchy/themes"))
    (cond
     ((null? rest)
      (unless theme (usage))
      (let* ((root (string-append "/tmp/schemacs-omarchy-colors-"
                                  (number->string (getpid))))
             (themes (string-append root "/themes"))
             (dump (string-append root "/dump"))
             (source (string-append themes-dir "/" theme "/colors.toml"))
             (outdir (or out
                         (string-append (or (getenv "SCHEMACS_ROOT") ".")
                                        "/schemacs/external/omarchy/themes"))))
        (unless (file-exists? source)
          (error "no such theme colors.toml" source))
        (unless (file-exists? root)
          (mkdir root))
        (unless (file-exists? themes)
          (mkdir themes))
        (let-values (((colours mode) (parse-colors source)))
          ;; **`display-name', not `display'.** The latter is the output
          ;; procedure, and a local binding of that name shadows it -
          ;; the same trap `warnings.scm''s `display-warning' fell into
          ;; with `message'.
          (let* ((display-name (slug->display theme))
                 (partial (build-palette colours))
                 (mappings (build-mappings colours)))
            (call-with-output-file (string-append themes "/" theme "-theme.el")
              (lambda (port)
                (display (theme-elisp theme display-name mode partial mappings)
                         port)))
            ;; `run_emacs' puts the themes' PARENT on the load path, where
            ;; `omarchy-themes.el' is; the checkout keeps it beside its
            ;; own themes/ directory.
            (copy-file (string-append (or (getenv "OMARCHY_EL")
                                          (expand-user "~/GITE/omarchy.el"))
                                      "/omarchy-themes.el")
                       (string-append root "/omarchy-themes.el"))
            (let ((forms (run-emacs emacs root themes dump)))
              (unless (file-exists? outdir)
                (system (string-append "mkdir -p " (shell-quote outdir))))
              (for-each
               (lambda (dialogue)
                 (let* ((name (car dialogue))
                        (header
                         (format #f "\
;;; ~a-theme.scm --- ~a, from Omarchy's colors.toml
;; Generated by tools/convert-omarchy-colors.scm from
;; ~a; do not edit by hand.
;;
;; A generic derivation, not a hand-tuned port: the slot rules are the
;; majority answer across omarchy.el's own themes, and the diff
;; backgrounds are blended from the theme's own colours."
                                 name display-name source))
                        (text (emit-theme name dialogue header))
                        (target (string-append outdir "/" (symbol->string name)
                                               "-theme.scm")))
                   (call-with-output-file target
                     (lambda (port) (display text port)))
                   (format #t "wrote ~a (~a bytes)~%" target (string-length text))))
               forms))))))

     ((string=? (car rest) "--out") (loop (cddr rest) theme (cadr rest) emacs themes-dir))
     ((string=? (car rest) "--emacs") (loop (cddr rest) theme out (cadr rest) themes-dir))
     ((string=? (car rest) "--themes-dir")
      (loop (cddr rest) theme out emacs (cadr rest)))
     ((and (> (string-length (car rest)) 1)
           (char=? #\- (string-ref (car rest) 0)))
      (usage))
     (else (loop (cdr rest) (car rest) out emacs themes-dir)))))

(define (slug->display slug)
  (let loop ((chars (string->list slug)) (out '()) (up? #t))
    (cond ((null? chars) (list->string (reverse out)))
          ((char=? (car chars) #\-) (loop (cdr chars) (cons #\space out) #t))
          (else (loop (cdr chars)
                      (cons (if up? (char-upcase (car chars)) (car chars)) out)
                      #f)))))

(main (command-line))
