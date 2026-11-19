;; Tests for the comment commands in `(schemacs editor newcomment)` -
;; `newcomment.el`'s `comment-region`, `uncomment-region`,
;; `comment-or-uncomment-region`, `comment-dwim`, `comment-box` and
;; `comment-kill`, plus the string helpers under them.
;;
;; **Every expectation is Emacs 31.1's own output** for the same text,
;; measured with `emacs -Q --batch` in a `fundamental-mode` buffer whose
;; `comment-start` is ";" (so the buffer is the same fixture on both
;; sides), `comment-end` "", `comment-start-skip` ";+ *" and
;; `comment-add` 1.
;;
;; The buffer-local variables are set the way a mode sets them -
;; `set-buffer-local-value!` - and `comment-normalize-vars` is called by
;; each command, as in the C.

(import
 (scheme base)
 (scheme write)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (guile) setvbuf)
 (only (schemacs editor buffer) allocate-buffer set-buffer-local-value!
       buffer-local-value)
 (only (schemacs editor frame) *current-frame* *current-buffer* new-frame)
 (only (schemacs editor editfns)
       buffer-substring goto-char insert point-max point-min)
 (only (schemacs editor scheme) scheme-mode)
 (only (schemacs editor command) call-interactively)
 (only (schemacs editor newcomment)
       *comment-padding* *comment-quote-nested* comment-add-count
       comment-box comment-dwim comment-kill comment-line
       comment-or-uncomment-region
       comment-padleft comment-padright comment-region comment-set-column
       comment-string-reverse comment-normalize-vars uncomment-region)
 (only (schemacs editor command) prefix-numeric-value))

(setvbuf (current-output-port) 'none)

(define (with-cmt text thunk)
  ;; A buffer with TEXT in it, the fixture's comment variables, and point
  ;; at the beginning - Emacs's `with-temp-buffer' plus the four
  ;; `setq-local's in the measurement above. The thunk's value is
  ;; answered.
  (let ((ed (allocate-buffer)))
    (parameterize ((*current-frame* (new-frame ed 24 80))
                   (*current-buffer* ed))
      (insert text)
      (set-buffer-local-value! ed 'comment-start ";")
      (set-buffer-local-value! ed 'comment-end "")
      (set-buffer-local-value! ed 'comment-start-skip ";+ *")
      (set-buffer-local-value! ed 'comment-add 1)
      (comment-normalize-vars)
      (goto-char (point-min))
      (thunk ed))))

(define (with-cmt-text text thunk)
  ;; `with-cmt` for the tests whose answer is the buffer's text.
  (with-cmt text (lambda (ed)
                   (thunk ed)
                   (buffer-substring (point-min) (point-max)))))

(define (region-of ed) (cons (point-min) (point-max)))

(test-begin "schemacs_editor_newcomment")

;;------------------------------------------------------------------
;; the string helpers
;;------------------------------------------------------------------
;;
;; Measured: `(comment-padright ";" 2)` is ";;; ", `(comment-padright
;; ";" 0)` "; ", `(comment-padleft ";" 2)` " ;;;", `(comment-string-
;; reverse "; ")` " ;", and with N = `re` the two answer the regexps
;; ";;+ ?" and "\\s-*;*;;".
(test-equal '(#t #t #t #t #t #t)
  (parameterize ((*comment-padding* " ")
                 (*comment-quote-nested* #t))
    (list (string=? (comment-padright ";" 2) ";;; ")
          (string=? (comment-padright ";" 0) "; ")
          (string=? (comment-padleft ";" 2) " ;;;")
          (string=? (comment-string-reverse "; ") " ;")
          (string=? (comment-padright ";;" 're) ";;+ ?")
          (string=? (comment-padleft ";;" 're) "\\s-*;*;;"))))

;; `comment-add' the function: with a one-char comment starter and no
;; ARG it answers the `comment-add' variable; with ARG it answers ARG-1.
(test-equal '(1 2)
  (with-cmt "" (lambda (ed)
                 (list (comment-add-count #f)
                       (comment-add-count 3)))))

;;------------------------------------------------------------------
;; the region commands
;;------------------------------------------------------------------
(test-equal "comment-region puts `;; ' on every line"
  ";; aaa\n;; bbb\n;; ccc\n"
  (with-cmt-text "aaa\nbbb\nccc\n"
            (lambda (ed)
              (comment-region (point-min) (point-max) #f))))

(test-equal "a numeric ARG is that many comment characters, minus one"
  ";; aaa\n"
  (with-cmt-text "aaa\n"
            (lambda (ed)
              (comment-region (point-min) (point-max) 2))))

(test-equal "uncomment-region takes the markers off"
  "aaa\nbbb\n"
  (with-cmt-text ";; aaa\n;; bbb\n"
            (lambda (ed)
              (uncomment-region (point-min) (point-max) #f))))

(test-equal "a numeric ARG removes that many comment characters"
  ";; aaa\n"
  (with-cmt-text ";;; aaa\n"
            (lambda (ed)
              (uncomment-region (point-min) (point-max) 1))))

(test-equal "comment-or-uncomment-region comments code and uncomments comments"
  '(";; aaa\n" "aaa\n")
  (list (with-cmt-text "aaa\n"
                       (lambda (ed)
                         (comment-or-uncomment-region (point-min) (point-max) #f)))
        (with-cmt-text ";; aaa\n"
                  (lambda (ed)
                    (comment-or-uncomment-region (point-min) (point-max) #f)))))

;; The box, whole: seven `;', a `;' and a space around each line, and
;; seven `;' at the bottom.
(test-equal "comment-box draws the box"
  ";;;;;;;\n; aaa ;\n; bbb ;\n;;;;;;;\n"
  (with-cmt-text "aaa\nbbb\n"
            (lambda (ed)
              (comment-box (point-min) (point-max) 0))))

;;------------------------------------------------------------------
;; the point commands
;;------------------------------------------------------------------
(test-equal "comment-dwim on a blank line inserts an empty comment"
  ";; \n"
  (with-cmt-text "   \n"
            (lambda (ed)
              (comment-dwim #f))))

(test-equal "comment-dwim after code moves to `comment-column'"
  "abc\t\t\t\t;\n"
  (with-cmt-text "abc\n"
            (lambda (ed)
              (goto-char 2)
              (comment-dwim #f))))

(test-equal "comment-kill removes the comment and the space before it"
  "abc\n"
  (with-cmt-text "abc ; hello\n"
                 (lambda (ed)
                   (comment-kill #f))))

;; `comment-set-column' with no ARG takes the current column. Measured
;; on Emacs 31.1: with point at the end of "  abc" the column becomes 5.
(test-equal 5
  (with-cmt "  abc"
            (lambda (ed)
              (goto-char 6)
              (comment-set-column #f)
              (buffer-local-value ed 'comment-column 32))))


;;------------------------------------------------------------------
;; a real mode: `comment-use-syntax` is t there
;;------------------------------------------------------------------
;;
;; **`comment-forward`'s syntax arm answers `forward-comment`'s value**,
;; not `(= n 0)`: in a mode whose syntax table knows comments (every
;; programming mode), `forward-comment` moves and returns non-nil, and
;; the C's `if` answers that. Answering `(= n 0)` there made
;; `comment-forward` nil for every such mode, and `uncomment-region`
;; then raised "Can't find the comment end" for a comment it could see -
;; `comment-line` on an already-commented line did nothing.
(test-equal '(";; hello\nworld\n" "hello\nworld\n")
  (let ((ed (allocate-buffer)))
    (parameterize ((*current-frame* (new-frame ed 24 80))
                   (*current-buffer* ed))
      (insert "hello\nworld\n")
      (scheme-mode)
      (goto-char (point-min))
      (call-interactively comment-line)
      (let ((commented (buffer-substring (point-min) (point-max))))
        (goto-char (point-min))
        (call-interactively comment-line)
        (list commented (buffer-substring (point-min) (point-max)))))))

(test-end "schemacs_editor_newcomment")
