(define-library (schemacs external groovy-modes grails-mode)
  ;; A port of `grails-mode.el' from Groovy-Emacs-Modes
  ;; (https://github.com/Groovy-Emacs-Modes/groovy-emacs-modes) - the
  ;; minor mode with navigation commands for a Grails project.  It lives
  ;; under `schemacs/external' because it is not part of GNU Emacs.
  ;;
  ;; **Departures, each named where it is:**
  ;;
  ;;   * **`anything` is not ported**, so `grails-show-project-files'
  ;;     cannot show its list.  The call is a seam,
  ;;     `*grails-anything-function*`, whose default signals a message
  ;;     naming the missing library; everything the command does before
  ;;     the call - finding the project root and building the display
  ;;     list - runs, and that is what a test drives.
  ;;   * **`define-minor-mode` is given a real keymap** where upstream
  ;;     gives it the `(KEY . DEF)` alist that Emacs also accepts.  The
  ;;     tree's macro hands `:keymap` to `add-minor-mode`, and its
  ;;     keymaps are records, so the alist is built with `kbd` and
  ;;     `define-key` first (a named placement, like `groovy-electric`'s
  ;;     reordering).
  ;;   * `file-name-directory`/`file-name-nondirectory` are
  ;;     `file-name-directory-part`/`-nondirectory-part` here (the
  ;;     fileio library's names, `fileio.scm`'s header says why).
  ;;   * `setq` of `grails-project-root' and the two lists creates
  ;;     globals in Emacs; they are plain `define`s set with `set!`.
  ;;     `anything-grails-project-files` keeps Emacs's alist shape,
  ;;     including the symbol `anything-c-match-on-file-name` it names,
  ;;     which resolves to nothing here - `anything` would read it.
  (import
    (scheme base)
    (only (schemacs custom) define-custom)
    (only (schemacs buffer) current-buffer default-directory)
    (only (schemacs core easy-mmode) define-minor-mode)
    (only (schemacs command) define-command)
    (only (schemacs keymap) define-key make-sparse-keymap)
    (only (schemacs character) kbd)
    (only (schemacs fileio)
          file-name-directory-part file-name-nondirectory-part)
    (only (schemacs files) file-name-sans-extension locate-dominating-file)
    (only (schemacs find-cmd) find-to-string)
    (only (schemacs search) string-match match-string)
    (only (schemacs subr) split-string)
    (only (schemacs fns) concat mapcar)
    (only (schemacs simple) shell-command-to-string)
    (only (schemacs editfns) message))

  (export grails-jump-to-model grails-jump-to-controller grails-jump-to-view
          grails-root-extra-find-args
          grails-make-displayable-name grails-list-project-files
          grails-project-root grails-project-files-list
          grails-project-files-list-display
          anything-grails-project-files grails-show-project-files
          *grails-anything-function* grails-mode grails-mode-map)

  (begin

    (define-command (grails-jump-to-model)
      "Jump to the domain model for the given context."
      (interactive)
      (let ((var1 #f))
        (set! var1 'some)
        (message "jump to model at point"))
      #f)

    (define-command (grails-jump-to-controller)
      "thisandthat."
      (interactive)
      (let ((var1 #f))
        (set! var1 'some)
        (message "jump to controller at point"))
      #f)

    (define-command (grails-jump-to-view)
      "Jumps the view for the controller action we are in"
      (interactive)
      (let ((var1 #f))
        (set! var1 'some)
        (message "jump to view for given action"))
      #f)

    ;; `(defvar grails-root-extra-find-args ...)' - a plain variable,
    ;; not a defcustom, so it keeps `defvar`'s spelling: only a variable
    ;; in `cus-start.el' or a `defcustom` becomes a `define-custom` here.
    (define grails-root-extra-find-args
      ;; "Extra find args that will be AND'd to the defaults (which are
      ;; in `grails-root-file-find-process')"
      (find-to-string '(prune (name ".svn" ".git"))))

    (define (grails-make-displayable-name path)
      "makes path into a displayable name. eg view(post): file, domain: file, controller: name"
      (let ((dir (file-name-directory-part path))
            (name (file-name-nondirectory-part path)))
        (let ((type (cond
                     ((string-match "/grails-app/views/\\([a-zA-Z0-9_]+\\)/" dir)
                      (concat "view(" (match-string 1 dir) ")"))
                     ((string-match "/grails-app/controllers/.*/\\([a-zA-Z0-9_]+\\)Controller" dir) "controller")
                     ((string-match "/grails-app/domain/" dir) "domain")
                     ((string-match "/grails-app/conf/" dir) "configuration")
                     ((string-match "/grails-app/i18n/" dir) "i18n")
                     ((string-match "/grails-app/services/" dir) "services")
                     ((string-match "/grails-app/taglib/" dir) "taglib")
                     ((string-match "/grails-app/utils/" dir) "utils")
                     ((string-match "/grails-app/\\([a-zA-Z0-9_]+\\)/" dir) (match-string 1 dir))
                     (else "misc file"))))
          (concat type ": " (file-name-sans-extension name)))))

    ;; `setq` of variables Emacs never declared: plain globals here.
    (define grails-project-root #f)
    (define grails-project-files-list #f)
    (define grails-project-files-list-display #f)

    (define (grails-list-project-files)
      "Returns a list of all files found under the grails project."
      ;;
      ;; find root of project
      ;; TODO should also check for grails-app directory
      (set! grails-project-root
            (locate-dominating-file (default-directory) "build.gradle"))

      ;; get a list of all the relevant files
      (set! grails-project-files-list
            (split-string
             (shell-command-to-string (concat "find " grails-project-root "grails-app "
                                              (find-to-string
                                               '(or (name "*.groovy")
                                                    (name "*.gsp")))))))

      ;; convert the list into cons pair of (display . filepath) where
      ;; display is a friendly name
      (set! grails-project-files-list-display
            (mapcar
             (lambda (f)
               (cons (grails-make-displayable-name f) f))
             grails-project-files-list))
      grails-project-files-list-display)

    ;; anything source for showing all grails project files
    (define anything-grails-project-files
      '((name . "Files in Grails Project")
        (candidates . grails-project-files-list-display)
        (match anything-c-match-on-file-name)
        ;(candidate-transformer nil)
        (type . file)))

    ;; **The named gap.** `anything` is not ported; this seam is what
    ;; `grails-show-project-files` calls, and a caller (or a test) can
    ;; replace it with anything that takes a list of sources.
    (define *grails-anything-function*
      (make-parameter
       (lambda (sources)
         (error "anything is not ported, so grails-show-project-files cannot show ~a"
                sources))))

    (define-command (grails-show-project-files)
      "Uses Anything to show all the project files"
      (interactive)
      (grails-list-project-files)
      ((*grails-anything-function*) (list anything-grails-project-files))
      #f)

    ;; Emacs's `:keymap` here is the `(KEY . DEF)` alist
    ;; `define-minor-mode` also accepts; the tree's macro takes a keymap
    ;; value, so the alist is built into one.  The keys are the same
    ;; three-event `C-c / m` sequences `"\C-c/m"` names.
    (define grails-mode-map (make-sparse-keymap))
    (define-key grails-mode-map (kbd "C-c / m") grails-jump-to-model)
    (define-key grails-mode-map (kbd "C-c / c") grails-jump-to-controller)
    (define-key grails-mode-map (kbd "C-c / v") grails-jump-to-view)
    (define-key grails-mode-map (kbd "C-c a") grails-show-project-files)

    (define-minor-mode grails-mode
      "Grails Minor Mode.
     With no argument, this command toggles the mode.
     Non-null prefix argument turns on the mode.
     Null prefix argument turns off the mode.

     When Grails mode is enabled, several keys are enabled that
     will allow navigation around a typical grails project."
      :init-value #f
      :lighter " Grails"
      :keymap grails-mode-map)

    ))
