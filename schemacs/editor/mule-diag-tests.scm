;; Tests for `mule-diag.scm' - `describe-coding-system' and the two
;; printers under it.
;;
;; **Every expected string is Emacs 31.1's own**, measured with
;; `emacs -Q --batch' and a look at `*Help*':
;;
;;   (describe-coding-system 'utf-8-unix)
;;   (princ (with-current-buffer "*Help*" (buffer-string)))
;;
;; The one difference is the "encodes the following charsets" block,
;; which this tree's coding systems cannot answer (they carry no
;; `:charset-list'); it is named in the library header.
;;-------------------------------------------------------------
(import
 (scheme base)
 (only (guile) setvbuf string-contains)
 (only (oop goops) make)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (schemacs editor test-display) <test-display>)
 (only (schemacs editor dispnew) current-display)
 (only (schemacs editor frame) *current-frame* *default-frame-alist*
       new-frame)
 (only (schemacs editor buffer) *current-buffer* allocate-buffer
       with-current-buffer get-buffer-create)
 (only (schemacs editor editfns) insert buffer-string)
 (only (schemacs editor mule-diag)
       describe-coding-system describe-current-coding-system
       coding-system-type print-coding-system-briefly)
 (only (schemacs editor coding) find-coding-system))

(setvbuf (current-output-port) 'none)

(*default-frame-alist* (cons '(menu-bar-lines . 0) (*default-frame-alist*)))
(define disp (make <test-display> #:column-width 1 #:line-height 1))
(current-display disp)

(define (help-text thunk)
  (let* ((ed (allocate-buffer)))
    (with-current-buffer ed (insert "x\n"))
    (parameterize ((*current-frame* (new-frame ed 24 80))
                   (*current-buffer* ed))
      (thunk)
      (with-current-buffer (get-buffer-create "*Help*")
        (buffer-string)))))

(test-begin "schemacs_editor_mule_diag")

(test-equal "a fixed-eol coding system, as Emacs prints it"
  "= -- no-conversion (alias: binary)

Do no conversion.

When you visit a file with this coding, the file is read into a
unibyte buffer as is, thus each byte of a file is treated as a
character.
Type: raw-text (text with random binary characters)
EOL type: LF
"
  (help-text (lambda () (describe-coding-system 'no-conversion))))

(test-equal "and a UTF-8 variant with its aliases"
  "U -- utf-8-unix (alias: mule-utf-8-unix cp65001-unix)

UTF-8 (no signature (BOM))
Type: utf-8 (UTF-8: Emacs internal multibyte form)
EOL type: LF
"
  (help-text (lambda () (describe-coding-system 'utf-8-unix))))

(test-equal "a base with variants says automatic selection"
  "U -- utf-8 (alias: mule-utf-8 cp65001)

UTF-8 (no signature (BOM))
Type: utf-8 (UTF-8: Emacs internal multibyte form)
EOL type: Automatic selection from:
	[utf-8-unix utf-8-dos utf-8-mac]
"
  (help-text (lambda () (describe-coding-system 'utf-8))))

;; `coding-system-type`, the C's `:coding-type`, derived here from the
;; base name (the record does not carry the field). The expectations are
;; Emacs 31.1's - `no-conversion` is a *raw-text* type there, not a type
;; of its own.
(test-equal "the types are Emacs's"
  '(utf-8 charset raw-text raw-text utf-16 shift-jis big5 undecided)
  (map coding-system-type
       '(utf-8-unix iso-latin-1-unix no-conversion raw-text
         utf-16le-with-signature-unix japanese-shift-jis chinese-big5
         undecided)))

;; The buffer's own coding system: the labels are Emacs's
;; `describe-current-coding-system`'s, less its process and selection
;; blocks (named in the library header).
(let ((text (help-text (lambda () (describe-current-coding-system)))))
  (test-assert "describe-current-coding-system names the buffer's coding"
               (and (string-contains text
                                     "Coding system for saving this buffer:")
                    (string-contains text
                                     "Default coding system (for new files):")
                    (string-contains text
                                     "Coding system for keyboard input:")
                    (string-contains text
                                     "Coding system for terminal output:"))))

(test-end "schemacs_editor_mule_diag")
