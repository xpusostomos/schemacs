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

(let ((args (if (> (length (command-line)) 1)
                (cdr (command-line))
                (list))))
  (apply main-gtk args))
