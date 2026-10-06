
SCHEME_LIBRARIES := \
  ./chibi/match.sld \
  ./slib/common.sld \
  ./slib/filename.sld \
  ./slib/directory.sld \
  ./schemacs/bitwise.sld \
  ./schemacs/string.sld \
  ./schemacs/vector.sld \
  ./schemacs/arrays.sld \
  ./schemacs/comparator.sld \
  ./schemacs/hash-table.sld \
  ./schemacs/lens.sld \
  ./schemacs/cursor.sld \
  ./schemacs/lens/vector.sld \
  ./schemacs/pretty.sld \
  ./schemacs/lens/bin-hash-table.sld \
  ./schemacs/lexer.sld \
  ./schemacs/editor/command.sld \
  ./schemacs/editor/data.sld \
  ./schemacs/editor/derived.sld \
  ./schemacs/editor/diredc.sld \
  ./schemacs/editor/dired.sld \
  ./schemacs/editor/fns.sld \
  ./schemacs/editor/timefns.sld \
  ./schemacs/editor/engine.sld \
  ./schemacs/editor/frame.sld \
  ./schemacs/editor/env.sld \
  ./schemacs/editor/fileio.sld \
  ./schemacs/editor/disp-table.sld \
  ./schemacs/editor/mule.sld \
  ./schemacs/editor/mule-cmds.sld \
  ./schemacs/editor/files.sld \
  ./schemacs/editor/select.sld \
  ./schemacs/editor/syntax.sld \
  ./schemacs/editor/simple.sld \
  ./schemacs/editor/xdisp.sld \
  ./schemacs/editor/isearch.sld \
  ./schemacs/editor/window.sld \
  ./schemacs/editor/keymap.sld \
  ./schemacs/editor/keyboard.sld \
  ./schemacs/editor/minibuffer.sld \
  ./schemacs/editor/search.sld \
  ./schemacs/editor/indentc.sld \
  ./schemacs/editor/coding.sld \
  ./schemacs/editor/charset.sld \
  ./schemacs/editor/cmds.sld \
  ./schemacs/editor/easy-mmode.sld \
  ./schemacs/editor/replace.sld \
  ./schemacs/editor/buffer.sld \
  ./schemacs/editor/buffer-text.sld \
  ./schemacs/editor/region-cache.sld \
  ./schemacs/editor/font-core.sld \
  ./schemacs/editor/font-lock.sld \
  ./schemacs/editor/pages.sld \
  ./schemacs/editor/tabulated-list.sld \
  ./schemacs/editor/buff-menu.sld \
  ./schemacs/map-ynp.sld \
  ./schemacs/regexp-opt.sld \
  ./schemacs/ui/platform/ncurses.sld \
  ./schemacs/keymap.sld \
  ./schemacs/bit-stack.sld \
  ./schemacs/elisp-eval/pretty.sld \
  ./schemacs/elisp-eval/print.sld \
  ./schemacs/elisp-eval/parser.sld \
  ./schemacs/elisp-eval/environment.sld \
  ./schemacs/elisp-eval/format.sld \
  ./schemacs/editor-impl.sld \
  ./schemacs/elisp-eval.sld \
  ./schemacs/elisp-load.sld \


SEARCH_PATHS := . \
  ./chibi/ \
  ./slib/ \
  ./schemacs/lens/ \
  ./schemacs/editor/ \
  ./schemacs/elisp-eval/ \
  ./schemacs/ \


######################################################################
# building

.PHONY: all  schemacs-run-gauche  schemacs-run-chibi  gauche-repl  chibi-repl

all:
	@echo '###<--- BUILD PROFILE NOT SPECIFIED --->###'

schemacs-mitscheme.com: build.scm $(SCHEME_LIBRARIES)
	mit-scheme --eval '(let () (load "build.scm") (exit 0))';

schemacs-guile: $(SCHEME_LIBRARIES)
	guile --r7rs  --fresh-auto-compile \
	  -L $(PWD) \
	  -c '(let () (load "./build.scm") (exit 0))';


schemacs-gambit: $(SCHEME_LIBRARIES)
	gsc -:r7rs . $(SEARCH_PATHS) $(SCHEME_LIBRARIES)

schemacs-stklos: $(SCHEME_LIBRARIES)
	stklos -l "./build.scm";

schemacs-chicken: $(SCHEME_LIBRARIES)
	@eggsists() { chicken-status -c "$$1" | grep -lq -F "$$1"; }; \
	if ! ( eggsists r7rs && \
	       eggsists matchable && \
	       eggsists filepath \
	     ) \
	  then { \
	    echo "Warning: must install eggs: r7rs, matchable, filepath"; \
	    chicken-install -s r7rs matchable filepath; \
	  } fi;
	csc -X r7rs -R r7rs -R matchable -R filepath -sJ -I '$(PWD)' $(SCHEME_LIBRARIES)

schemacs-chez: $(SCHEME_LIBRARIES)
	akku install && \
	echo '(compile-file "./.akku/lib/schemacs/elisp-eval.sls")' | \
	  chezscheme \
	    --compile-imported-libraries \
	    --libdirs ./.akku/lib \

schemacs-run-gauche:
	gosh -r7 -I'$(PWD)' -e '(load "./elisp-tests.scm")'

schemacs-run-chibi:
	chibi-scheme -e '(load "./elisp-tests.scm")'

gauche-repl:
	gosh -r7 -I'$(PWD)'

chibi-repl:
	chibi-scheme

guile-repl:
	guile --r7rs -L '$(PWD)'

chez-repl:
	chezscheme --libdirs ./.akku/lib

######################################################################
# Cleaning

FIND_SKIP_GIT = -type d \( -name .git -o -name .akku \) -false -o

DEFAULT_FIND = find . $(FIND_SKIP_GIT)

.PHONY: clean  clean-gambit  cleam-mit  schemacs-guile  schemacs-gambit  clean-all-chez

clean: clean-mit clean-stklos clean-gambit


clean-stklos:
	find -type f -name '*.ostk' -print -delete;


clean-mit:
	$(DEFAULT_FIND) \
	  -type f \
	  \( -name '*.com' \
	  -o -name '*.bin' \
	  -o -name '*.bci' \
	  -o -name '*.comld' \
	  -o -name '*.binld' \
	  -o -name '*.bcild' \
	  \) \
		-print -delete;


clean-gambit:
	$(DEFAULT_FIND) \
	  -type f \
	  \( -name '*.o[0-9]' \
	  -o -name '*.o[0-9][0-9]' \
	  \) \
	  -print -delete;

clean-chez:
	find ./.akku \
	  -type d \
	  \( -name srfi \
	  -o -name scheme \
	  -o -name akku \
	  -o -name akku-r7rs \
	  -o -name laesare \
	  \) \
	  -prune -false -o \
	  -type f -name '*.so' \
	  -print -delete

clean-all-chez:
	find ./.akku -type f -name '*.so' -print -delete


clean-cache:
	rm -rf ~/.cache/guile/ccache/3.0-LE-8-4.7$(PWD)/
