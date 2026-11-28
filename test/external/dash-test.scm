;; Tests for `(schemacs external dash)', the `->>' subset.  The
;; expectations are the installed dash's own answers for the same
;; forms, measured in a batch Emacs with dash on the load path.
(import
 (scheme base)
 (scheme write)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (schemacs external dash))

(test-begin "schemacs_external_dash")
(test-equal "a lone expression threads nowhere" 5 (->> 5))
(test-equal "one form takes the value as its last argument" 6
            (->> 5 (+ 1)))
(test-equal "two forms chain" 12
            (->> 5 (+ 1) (* 2)))
(test-equal "a non-list form is called with the value" -5
            (->> 5 -))
(test-equal "an empty form still receives the value" '(5)
            (->> 5 (list)))
(test-equal "argument order: the value is LAST" '(1 2 5)
            (->> 5 (list 1 2)))
(test-end "schemacs_external_dash")
