(define-library (schemacs external omarchy omarchy-themes)
  ;; A port of omarchy.el's `omarchy-themes.el': the shared library the
  ;; bundled Modus-derived themes are written against. Its one job is
  ;; the `custom-theme-load-path` entry, so that `load-theme` finds the
  ;; themes/ directory shipped beside it.
  ;;
  ;; **`load-file-name` has no counterpart here.** Emacs's version does
  ;; `(expand-file-name "themes/" (file-name-directory load-file-name))`;
  ;; a library in this tree does not know its own file at run time, so
  ;; the directory is found along `%load-path` the way `startup.sld`
  ;; finds `splash.txt`: the first entry that has
  ;; `schemacs/external/omarchy/themes`.
  ;;
  ;; The themes themselves are in `themes/`, converted from the
  ;; package's by `tools/convert-omarchy-themes.py` - the generator,
  ;; `modus-themes-theme`, is not ported, only the settings it produced.

  (import (scheme base)
          (only (guile) %load-path getcwd)
          (only (schemacs editor fileio) file-directory-p expand-file-name)
          (only (schemacs editor subr) add-to-list)
          (only (schemacs editor theme) *custom-theme-load-path*))

  (export omarchy-themes--themes-directory)

  (begin

    (define (omarchy-themes--themes-directory)
      ;; The `themes/` directory beside this library, or #f when the tree
      ;; is not on the load path - the C's `(file-name-directory
      ;; load-file-name)` made a search.
      ;;
      ;; **Expanded against the process directory.** A load-path entry
      ;; may be relative (`-L .` puts one there), and `locate-file`
      ;; resolves a relative *directory* against `default-directory` -
      ;; the visited file's directory, not the tree's - so an
      ;; unexpanded entry finds the themes only from the right buffer.
      ;;--------------------------------------------------------------
      (let find ((rest %load-path))
        (cond ((null? rest) #f)
              (else
               (let ((dir (expand-file-name
                           "schemacs/external/omarchy/themes"
                           (expand-file-name (car rest) (getcwd)))))
                 (if (file-directory-p dir)
                     dir
                     (find (cdr rest))))))))

    ;; The `when load-file-name` / `add-to-list` at the foot of
    ;; `omarchy-themes.el`, run as this library loads.
    (let ((dir (omarchy-themes--themes-directory)))
      (when dir
        (add-to-list *custom-theme-load-path* dir)))))
