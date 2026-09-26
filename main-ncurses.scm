;; Schemacs-ncurses entry point. Mirrors `main-gui.scm` in style.
;;
;; NOTE: `GUILE_WARN_DEPRECATED=no` suppresses the deprecation warning
;; the guile-ncurses bindings emit (a string passed as a record-type
;; name inside that library), which would otherwise garble the first
;; screen paint. Auto-compiled modules process imports before
;; top-level forms run, so also export the variable here for direct
;; invocation:
;;     GUILE_WARN_DEPRECATED=no guile --r7rs -L . -s main-ncurses.scm
;;------------------------------------------------------------------
(setenv "GUILE_WARN_DEPRECATED" "no")

(import (schemacs apps ncurses-editor))

(let ((args (if (> (length (command-line)) 1)
                (cdr (command-line))
                (list))))
  (apply main-ncurses args))