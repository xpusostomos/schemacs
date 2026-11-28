;; Tests for `(schemacs find-cmd)' - `find-cmd.el', the sexp-to-find(1)
;; builder.  Every expectation here is GNU Emacs 31.1's own answer for
;; the same form, measured with `(find-to-string FORM)' and `(find-cmd
;; ...)' in a batch Emacs; `find-cmd''s own row compares the part after
;; the search path, because the path is the process's directory.
(import
 (scheme base)
 (scheme write)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (schemacs subr) shell-quote-argument error-message-string)
 (only (schemacs fileio) expand-file-name)
 (only (schemacs buffer) default-directory)
 (schemacs find-cmd))

(test-begin "schemacs_find_cmd")
(test-equal "the manual's example"
            "\\( \\( \\( -name .svn -or -name .git -or -name .CVS \\) -prune -or -true \\) -and \\( \\( \\( -name \\*.pl -or -name \\*.pm -or -name \\*.t \\) -or -mtime \\+1 \\) -and \\( -fstype nfs -or -fstype ufs \\) \\) \\) "
            (find-to-string
             '(and (prune (name ".svn" ".git" ".CVS"))
                   (and (or (name "*.pl" "*.pm" "*.t")
                            (mtime "+1"))
                        (fstype "nfs" "ufs")))))
(test-equal "exec has its terminating semicolons and is and-ed"
            "\\( -exec rm \\; -and -exec {} \\; -and -exec ; \\; \\) "
            (find-to-string '(exec "rm" "{}" ";")))
(test-equal "not ors its forms and prefixes -not"
            "-not \\( -mtime \\+1 -or -name something \\) "
            (find-to-string '(not (mtime "+1") (name "something"))))
(test-equal "an argument with a space is shell-quoted" "-name a\\ b "
            (find-to-string '(name "a b")))
(test-equal "and with one form is just that form" "-name x "
            (find-to-string '(and (name "x"))))
(test-equal "or with two forms" "\\( -name x -or -name y \\) "
            (find-to-string '(or (name "x") (name "y"))))
(test-equal "a switch takes no arguments" "-L "
            (find-to-string '(L)))
(test-equal "a non-action option" "-type f "
            (find-to-string '(type "f")))
(test-equal "a missing option"
            "-xtype f "
            (find-to-string '(xtype "f")))

;; `find-cmd' itself: the search path is `default-directory', expanded
;; and shell-quoted, then the forms.
(test-equal "find-cmd's command line"
            (string-append "find "
                           (shell-quote-argument
                            (expand-file-name (default-directory)))
                           " \\( -name x -or -name y \\) -name z ")
            (find-cmd '(or (name "x") (name "y")) '(name "z")))
(test-equal "find-cmd with one form passes it through find-to-string"
            (string-append "find "
                           (shell-quote-argument
                            (expand-file-name (default-directory)))
                           " -name x ")
            (find-cmd '(name "x")))

;; The two error paths.
(test-equal "an unknown option's message"
            "Sorry I don't know how to handle `nonsense'"
            (guard (e (#t (error-message-string e)))
              (find-to-string '(nonsense "x"))))
(test-equal "too few arguments for a generic option"
            "`fprintf' needs at least 2 arguments"
            (guard (e (#t (error-message-string e)))
              (find-to-string '(fprintf "x"))))
(test-end "schemacs_find_cmd")
