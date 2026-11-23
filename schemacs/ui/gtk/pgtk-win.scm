(define-library (schemacs ui gtk pgtk-win)
  ;; This library mirrors the Gtk window-system Lisp of GNU Emacs's
  ;; `lisp/term/pgtk-win.el' - the part of `lisp/term/x-win.el' that is
  ;; about tool bar icons: which GTK icon-theme name each of Emacs's
  ;; image files stands for.
  ;;
  ;; **Why it exists: Emacs's Gtk tool bar is themed, and its bundled
  ;; XPMs are only the fallback.** `update_frame_tool_bar`
  ;; (`gtkutil.c:5904`) calls `x_gtk_map_stock` on each image's file
  ;; name, `find_icon_from_name` asks `gtk_icon_theme_has_icon` for the
  ;; mapped names, and the button is made with
  ;; `gtk_image_new_from_icon_name` when one is found - so real Emacs
  ;; shows the desktop's own icons (Adwaita's `document-new`, and so
  ;; on), not the Gtk2-era bitmaps. The XPM is used only when the theme
  ;; has none of the mapped names.
  ;;
  ;; The map is transcribed from `x-win.el:1377` as Emacs 31.1 has it.
  ;; Named departures:
  ;;
  ;; * `icon-map-list` holds the alist itself where Emacs's default is
  ;;   the *symbol* `x-gtk-stock-map` (Elisp has one obarray to resolve
  ;;   it in; a Scheme variable is not a symbol with a value). A symbol
  ;;   element is still accepted, and the one name this tree can
  ;;   resolve is `x-gtk-stock-map`.
  ;; * The lookup is `assoc` with `equal?`, which is `assoc-string`'s
  ;;   answer for these plain string keys; this tree has no
  ;;   `assoc-string` and needs none for this.

  (import
    (scheme base)
    (only (guile) make-hash-table hash-ref hash-set!)
    (only (schemacs search) string-match match-string)
    (only (schemacs files) file-name-sans-extension)
    (only (schemacs custom) define-custom))

  (export x-gtk-map-stock
          *x-gtk-stock-map* *icon-map-list* x-gtk-stock-cache)

  (begin

    (define-custom *x-gtk-stock-map*
      '(
        ("etc/images/new" . ("document-new" "gtk-new"))
        ("etc/images/open" . ("document-open" "gtk-open"))
        ("etc/images/diropen" . "gtk-directory")
        ("etc/images/close" . ("window-close" "gtk-close"))
        ("etc/images/save" . ("document-save" "gtk-save"))
        ("etc/images/saveas" . ("document-save-as" "gtk-save-as"))
        ("etc/images/undo" . ("edit-undo" "gtk-undo"))
        ("etc/images/redo" . ("edit-redo" "gtk-redo"))
        ("etc/images/cut" . ("edit-cut" "gtk-cut"))
        ("etc/images/copy" . ("edit-copy" "gtk-copy"))
        ("etc/images/paste" . ("edit-paste" "gtk-paste"))
        ("etc/images/search" . ("edit-find" "gtk-find"))
        ("etc/images/print" . ("document-print" "gtk-print"))
        ("etc/images/preferences" . ("preferences-system" "gtk-preferences"))
        ("etc/images/help" . ("help-browser" "gtk-help"))
        ("etc/images/left-arrow" . ("go-previous" "gtk-go-back"))
        ("etc/images/right-arrow" . ("go-next" "gtk-go-forward"))
        ("etc/images/home" . ("go-home" "gtk-home"))
        ("etc/images/jump-to" . ("go-jump" "gtk-jump-to"))
        ("etc/images/index" . ("gtk-search" "gtk-index"))
        ("etc/images/exit" . ("application-exit" "gtk-quit"))
        ("etc/images/cancel" . "gtk-cancel")
        ("etc/images/info" . ("dialog-information" "gtk-info"))
        ("etc/images/bookmark_add" . "n:bookmark_add")
        ;; Used in package-menu
        ("images/package-menu/execute" . "gtk-apply")
        ("images/package-menu/info" . ("dialog-information" "gtk-info"))
        ("images/package-menu/install" . ("archive-insert" "list-add"))
        ("images/package-menu/delete" . ("archive-remove" "gtk-remove"))
        ("images/package-menu/unmark" . ("gnumeric-object-checkbox" "box"))
        ("images/package-menu/url" . "globe")
        ("images/package-menu/upgrade" . ("archive-extract" "go-bottom"))
        ;; Used in Gnus and/or MH-E:
        ("etc/images/attach" . ("mail-attachment" "gtk-attach"))
        ("etc/images/connect" . "gtk-connect")
        ("etc/images/contact" . "gtk-contact")
        ("etc/images/delete" . ("edit-delete" "gtk-delete"))
        ("etc/images/describe" . ("document-properties" "gtk-properties"))
        ("etc/images/disconnect" . "gtk-disconnect")
        ;; ("etc/images/exit" . "gtk-exit")
        ("etc/images/lock-broken" . "gtk-lock_broken")
        ("etc/images/lock-ok" . "gtk-lock_ok")
        ("etc/images/lock" . "gtk-lock")
        ("etc/images/next-page" . "gtk-next-page")
        ("etc/images/refresh" . ("view-refresh" "gtk-refresh"))
        ("etc/images/search-replace" . "edit-find-replace")
        ("etc/images/sort-ascending" . ("view-sort-ascending"
                                        "gtk-sort-ascending"))
        ("etc/images/sort-column-ascending" . "gtk-sort-column-ascending")
        ("etc/images/sort-criteria" . "gtk-sort-criteria")
        ("etc/images/sort-descending" . ("view-sort-descending"
                                         "gtk-sort-descending"))
        ("etc/images/sort-row-ascending" . "gtk-sort-row-ascending")
        ("etc/images/spell" . ("tools-check-spelling" "gtk-spell-check"))
        ("images/gnus/toggle-subscription" . "gtk-task-recurring")
        ("images/mail/compose" . ("mail-message-new" "gtk-mail-compose"))
        ("images/mail/copy" . "gtk-mail-copy")
        ("images/mail/forward" . "gtk-mail-forward")
        ("images/mail/inbox" . "gtk-inbox")
        ("images/mail/move" . "gtk-mail-move")
        ("images/mail/not-spam" . "gtk-not-spam")
        ("images/mail/outbox" . "gtk-outbox")
        ("images/mail/reply-all" . "gtk-mail-reply-to-all")
        ("images/mail/reply" . "gtk-mail-reply")
        ("images/mail/save-draft" . "gtk-mail-handling")
        ("images/mail/send" . ("mail-send" "gtk-mail-send"))
        ("images/mail/spam" . "gtk-spam")
        ;; Used for GDB Graphical Interface
        ("images/gud/break" . "gtk-no")
        ("images/gud/recstart" . ("media-record" "gtk-media-record"))
        ("images/gud/recstop" . ("media-playback-stop" "gtk-media-stop"))
        ;; No themed versions available:
        ;; mail/preview (combining stock_mail and stock_zoom)
        ;; mail/save    (combining stock_mail, stock_save and stock_convert)
        ("images/mpc/prev" . "media-skip-backward")
        ("images/mpc/rewind" . "media-seek-backward")
        ("images/mpc/pause" . "media-playback-pause")
        ("images/mpc/play" . "media-playback-start")
        ("images/mpc/ffwd" . "media-seek-forward")
        ("images/mpc/next" . "media-skip-forward")
        ("images/mpc/stop" . "media-playback-stop")
        ("images/mpc/add" . "list-add"))
      "How icons for tool bars are mapped to Gtk+ stock items.
Emacs must be compiled with the Gtk+ toolkit for this to have any effect.
A value that begins with n: denotes a named icon instead of a stock icon."
      :version "31.1"
      :type '(choice (repeat (choice symbol
                                     (cons (string :tag "Emacs icon")
                                           (choice (group (string :tag "Named")
                                                          (string :tag "Stock"))
                                                   (string :tag "Stock/named"))))))
      :group 'x)

    (define-custom *icon-map-list* '(*x-gtk-stock-map*)
      "A list of alists that map icon file names to stock/named icons.
The alists are searched in the order they appear.  The first match is used.
The keys in the alists are file names without extension and with two directory
components.  For example, to map /usr/share/emacs/22.1.1/etc/images/open.xpm
to stock item gtk-open, use:

  (\"etc/images/open\" . \"gtk-open\")

Themes also have named icons.  To map to one of those, use n: before the name:

  (\"etc/images/diropen\" . \"n:system-file-manager\")

The list elements are either the symbol name for the alist or the
alist itself.

If you don't want stock icons, set the variable to nil."
      :type '(repeat (choice symbol (repeat (cons (string :tag "Emacs icon")
                                                  (string :tag "Stock/named")))))
      :group 'x)

    (define x-gtk-stock-cache (make-hash-table))
    ;; ^ `x-gtk-stock-cache` (`x-win.el:1504`): "Cache for stock icon
    ;; lookups" - a file name to the mapped names, so a redisplay does
    ;; not walk the alist for every icon.

    (define (%icon-map-alist elem)
      ;; Emacs's `(if (symbolp elem) (symbol-value elem) elem)`: an
      ;; element of `icon-map-list` is an alist or the *name* of one.
      ;; There is one name this tree can resolve - see the header.
      ;;--------------------------------------------------------------
      (cond ((not (symbol? elem)) elem)
            ;; The variable's name here carries the asterisks the
            ;; parameter convention gives a defcustom, which is what the
            ;; default `icon-map-list` holds.
            ((eq? elem '*x-gtk-stock-map*) (*x-gtk-stock-map*))
            (else '())))

    (define (x-gtk-map-stock file)
      ;; GNU Emacs's `x-gtk-map-stock` (`x-win.el:1508`): "Map icon with
      ;; file name FILE to a Gtk+ stock name. This uses `icon-map-list`
      ;; to map icon file names to stock icon names."
      ;;
      ;; **The key is the last three path components without the
      ;; extension** - `etc/images/new` for any `.../etc/images/new.xpm`
      ;; - which is the C's `"/\\([^/]+/[^/]+/[^/]+$\\)"` match over the
      ;; path without its extension. The value is a single name or a
      ;; list of names, each tried in order by the caller.
      ;;--------------------------------------------------------------
      (and (string? file)
           (or (hash-ref x-gtk-stock-cache file)
               (let* ((file-sans (file-name-sans-extension file))
                      (key (let ((start (string-match
                                         ;; `string-match` takes an
                                         ;; Emacs regexp - the C's own
                                         ;; `"/\\([^/]+/[^/]+/[^/]+$\\)"`
                                         ;; - which this tree translates
                                         ;; to the engine's ERE itself.
                                         "/\\([^/]+/[^/]+/[^/]+$\\)"
                                         file-sans)))
                             (and start (match-string 1 file-sans))))
                      (value
                       (let loop ((maps (*icon-map-list*)) (value #f))
                         (cond
                          ((or value (null? maps)) value)
                          (else
                           (let ((hit (assoc (or key file-sans)
                                             (%icon-map-alist (car maps)))))
                             (loop (cdr maps) (and hit (cdr hit)))))))))
                 (hash-set! x-gtk-stock-cache file value)
                 value))))
))
