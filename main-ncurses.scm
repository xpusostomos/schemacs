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

(import (schemacs ui platform ncurses))
(import (only (schemacs repl) start-repl!))
(import (only (guile) getenv string->number))

;; The development back door, the same one `main-gtk.scm' opens and for
;; the same reason - see `schemacs/repl.sld'. Here the command loop is the
;; only thing that can give the server a turn: a terminal's read blocks in
;; `getch', so this REPL answers between keys rather than while idle. It is
;; a no-op unless `SCHEMACS_REPL' names a port.
(let ((port (getenv "SCHEMACS_REPL")))
  (when port
    (start-repl! (string->number port))))

(let ((args (if (> (length (command-line)) 1)
                (cdr (command-line))
                (list))))
  (apply main-ncurses args))