Schemacs assessment and TODOs
Recorded 2026-09-25 (analysis of code state as of commit 53c3ba6)


WHAT THE PROJECT IS
===================

Emacs clone + Elisp interpreter written in portable R7RS Scheme.
Three layers in different states of completion:

1. Elisp interpreter (schemacs/elisp-eval)  -- most mature.
   run-tests.scm: 123 pass / 5 fail. Main effort is here.
2. Editor logic (schemacs/apps/emacs.sld)   -- substantially written
   (buffers, windows, mode line, echo area, minibuffer, keymaps,
   commands) but cannot render.
3. GUI backend (schemacs/ui/platform/guile-gi-gtk3.sld) -- works at
   the widget level, but only the debugui app renders.


HOW TO RUN
==========

- GUI:       ./guile.sh   then   (load "./main-gui.scm")
             (What appears is (schemacs apps debugui), NOT the editor.)
- Tests:     guile --r7rs -L "$PWD" -c '(let () (load "./run-tests.scm"))'
- Deps:      guile 3 + guile-gi (module (gi)) must be on %load-path.
             guile.sh sets GTK_DEBUG=interactive, which pops up the
             GTK inspector window on every launch; comment out that
             export to suppress it.


FINDINGS
========

1. The window that opens is a debug/demo UI, not the editor.
   schemacs/ui/platform/guile-gi-gtk3.sld:53-54 has the real editor
   app commented out:

       ;;(prefix (schemacs apps emacs) ed:)
       (prefix (schemacs apps debugui) ed:)

2. The real editor app exists but crashes when rendered.
   Swapping the import above to (schemacs apps emacs) and running
   (main) gets far (frames, GtkTextBuffers, box packing all happen)
   then fails:

       gtk-draw-text-editor: Wrong type argument in position 1
       (expecting struct): #f

   Root cause: geometry/rect propagation. debugui hand-computes an
   explicit pixel rect for every widget and installs an 'on-resize:
   handler (schemacs/apps/debugui.sld:616-635). The emacs app's
   winframe-view (schemacs/apps/emacs.sld:819) builds a div tree with
   'expand / pack-elem hints and expects the layout engine to compute
   rects; the GTK backend drops rect to #f by the time it reaches
   gtk-draw-text-editor (guile-gi-gtk3.sld:895-898).

3. Ambiguity in the (schemacs ui) abstraction is the design hole.
   The (schemacs ui) header says rect-computing algorithms "need not
   be used, the sizes can be computed by the implementation-specific
   widget library." Two valid readings diverged:
   - debugui: app computes rects, backend just draws.
   - emacs app: backend should lay out from div hints.
   Fix direction: pick ONE owner for geometry -- either a pure
   layout pass in (schemacs ui) that produces rects for every div
   (most portable: lets terminals do the same), or a documented
   layout protocol every backend must implement.

4. The parameter-based platform layer is fragile.
   Platform calls are parameterized via ~30 *impl/...* make-parameter
   bindings (28 in schemacs/editor-impl.sld, 27 in
   schemacs/ui/text-buffer-impl.sld), installed by
   parameterized-gtk-api (guile-gi-gtk3.sld:1555). Forgetting the
   parameterize fails only at call time with an opaque error, e.g.
   "`new-buffer` not defined" (text-buffer-impl.sld:80). Also note:
   parameterized-gtk-api wraps only `main` and gtk3-event-handler --
   a bare gtk-draw-div call runs UNparameterized (this bit us while
   testing the emacs app directly).

5. Maturity ranking (headless > screen):
   - Elisp interpreter + keymap + editor engine (gap buffer + CDF,
     schemacs/editor/engine.sld): tested and solid.
   - Editor logic in emacs.sld: written but unreachable from GUI.
   - Div-tree -> widget layout integration: the missing link.

6. Scope/risk: three projects' worth of surface (portable GUI
   toolkit + Emacs clone + Elisp interpreter) driven by essentially
   one maintainer. Last 12 months (~112 commits) went to headless
   layers (GUI framework rewrite Oct 2025-Feb 2026, then editor
   engine + elisp builtins Mar-Sep 2026); the rendering front-end
   has been idle since Feb 2026.

7. Environment notes:
   - guile-gi is a niche dependency (installed from AUR here);
     g-golf path is an error stub, not implemented.


CONCRETE TODO IDEAS (if hacking on the GUI)
===========================================

a. Define one owner of layout geometry in (schemacs ui) and make
   the GTK backend conform (see finding 3). Smallest experiment:
   make gtk-draw-div's pack path assign concrete rects from
   size2D/expand hints and pass them down recursively, then flip
   guile-gi-gtk3.sld:53 to the emacs app and fix fallout.

b. Consider a fallback pure-Scheme layout mode in the backend for
   div trees without explicit rects, instead of crashing on #f.

c. Make the platform parameter errors actionable: raise a single
   recognizable error naming the missing parameterize context.

d. Bigger Elisp wins are elsewhere: issue #30 (ERT on cl-lib.el)
   is testable headlessly and needs no GUI.

e. README says `(load "./main-gui.scm")` works from any Guile; in
   fact ./guile.sh (guile --r7rs -L $PWD) is required. Also GTK_DEBUG
   'interactive' in guile.sh opens the inspector window on launch.