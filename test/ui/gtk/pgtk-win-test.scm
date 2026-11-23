(import
 (scheme base)
 (scheme write)
 (only (srfi 64) test-assert test-equal test-begin test-end)
 (only (guile) setvbuf hash-ref)
 (only (schemacs ui gtk pgtk-win)
       x-gtk-map-stock *x-gtk-stock-map* *icon-map-list* x-gtk-stock-cache))

;; Regression tests for `(schemacs ui gtk pgtk-win)` - the stock-icon
;; map of `x-win.el`/`pgtk-win.el`.
;;
;; The expectations are Emacs 31.1's `x-gtk-stock-map` entries: the
;; tool bar's `new.xpm` stands for `("document-new" "gtk-new")` and the
;; Gtk backend tries each name against the icon theme in order. What the
;; map is *for* is the difference between real Emacs's themed tool bar
;; and a bar of the bundled Gtk2-era bitmaps.

(setvbuf (current-output-port) 'none)

(test-begin "schemacs_ui_gtk_pgtk_win")

(test-equal "new maps to the theme's document icon"
  '("document-new" "gtk-new")
  (x-gtk-map-stock "/usr/share/emacs/31.1/etc/images/new.xpm"))

(test-equal "a single-name entry"
  "gtk-directory"
  (x-gtk-map-stock "/home/x/emacs/etc/images/diropen.xpm"))

(test-equal "search maps to the theme's find icon"
  '("edit-find" "gtk-find")
  (x-gtk-map-stock "/opt/share/emacs/etc/images/search.xpm"))

(test-equal "the key is the last three components, whatever the prefix"
  '("edit-undo" "gtk-undo")
  (x-gtk-map-stock "/a/b/c/d/etc/images/undo.xpm"))

(test-equal "an n: entry is passed through as Emacs writes it"
  "n:bookmark_add"
  (x-gtk-map-stock "/x/etc/images/bookmark_add.xpm"))

(test-equal "an icon not in the map has no stock name"
  #f
  (x-gtk-map-stock "/x/etc/images/no-such-icon.xpm"))

(test-equal "a non-string file has no stock name"
  #f
  (x-gtk-map-stock #f))

(test-assert "a second lookup is served from the cache"
             (let ((again (x-gtk-map-stock
                           "/usr/share/emacs/31.1/etc/images/new.xpm")))
               (and (equal? again '("document-new" "gtk-new"))
                    (hash-ref x-gtk-stock-cache
                              "/usr/share/emacs/31.1/etc/images/new.xpm"))))

(test-equal "icon-map-list names the stock map by its starred name"
  (list '*x-gtk-stock-map*)
  (*icon-map-list*))

(test-assert "the stock map holds the icons tool-bar-setup names"
             (and (assoc "etc/images/save" (*x-gtk-stock-map*))
                  (assoc "etc/images/cut" (*x-gtk-stock-map*))
                  (assoc "etc/images/paste" (*x-gtk-stock-map*))))

(test-end "schemacs_ui_gtk_pgtk_win")
