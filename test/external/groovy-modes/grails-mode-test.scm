;; Tests for `(schemacs external groovy-modes grails-mode)', against the
;; upstream `grails-mode.el'. The displayable-name table and the
;; project-file listing were measured on Emacs 31.1 with the package's
;; own `grails-mode' on the same directory tree; `anything` is not
;; ported, so the show command is driven through its seam.
(import
 (scheme base)
 (scheme write)
 (scheme file)
 (only (guile) mkdir delete-file system)
 (only (srfi srfi-13) string-contains)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (schemacs buffer) generate-new-buffer current-buffer set-buffer
       set!buffer-default-directory buffer-local-value)
 (only (schemacs editfns) insert point point-min point-max
       buffer-substring-no-properties forward-line)
 (only (schemacs files) file-exists-p)
 (only (schemacs keymap) lookup-key)
 (only (schemacs character) kbd)
 (only (schemacs subr) *minor-mode-alist*)
 (schemacs external groovy-modes grails-mode))

(define %root "/tmp/grails-mode-test/")

(define (ensure-project)
  ;; The tree the measurements were taken on: a `build.gradle' at the
  ;; root and four files under `grails-app'.
  (unless (file-exists-p %root)
    (mkdir %root)
    (mkdir (string-append %root "grails-app"))
    (for-each
     (lambda (sub)
       (let ((dir (string-append %root sub)))
         (unless (file-exists-p dir) (mkdir dir))))
     '("grails-app" "grails-app/views" "grails-app/views/book"
       "grails-app/controllers" "grails-app/controllers/com"
       "grails-app/controllers/com/foo"
       "grails-app/domain" "grails-app/domain/com" "grails-app/domain/com/foo"
       "grails-app/conf"))
    (for-each
     (lambda (path)
       (call-with-output-file (string-append %root path) (lambda (p) #t)))
     '("build.gradle"
       "grails-app/views/book/list.gsp"
       "grails-app/controllers/com/foo/BookController.groovy"
       "grails-app/domain/com/foo/Book.groovy"
       "grails-app/conf/Config.groovy"))))

(test-begin "schemacs_external_grails_mode")

(test-equal "view(post): file"
  "view(book): list"
  (grails-make-displayable-name "/x/grails-app/views/book/list.gsp"))
(test-equal "controller - looked up in the directory, as upstream does"
  "controllers: BookController"
  (grails-make-displayable-name "/x/grails-app/controllers/com/foo/BookController.groovy"))
(test-equal "domain: file"
  "domain: Book"
  (grails-make-displayable-name "/x/grails-app/domain/com/foo/Book.groovy"))
(test-equal "configuration: file"
  "configuration: BuildConfig"
  (grails-make-displayable-name "/x/grails-app/conf/BuildConfig.groovy"))
(test-equal "i18n: file"
  "i18n: messages"
  (grails-make-displayable-name "/x/grails-app/i18n/messages.properties"))
(test-equal "services: file"
  "services: S"
  (grails-make-displayable-name "/x/grails-app/services/S.groovy"))
(test-equal "taglib: file"
  "taglib: T"
  (grails-make-displayable-name "/x/grails-app/taglib/T.groovy"))
(test-equal "utils: file"
  "utils: U"
  (grails-make-displayable-name "/x/grails-app/utils/U.groovy"))
(test-equal "an unknown grails-app subdirectory is its own type"
  "jobs: J"
  (grails-make-displayable-name "/x/grails-app/jobs/J.groovy"))
(test-equal "outside grails-app is a misc file"
  "misc file: Foo"
  (grails-make-displayable-name "/x/src/main/Foo.groovy"))

(test-equal "the extra find args are the pruned VCS directories"
  "\\( \\( -name .svn -or -name .git \\) -prune -or -true \\) "
  grails-root-extra-find-args)

;; The listing, against the fake project: the same four files, in
;; `find`'s order, each with its display name - measured on Emacs 31.1
;; with the same tree.
(ensure-project)
(let ((b (generate-new-buffer "*grails-test*")))
  (set-buffer b)
  (set!buffer-default-directory b %root)
  (let ((listing (parameterize ((*grails-anything-function*
                                 (lambda (sources) sources)))
                   (grails-show-project-files)
                   grails-project-files-list-display)))
    (test-equal "the project root is found by build.gradle"
      %root grails-project-root)
    (test-equal "the file list is every .groovy and .gsp under grails-app"
      '("configuration: Config" "domain: Book"
        "controllers: BookController" "view(book): list")
      (map car listing))
    (test-equal "each display name names its file"
      '("grails-app/conf/Config.groovy"
        "grails-app/domain/com/foo/Book.groovy"
        "grails-app/controllers/com/foo/BookController.groovy"
        "grails-app/views/book/list.gsp")
      (map (lambda (pair)
             (substring (cdr pair) (string-length %root)))
           listing))
    (test-assert "the anything function is handed the source alist"
      (let ((seen #f))
        (parameterize ((*grails-anything-function*
                        (lambda (sources) (set! seen sources) '())))
          (grails-show-project-files))
        (and (pair? seen)
             ;; `seen` is the list of sources; its first is the alist,
             ;; whose first entry is `(name . "Files in Grails Project")'.
             (let ((entry (car (car seen))))
               (and (eq? (car entry) 'name)
                    (equal? (cdr entry) "Files in Grails Project"))))))))

(test-assert "with no anything, the command says so by name"
  (let ((b (generate-new-buffer "*grails-test2*")))
    (set-buffer b)
    (set!buffer-default-directory b %root)
    (call/cc
     (lambda (escape)
       (with-exception-handler
        (lambda (e)
          (let ((msg (if (error-object? e) (error-object-message e) "")))
            (escape (and (string? msg)
                         (string-contains msg "anything is not ported")))))
        (lambda () (grails-show-project-files)))))))

(test-assert "grails-mode binds its keys"
  (begin
    (let ((b (generate-new-buffer "*grails-test3*")))
      (set-buffer b)
      (grails-mode 1)
      (and (eq? (lookup-key grails-mode-map (kbd "C-c / m")) grails-jump-to-model)
           (eq? (lookup-key grails-mode-map (kbd "C-c / c")) grails-jump-to-controller)
           (eq? (lookup-key grails-mode-map (kbd "C-c / v")) grails-jump-to-view)
           (eq? (lookup-key grails-mode-map (kbd "C-c a")) grails-show-project-files)))))

(test-assert "the mode line lighter is registered"
  (and (assq 'grails-mode (*minor-mode-alist*))
       (equal? " Grails" (cadr (assq 'grails-mode (*minor-mode-alist*))))))

(test-end "schemacs_external_grails_mode")
