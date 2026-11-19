
Rough size, from the C:

Emacs: display_menu_bar (xdisp.c:27756)
lines: 155
what it is: draw the bar row: top-level items across the frame's first row, in the
  menu face, with menu-bar items from the keymap
────────────────────────────────────────
Emacs: tty_menu_show (term.c:4023)
lines: 273
what it is: build a tty_menu from the Lisp menu_items tree, call tty_menu_activate,
  map the answer back to t
────────────────────────────────────────
Emacs: tty_menu_activate (
lines: 258
what it is: the modal loop(arrows move between
  panes/items, RET/C-g, mouse), highlight the selection, show :help in the echo
  area
────────────────────────────────────────
Emacs: the helpers (calc_selection, locate,
  new_item_coords, …)
lines: ~180
what it is: geometry and the pane/item model

So about 900 lines of C, of which the modal loop and tty_menu_show are the real
work and the drawing helpenstcursor_to/write_glyphs/clear_end_of_line, which this tree already has.

What's already done here: the Lisp half — menu-bar.scm (the bar's keymap,
menu-bar-items, the File/E(parse_menu_item, themenu_items array, digest_single_submenu) and find-and-call-menu-selection. The GTK
front end consumes all of sume the same tree.

What's missing besides theace at all (I noted that in DEPARTURES when doing the GTK bar), and x-popup-menu isn't ported, so         tty_menu_show's caller doer also has to own one ofthe frame's rows, which touches the frame's row geometry (adjust_frame_size's menu-bar-lines on a tty).
