;; Schemacs GTK entry point. Mirrors `main-ncurses.scm` in style.
;;
;;     guile --r7rs -L . -s main-gtk.scm
;;     guile --r7rs -L . -s main-gtk.scm FILE
;;
;; `GUILE_WARN_DEPRECATED=no` quiets the guile-gi deprecation warnings
;; that would otherwise be printed over the first paint.
;;------------------------------------------------------------------
(setenv "GUILE_WARN_DEPRECATED" "no")

;; Only `main-gtk': `(schemacs editor pgtk)' publishes the whole GTK
;; surface into its own public interface, so importing it wholesale
;; would shadow core bindings here.
(import (only (schemacs ui platform gtk) main-gtk))
(import (only (schemacs repl) start-repl!))
(import (only (guile) getenv string->number))

;; A back door, off unless asked for. `SCHEMACS_REPL' names a port and the
;; editor opens Guile's cooperative REPL server on it, so a running editor
;; can be read and poked through `tools/repl.py' - see `schemacs/repl.sld'
;; for why it is the cooperative server and not `--listen', and `seg' for
;; how it is usually started. Set here rather than in the editor so that
;; nothing in the editor proper knows the back door exists.
(let ((port (getenv "SCHEMACS_REPL")))
  (when port
    (start-repl! (string->number port))))

(let ((args (if (> (length (command-line)) 1)
                (cdr (command-line))
                (list))))
  (apply main-gtk args))
