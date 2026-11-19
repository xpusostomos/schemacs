(define-library (schemacs editor jit-lock)
  ;; This library mirrors GNU Emacs's `lisp/jit-lock.el`: the just-in-time
  ;; fontification that `font-lock-mode` uses by default. Its whole point
  ;; is that a buffer change does *not* fontify anything - it marks the
  ;; changed text `fontified` nil - and the **redisplay** calls the
  ;; buffer's `fontification-functions` for text whose `fontified`
  ;; property is nil (`handle_fontified_prop`, `xdisp.c:4667', which
  ;; `(schemacs editor xdisp)` runs from the row builder).
  ;;
  ;; **What is here is the core**, everything a normal edit runs through:
  ;; `jit-lock-mode`, `jit-lock-register`/`-unregister`,
  ;; `jit-lock-refontify`, `jit-lock-function`, `jit-lock--run-functions`,
  ;; `jit-lock-fontify-now`, `jit-lock-force-redisplay` and
  ;; `jit-lock-after-change`.
  ;;
  ;; **Contextual fontification is carried**: after a change, an idle
  ;; timer (`jit-lock-context-time`) marks everything after the change
  ;; unfontified, so lines below whose syntactic context changed are
  ;; refontified when the redisplay reaches them. That is what the
  ;; `jit-lock-contextually` variable means, and the redisplay hook is
  ;; exactly why it is needed: a line already drawn keeps its
  ;; `fontified` property, and without the sweep it would keep its old
  ;; faces.
  ;;
  ;; **Not carried, each named where its variable is**: stealth
  ;; fontification (`jit-lock-stealth-*`, idle timers over every buffer),
  ;; deferred fontification (`jit-lock-defer-time`, nil by default), the
  ;; antiblink `post-command-hook` pair (which delays the context sweep
  ;; while an unterminated string was just opened) and the
  ;; `jit-lock-defer-multiline` branch of `jit-lock-context-fontify`
  ;; (deferred multiline fontification).
  ;;
  ;; **Four Emacs buffer-locals are entries in this tree's per-buffer
  ;; store** (`jit-lock-mode`, `jit-lock-functions`,
  ;; `jit-lock-contextually`, `jit-lock-context-unfontify-pos`), read the way
  ;; `font-lock-buffer-local` reads font-lock's, because Emacs's hook
  ;; machinery here is parameters and a parameter is not per buffer.
  ;; `fontification-functions` is the same shape and is `xdisp.c`'s
  ;; variable, so its accessors live in `(schemacs editor xdisp)`.
  ;;
  ;; `jit-lock-after-change` is on this tree's one global
  ;; `after-change-functions` list and is gated on the buffer's
  ;; `jit-lock-mode` - the same compromise
  ;; `font-lock-after-change-function` documents in its own file.

  (import
    (scheme base)
    (only (guile) delq)
    (only (schemacs editor buffer)
          buffer-local-value buffer-list current-buffer
          set-buffer-local-value! with-current-buffer)
    (only (schemacs editor insdel) *after-change-functions*)
    (only (schemacs editor subr)
          run-hook-with-args with-silent-modifications)
    (only (schemacs editor textprop)
          next-single-property-change put-text-property text-property-any)
    (only (schemacs editor editfns)
          point-max point-min save-excursion save-restriction widen)
    (only (schemacs editor marker) copy-marker marker-buffer marker-position)
    (only (schemacs editor timer) run-with-timer run-with-idle-timer cancel-timer)
    (only (schemacs editor xdisp)
          fontification-functions set!fontification-functions!)
    (only (schemacs editor custom) define-custom))

  (export
   jit-lock-mode-on?
   jit-lock-mode
   jit-lock-functions
   jit-lock-register
   jit-lock-unregister
   jit-lock-refontify
   jit-lock-function
   jit-lock-fontify-now
   jit-lock-force-redisplay
   jit-lock-after-change
   *jit-lock-start* *jit-lock-end*
   *jit-lock-after-change-extend-region-functions*
   *jit-lock-chunk-size*
   *jit-lock-contextually*
   *jit-lock-context-time*
   jit-lock-context-fontify
   jit-lock-contextually
   jit-lock-context-timer
   jit-lock-context-unfontify-pos
   *jit-lock-defer-time*)

  (begin

    ;;----------------------------------------------------------------
    ;; The variables (`jit-lock.el:37-180')
    ;;----------------------------------------------------------------
    (define-custom *jit-lock-chunk-size* 1500
      "Jit-lock fontifies chunks of at most this many characters at a time.
This variable controls both display-time and stealth fontification."
      :type 'integer
      :group 'jit-lock)

    (define-custom *jit-lock-contextually* 'syntax-driven
      "If non-nil, fontification should be syntactically true.
If nil, refontification occurs only on lines that were modified.  This
means where modification on a line causes syntactic change on subsequent lines,
those subsequent lines are not refontified to reflect their new context.
If t, fontification occurs on those lines modified and all subsequent lines.
This means those subsequent lines are refontified to reflect their new
syntactic context, after `jit-lock-context-time' seconds.
If any other value, e.g., `syntax-driven', it means refontification of
subsequent lines to reflect their new syntactic context may or may not
occur after `jit-lock-context-time', depending on the font-lock
definitions of the buffer.  Specifically, if `font-lock-keywords-only'
is nil in a buffer, which generally means the syntactic fontification
is done using the buffer mode's syntax table, the syntactic
refontification will be triggered (because in that case font-lock
calls `jit-lock-register' to set up for syntactic refontification,
and sets the buffer-local value of `jit-lock-contextually' to t).

The value of this variable is used when JIT Lock mode is turned on."
      :type 'symbol
      :group 'jit-lock)

    (define-custom *jit-lock-context-time* 0.5
      "Seconds to wait after last modification to fontify contextually."
      :type 'number
      :group 'jit-lock)

    (define-custom *jit-lock-defer-time* #f
      "If non-nil, defer fontification of changed text until this many seconds.
Not carried: nil is the default and is what the editor behaves as."
      :type '(choice (const :tag "None" nil) number)
      :group 'jit-lock)

    (define (jit-lock-mode-on?)
      ;; `jit-lock-mode` (`jit-lock.el:186`) - buffer-local, so an accessor
      ;; the way `font-lock-mode-on?` is one.
      ;;--------------------------------------------------------------
      (buffer-local-value (current-buffer) 'jit-lock-mode #f))
    (define (set!jit-lock-mode! value)
      (set-buffer-local-value! (current-buffer) 'jit-lock-mode value))

    (define (jit-lock-functions)
      ;; `jit-lock-functions` (`jit-lock.el:147') - "List of functions to
      ;; be called to fontify regions of text" - buffer-local.
      ;;--------------------------------------------------------------
      (buffer-local-value (current-buffer) 'jit-lock-functions '()))
    (define (set!jit-lock-functions! value)
      (set-buffer-local-value! (current-buffer) 'jit-lock-functions value))

    (define *jit-lock-start* (make-parameter #f))
    (define *jit-lock-end* (make-parameter #f))
    ;; ^ "Dynamically scoped variables" (`jit-lock.el:667'): the two the
    ;; `jit-lock-after-change-extend-region-functions` hook modifies - "The
    ;; extended region to refontify is returned indirectly by modifying the
    ;; variables". Parameters, because that is exactly a dynamic binding.

    (define *jit-lock-after-change-extend-region-functions* (make-parameter '()))
    ;; ^ `jit-lock-after-change-extend-region-functions`
    ;; (`jit-lock.el:668'): "Hook that can extend the text to refontify
    ;; after a change." A parameter because it is a hook.

    ;;----------------------------------------------------------------
    ;; Contextual fontification (`jit-lock.el:154-270', `:636-666')
    ;;----------------------------------------------------------------
    ;;
    ;; `jit-lock-context-unfontify-pos' is buffer-local; nil means
    ;; contextual fontification is off for that buffer. Everything
    ;; *after* that position is considered unfontified once the editor
    ;; has been idle for `jit-lock-context-time', and the next redisplay
    ;; of those lines refontifies them with the new syntactic context.

    (define jit-lock-context-timer #f)
    ;; ^ "Timer for context fontification in Just-in-time Lock mode."

    (define (jit-lock-contextually)
      ;; The buffer-local value, defaulting to the custom - Emacs's
      ;; `jit-lock-register' does `(setq-local jit-lock-contextually t)'
      ;; and the mode reads the buffer-local.
      ;;--------------------------------------------------------------
      (buffer-local-value (current-buffer) 'jit-lock-contextually
                          (*jit-lock-contextually*)))
    (define (set!jit-lock-contextually! value)
      (set-buffer-local-value! (current-buffer) 'jit-lock-contextually value))

    (define (jit-lock-context-unfontify-pos)
      (buffer-local-value (current-buffer)
                          'jit-lock-context-unfontify-pos #f))
    (define (set!jit-lock-context-unfontify-pos! value)
      (set-buffer-local-value! (current-buffer)
                               'jit-lock-context-unfontify-pos value))

    (define (jit-lock--any-buffer-on?)
      ;; Emacs's `(catch \'found (dolist (buf (buffer-list)) ...))'.
      ;;--------------------------------------------------------------
      (let loop ((buffers (buffer-list)))
        (and (pair? buffers)
             (or (with-current-buffer (car buffers) (jit-lock-mode-on?))
                 (loop (cdr buffers))))))

    (define (jit-lock-context--update)
      ;; `jit-lock-context--update' (`jit-lock.el:181'): the antiblink
      ;; grace timer is not carried, so this is the plain call.
      ;;--------------------------------------------------------------
      (jit-lock-context-fontify))

    (define (jit-lock-context-fontify)
      ;; GNU Emacs's `jit-lock-context-fontify' (`jit-lock.el:636'):
      ;; "Refresh fontification to take new context into account."
      ;;
      ;; The `jit-lock-defer-multiline' branch is not carried (deferred
      ;; fontification is not), so the position is not moved back and the
      ;; whole tail is marked unfontified.
      ;;--------------------------------------------------------------
      (let loop ((buffers (buffer-list)))
        (when (pair? buffers)
          (with-current-buffer (car buffers)
            (let ((pos (jit-lock-context-unfontify-pos)))
              (when pos
                (save-restriction
                  (widen)
                  (when (and (>= pos (point-min)) (< pos (point-max)))
                    (with-silent-modifications
                      (put-text-property pos (point-max) 'fontified #f))
                    (set!jit-lock-context-unfontify-pos! (point-max)))))))
          (loop (cdr buffers))))
      #f)

    ;;----------------------------------------------------------------
    ;; `jit-lock-mode' (`jit-lock.el:186')
    ;;----------------------------------------------------------------
    (define (jit-lock-mode arg)
      ;; "Toggle Just-in-time Lock mode. Turn Just-in-time Lock mode on
      ;; if and only if ARG is non-nil."
      ;;
      ;; The two branches this tree carries: turn on = mark the buffer for
      ;; refontification, arm the contextual idle timer when the buffer
      ;; asks for it, and install the two hooks; turn off = remove them
      ;; and cancel the timer when no buffer is left using it. The
      ;; indirect-buffer refusal, the stealth and deferred timers, and
      ;; the antiblink hook are not carried (see the header).
      ;;--------------------------------------------------------------
      (set!jit-lock-mode! arg)
      (if arg
          (begin
            ;; "Mark the buffer for refontification."
            (jit-lock-refontify)
            ;; "Initialize contextual fontification if requested."
            ;; (`jit-lock.el:258-265')
            (when (eq? (jit-lock-contextually) #t)
              (unless jit-lock-context-timer
                (set! jit-lock-context-timer
                      (run-with-idle-timer (*jit-lock-context-time*) #t
                                           jit-lock-context--update)))
              (unless (jit-lock-context-unfontify-pos)
                (set!jit-lock-context-unfontify-pos! (point-max))))
            ;; "Setup our hooks" (`:268-269'): the after-change one on the
            ;; tree's one list, the fontification one on the buffer's.
            (*after-change-functions*
             (cons jit-lock-after-change
                   (delq jit-lock-after-change (*after-change-functions*))))
            (unless (memq jit-lock-function (fontification-functions))
              (set!fontification-functions!
               (append (fontification-functions) (list jit-lock-function)))))
          (begin
            (*after-change-functions*
             (delq jit-lock-after-change (*after-change-functions*)))
            (set!fontification-functions!
             (delq jit-lock-function (fontification-functions)))
            ;; "Cancel our idle timers." - only if no other buffer is
            ;; using jit-lock, as the C's `catch \'found' walk says.
            (when (and jit-lock-context-timer
                       (not (jit-lock--any-buffer-on?)))
              (cancel-timer jit-lock-context-timer)
              (set! jit-lock-context-timer #f))))
      #t)

    ;;----------------------------------------------------------------
    ;; Registering a fontification function (`jit-lock.el:338')
    ;;----------------------------------------------------------------
    (define (jit-lock-register fun . rest)
      ;; "Register FUN as a fontification function to be called in this
      ;; buffer. FUN will be called with two arguments START and END
      ;; indicating the region that needs to be (re)fontified."
      ;;
      ;; "If non-nil, CONTEXTUAL means that a contextual fontification
      ;; would be useful": the buffer-local `jit-lock-contextually' is
      ;; set to t, which is what arms the context timer in
      ;; `jit-lock-mode' (`jit-lock.el:338-347').
      ;;--------------------------------------------------------------
      (unless (memq fun (jit-lock-functions))
        (set!jit-lock-functions! (cons fun (jit-lock-functions))))
      (when (and (pair? rest) (car rest) (jit-lock-contextually))
        (set!jit-lock-contextually! #t))
      (jit-lock-mode #t))

    (define (jit-lock-unregister fun)
      ;; "Unregister FUN as a fontification function."
      ;;--------------------------------------------------------------
      (set!jit-lock-functions! (delq fun (jit-lock-functions)))
      (when (or (null? (jit-lock-functions))
                (equal? (jit-lock-functions) '(t)))
        (jit-lock-mode #f)))

    (define (jit-lock-refontify . rest)
      ;; "Force refontification of the region BEG..END (default whole
      ;; buffer)." (`:358')
      ;;--------------------------------------------------------------
      (let ((beg (if (pair? rest) (car rest) #f))
            (end (if (and (pair? rest) (pair? (cdr rest))) (cadr rest) #f)))
        (with-silent-modifications
          (save-restriction
            (widen)
            (put-text-property (or beg (point-min)) (or end (point-max))
                               'fontified #f)))))

    ;;----------------------------------------------------------------
    ;; On-demand fontification (`jit-lock.el:368-508')
    ;;----------------------------------------------------------------
    (define (jit-lock-function start)
      ;; "Fontify current buffer starting at position START. This
      ;; function is added to `fontification-functions' when
      ;; `jit-lock-mode' is active."
      ;;
      ;; The deferral branch (`jit-lock-defer-time`) is not carried; its
      ;; default is nil.
      ;;--------------------------------------------------------------
      (when (jit-lock-mode-on?)
        (let* ((cend (min (point-max) (+ start (*jit-lock-chunk-size*))))
               (vend (or (next-single-property-change start 'invisible #f cend)
                         cend)))
          ;; "Presumably if we're called it means `start' is not at EOB
          ;; (nor invisible) and hence (> vend start)."
          (jit-lock-fontify-now start vend))))

    (define (jit-lock--run-functions beg end)
      ;; "Run the fontification functions" (`:394'): each is called with
      ;; BEG and END, and its answer - `(jit-lock-bounds BEG . END)' -
      ;; tightens or loosens the region actually fontified. Emacs uses
      ;; `run-hook-wrapped'; no function here returns non-nil, so the
      ;; walk is a `for-each`.
      ;;--------------------------------------------------------------
      (let ((tight-beg #f) (tight-end #f)
            (loose-beg beg) (loose-end end))
        (for-each
         (lambda (fun)
           (let* ((res (fun beg end))
                  (bounds (and (pair? res) (eq? (car res) 'jit-lock-bounds)))
                  (this-beg (if bounds (car (cdr res)) beg))
                  (this-end (if bounds (cdr (cdr res)) end)))
             (set! tight-beg (max (or tight-beg (point-min)) this-beg))
             (set! tight-end (min (or tight-end (point-max)) this-end))
             (set! loose-beg (min loose-beg this-beg))
             (set! loose-end (max loose-end this-end))))
         (jit-lock-functions))
        (list (min tight-beg beg) (max tight-end end) loose-beg loose-end)))

    (define (jit-lock-fontify-now . rest)
      ;; "Fontify current buffer from START to END. Defaults to the whole
      ;; buffer. END can be out of bounds." (`:418')
      ;;--------------------------------------------------------------
      (let ((start (if (pair? rest) (car rest) #f))
            (end (if (and (pair? rest) (pair? (cdr rest))) (cadr rest) #f)))
        (with-silent-modifications
          (save-excursion
            (unless start (set! start (point-min)))
            (set! end (if end (min end (point-max)) (point-max)))
            (let ((orig-start start))
              ;; "Fontify chunks beginning at START. The end of a chunk is
              ;; either END, or the start of a region before END that has
              ;; already been fontified."
              (let loop ()
                (when (and start (< start end))
                  (let ((next (or (text-property-any start end 'fontified #t)
                                  end)))
                    ;; "Avoid unnecessary work if the chunk is empty
                    ;; (bug#23278)."
                    (when (> next start)
                      ;; "Fontify the chunk, and mark it as fontified. We
                      ;; mark it first, to make sure that we don't
                      ;; indefinitely re-execute this fontification if an
                      ;; error occurs."
                      (put-text-property start next 'fontified #t)
                      (let* ((answer (jit-lock--run-functions start next))
                             (tight-beg (car answer))
                             (tight-end (cadr answer))
                             (loose-beg (car (cddr answer))))
                        ;; "In case we fontified more than requested, take
                        ;; advantage of the good news."
                        (when (or (< tight-beg start) (> tight-end next))
                          (put-text-property tight-beg tight-end 'fontified #t))
                        ;; "The redisplay engine has already rendered the
                        ;; buffer up-to ORIG-START ... so if LOOSE-BEG is
                        ;; before ORIG-START, we need to cause a new
                        ;; redisplay cycle after this one."
                        (when (< loose-beg orig-start)
                          (run-with-timer
                           0 #f (lambda ()
                                 (jit-lock-force-redisplay
                                  (copy-marker loose-beg)
                                  (copy-marker orig-start)))))
                        ;; "Skip to the end of the fully refontified part."
                        (set! start tight-end)))
                    ;; "Find the start of the next chunk, if any."
                    (set! start (text-property-any start end 'fontified #f))
                    (loop))))))))
      #t)

    (define (jit-lock-force-redisplay start end)
      ;; "Force the display engine to re-render START's buffer from START
      ;; to END. This applies to the buffer associated with marker START."
      ;;--------------------------------------------------------------
      (when (marker-buffer start)
        (with-current-buffer (marker-buffer start)
          (with-silent-modifications
            (let ((s (marker-position start))
                  (e (marker-position end)))
              (when (> e (point-max))
                (set! e (point-max))
                (set! s (min s e)))
              (when (< s (point-min))
                (set! s (point-min))
                (set! e (max s e)))
              ;; "Don't cause refontification (it's already been done),
              ;; but just do some random buffer change, so as to force
              ;; redisplay."
              (put-text-property s e 'fontified #f)
              (put-text-property s e 'fontified #t))))
        #t))

    ;;----------------------------------------------------------------
    ;; `jit-lock-after-change' (`jit-lock.el:680')
    ;;----------------------------------------------------------------
    (define (jit-lock-after-change start end old-len)
      ;; "Mark the rest of the buffer as not fontified after a change.
      ;; Installed on `after-change-functions'. START and END are the
      ;; start and end of the changed text. OLD-LEN is the pre-change
      ;; length."
      ;;
      ;; **This is the function that makes fontification lazy**: the
      ;; change marks `fontified` nil and does nothing else; the redisplay
      ;; fontifies what it shows.
      ;;--------------------------------------------------------------
      (when (jit-lock-mode-on?)
        (parameterize ((*jit-lock-start* start)
                       (*jit-lock-end* end))
          (with-silent-modifications
            (run-hook-with-args
             (*jit-lock-after-change-extend-region-functions*)
             start end old-len)
            ;; "Make sure we change at least one char (in case of
            ;; deletions)."
            (*jit-lock-end* (min (max (*jit-lock-end*) (+ 1 start))
                                 (point-max)))
            ;; "Request refontification."
            (save-restriction
              (widen)
              (put-text-property (*jit-lock-start*) (*jit-lock-end*)
                                 'fontified #f)))
          ;; "Mark the change for deferred contextual refontification."
          ;; (`jit-lock.el:701-708') - outside the `with-silent-
          ;; modifications', as the C has it, and the (possibly
          ;; extended) start of the change, since text between start and
          ;; end is usually refontified by being displayed, and text
          ;; after end only by the context sweep.
          (let ((context-pos (jit-lock-context-unfontify-pos)))
            (when context-pos
              (set!jit-lock-context-unfontify-pos!
               (min context-pos (*jit-lock-start*)))))))
      #t)

    ))
