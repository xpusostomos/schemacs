;; Tests for `simple.el''s undo tail - `undo-more' and the change-group
;; primitives `atomic-change-group' is built on. The expectations are
;; `emacs -Q --batch''s on the same buffers:
;;
;;   (atomic-change-group (insert "X"))             -> "abcX"
;;   the same body with an error                   -> "abc"
;;   both, with undo disabled                      -> the text above,
;;                                                    buffer-undo-list t
;;   undo-more one group                           -> "abc", pending t

(import
 (scheme base)
 (only (srfi 64) test-equal test-begin test-end)
 (only (schemacs buffer) allocate-buffer set-buffer)
 (only (schemacs editfns) insert point-max buffer-substring-no-properties)
 (only (schemacs simple)
       undo-more atomic-change-group *pending-undo-list*)
 (only (schemacs undo)
       text-editor-undo-boundary! text-editor-undo-disable!
       text-editor-undo-list))

(test-begin "schemacs_simple_undo")

(define (fresh)
  (let ((b (allocate-buffer)))
    (set-buffer b)
    b))

(define (text)
  (buffer-substring-no-properties 1 (point-max)))

;;----------------------------------------------------------------------
;; undo-more
;;----------------------------------------------------------------------

(let ((b (fresh)))
  (insert "abc")
  (text-editor-undo-boundary! b)
  (insert "X")
  (test-equal "the buffer holds both edits" "abcX" (text))
  (parameterize ((*pending-undo-list* (text-editor-undo-list b)))
    (undo-more 1))
  (test-equal "undo-more undoes the most recent group" "abc" (text)))

(let ((b (fresh)))
  (insert "X")
  (parameterize ((*pending-undo-list* (text-editor-undo-list b)))
    (undo-more 1)
    (test-equal "at the end of the list pending-undo-list becomes t" #t
                (*pending-undo-list*)))
  (test-equal "and the change is undone" "" (text)))

;;----------------------------------------------------------------------
;; atomic-change-group
;;----------------------------------------------------------------------

(let ((b (fresh)))
  (insert "abc")
  (atomic-change-group (insert "X"))
  (test-equal "a successful group keeps its changes" "abcX" (text)))

(let ((b (fresh)))
  (insert "abc")
  (guard (e (else #f))
    (atomic-change-group
      (insert "X")
      (error "boom")))
  (test-equal "a group that errors has its changes undone" "abc" (text)))

(let ((b (fresh)))
  (insert "abc")
  (text-editor-undo-disable! b)
  (guard (e (else #f))
    (atomic-change-group
      (insert "X")
      (error "boom")))
  (test-equal "even with undo disabled, the changes are undone" "abc" (text))
  (test-equal "and undo stays disabled" #t
              (eq? (text-editor-undo-list b) #t)))

(let ((b (fresh)))
  (insert "abc")
  (text-editor-undo-disable! b)
  (atomic-change-group (insert "X"))
  (test-equal "an accepted group keeps its changes with undo disabled"
              "abcX" (text))
  (test-equal "and undo stays disabled" #t
              (eq? (text-editor-undo-list b) #t)))

(test-end "schemacs_simple_undo")
