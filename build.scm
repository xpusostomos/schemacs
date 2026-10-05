(define matcher-libs
  (cond-expand
    ((or chibi loko) '()) ;; use the built-in matcher, not the copy in this source repo
    (else '((chibi match)))
    )
  )

(define matcher-libdirs
  (cond-expand
    ((or chibi loko) '())
    (else '((chibi)))
    ))

(define library-directories
  `(()
    (slib)
    ,@matcher-libdirs
    (schemacs lens)
    (schemacs apps emacs)
    (schemacs elisp-eval)
    (schemacs)
    (schemacs editor)
    ))

(define library-list
  `((slib common)
    (slib filename)
    (slib directory)
    ,@matcher-libs
    (schemacs match)
    (schemacs bitwise)
    (schemacs string)
    (schemacs vector)
    (schemacs arrays)
    (schemacs comparator)
    (schemacs hash-table)
    (schemacs lens)
    (schemacs cursor)
    (schemacs lens vector)
    (schemacs pretty)
    (schemacs lens bin-hash-table)
    (schemacs lexer)
    (schemacs editor command)
    (schemacs editor data)
    (schemacs editor derived)
    (schemacs editor diredc)
    (schemacs editor dired)
    (schemacs editor fns)
    (schemacs editor timefns)
    (schemacs editor engine)
    (schemacs editor frame)
    (schemacs editor characters)
    (schemacs editor character)
    (schemacs editor env)
    (schemacs editor fileio)
    (schemacs editor disp-table)
    (schemacs editor mule)
    (schemacs editor files)
    (schemacs editor select)
    (schemacs editor syntax)
    (schemacs editor simple)
    (schemacs editor xdisp)
    (schemacs editor isearch)
    (schemacs editor window)
    (schemacs editor keymap)
    (schemacs editor keyboard)
    (schemacs editor minibuffer)
    (schemacs editor search)
    (schemacs editor indentc)
    (schemacs editor cmds)
    (schemacs editor replace)
    (schemacs editor buffer)
    (schemacs editor buffer-text)
    (schemacs editor region-cache)
    (schemacs editor font-core)
    (schemacs editor font-lock)
    (schemacs editor pages)
    (schemacs editor tabulated-list)
    (schemacs editor buff-menu)
    (schemacs map-ynp)
    (schemacs regexp-opt)
    (schemacs ui platform ncurses)
    (schemacs keymap)
    (schemacs bit-stack)
    (schemacs elisp-eval pretty)
    (schemacs elisp-eval parser)
    (schemacs elisp-eval environment)
    (schemacs elisp-eval format)
    (schemacs editor-impl)
    (schemacs elisp-eval)
    (schemacs elisp-load)
    ))

;;--------------------------------------------------------------------

(define path-separator
  (cond-expand
    ((or cp/m ms-dos msdos freedos os/2 os2
         windows ms-windows reactos react-os
         )
     "\\"
     )
    (else "/")
    ))

(define (library-id->path lib-id suffix)
  (apply
   string-append
   (cons
    "."
    (let loop ((elems lib-id))
      (cond
       ((null? elems) (list suffix))
       ((pair? elems)
        (let*((head (car elems))
              (head
               (cond
                ((integer? head) (number->string head))
                ((symbol? head) (symbol->string head))
                (else (error "not a symbol or integer" head 'in lib-id))
                )))
          (cons path-separator (cons head (loop (cdr elems))))
          )))
      ))))

(define (make-loader ldproc)
  (lambda (lib)
    (ldproc (library-id->path lib ".sld"))
    ))

(define (make-verbose-loader msg ldproc)
  (lambda (lib)
    (let ((file (library-id->path lib ".sld")))
      (display "; ") (write-string msg) (write-char #\space) (write file) (newline)
      (ldproc file)
      )))

;;--------------------------------------------------------------------

(cond-expand

  (mit

   (define loader (make-loader load))

   (for-each loader library-list)

   (disk-save "./schemacs-mitscheme.com")
   (newline)
   (display ";;; Now run the command `mit-scheme --band ./schemacs-mitscheme.com`")
   (newline)
   )

  (guile

   ;; Use the Guile REPL's "import" statement to do all the work.
   (import
     (scheme base)
     (scheme load)
     (scheme write)
     (schemacs elisp-eval)
     )
   )

  (gauche

   (define loader (make-loader load))

   (for-each loader library-list)

   )

  (gambit

   (for-each module-search-order-add!
             (map (lambda (lib) (library-id->path lib ".sld"))
                  library-directories
                  ))

   (define (loader lib)
     (let ((src (library-id->path lib ".sld"))
           (obj (library-id->path lib ""))
           )
       (display "; compile ") (write src) (newline)
       (compile-file src)
       (load obj)
       ))

   (for-each loader library-list)

   )

  (stklos

   (let*((old-lp
          (filter
           (lambda (p) (not (string=? p ".")))
           (load-path)
           ))
         (new-lp
          (let loop
              ((paths
                (map (lambda (lib) (library-id->path lib "/"))
                     library-directories
                     ))
               )
            (cond
             ((null? paths) old-lp)
             (else
              (let ((head (car paths)) (tail (cdr paths)))
                (if (member head old-lp)
                    (loop tail)
                    (cons head (loop tail))
                    )))))
          
          ))
     (display ";; set load-path to:") (newline)
     (for-each (lambda (path) (display "; ") (write path) (newline)) new-lp)
     (load-path new-lp)
     )

   (define (loader lib)
     (let ((src (library-id->path lib ".sld"))
           (obj (library-id->path lib ".ostk"))
           )
       (parameterize ((load-verbose #t))
         (display ";; Compile file ") (write src) (newline)
         (and
          (compile-file src obj)
          (load obj)
          #t)
         )))

   (for-each loader library-list)

   )

  (chibi

   (define (loader lib) (eval `(import ,lib)))

   (for-each loader library-list)

   )

  (chez

   (compile-imported-libraries #t)
   (generate-wpo-files #t)
   (compile-library "./.akku/lib/elisp-eval.sld")

   )

  (else
   (error "this Scheme implementation is not supported")
   ))
