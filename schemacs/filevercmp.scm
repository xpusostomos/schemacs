(define-library (schemacs filevercmp)
  ;; This library mirrors gnulib's `lib/filevercmp.c' - the version-aware
  ;; file-name comparison behind `string-version-lessp' (`fns.c:577'),
  ;; which `help--describe-map-compare' uses to sort event names "in the
  ;; natural way, with (for instance) \"<f2>\" coming between \"<f1>\" and
  ;; \"<f11>\"".
  ;;
  ;; The C has three layers, all ported: `file_prefixlen' (where the
  ;; version-carrying suffix starts), `order' (the byte ranking: digits
  ;; first, then letters, then everything else, with `~' sorting before
  ;; even the empty string), and `verrevcmp' (dpkg's version
  ;; comparison). Filenames are Scheme strings here, so the C's `*LEN ==
  ;; -1' "this is a NUL-terminated string" case is the only one; the
  ;; length-carrying array form has no counterpart.
  ;;
  ;; **Departures**: the C compares *bytes* (`UCHAR_MAX' in `order') and
  ;; classifies with `c-ctype.h', both of which are ASCII-only, where a
  ;; Scheme string is compared by code point and `char-alphabetic?' /
  ;; `char-numeric?' follow the Unicode tables. For the ASCII names this
  ;; is used on - key descriptions like `<f11>' - the two agree; for
  ;; non-ASCII characters the C ranks and classifies by encoded byte and
  ;; this ranks by code point with Unicode classes.

  (import (scheme base) (scheme char))

  (export %filevercmp)

  (begin

    (define (%file-prefixlen s)
      ;; `file_prefixlen' (`filevercmp.c:34'): "Return the length of a
      ;; prefix of S that corresponds to the suffix defined by this
      ;; extended regular expression in the C locale:
      ;;   (\.[A-Za-z~][A-Za-z0-9~]*)*$
      ;; Use the longest suffix matching this regular expression, except
      ;; do not use all of S as a suffix if S is nonempty."
      ;;
      ;; The C's `*len < 0 ? !s[i] : i == n' is the string case, `i ==
      ;; n'; its `*len = i' leaves LEN at the string's own length.
      ;;--------------------------------------------------------------
      (let ((n (string-length s)))
        (let loop ((i 0) (prefixlen 0))
          (if (= i n)
              prefixlen
              ;; "i++; prefixlen = i;"
              (let ((i (+ i 1)))
                (let ((prefixlen i))
                  ;; "while (i + 1 < n && s[i] == '.' && (c_isalpha
                  ;; (s[i + 1]) || s[i + 1] == '~'))"
                  (let skip ()
                    (when (and (< (+ i 1) n)
                               (char=? (string-ref s i) #\.)
                               (let ((c (string-ref s (+ i 1))))
                                 (or (char-alphabetic? c) (char=? c #\~))))
                      ;; "for (i += 2; i < n && (c_isalnum (s[i]) ||
                      ;; s[i] == '~'); i++)"
                      (set! i (+ i 2))
                      (let scan ()
                        (when (and (< i n)
                                   (let ((c (string-ref s i)))
                                     (or (char-numeric? c)
                                         (char-alphabetic? c)
                                         (char=? c #\~))))
                          (set! i (+ i 1))
                          (scan)))
                      (skip)))
                  (loop i prefixlen)))))))

    (define (%order s pos len)
      ;; `order' (`filevercmp.c:62'): "Return a version sort comparison
      ;; value for S's byte at position POS. S has length LEN. If POS ==
      ;; LEN, sort before all non-'~' bytes."
      ;;--------------------------------------------------------------
      (if (= pos len)
          -1
          (let ((c (char->integer (string-ref s pos))))
            (cond ((char-numeric? (string-ref s pos)) 0)
                  ((char-alphabetic? (string-ref s pos)) c)
                  ((char=? (string-ref s pos) #\~) -2)
                  ;; "return c + UCHAR_MAX + 1;"
                  (else (+ c 256))))))

    (define (%verrevcmp s1 s1-len s2 s2-len)
      ;; `verrevcmp' (`filevercmp.c:93'): "slightly modified verrevcmp
      ;; function from dpkg ... This implements the algorithm for
      ;; comparison of version strings specified by Debian." The C's
      ;; `return`s from inside its loops are the one-shot continuation.
      ;;--------------------------------------------------------------
      (call/cc
       (lambda (return)
         (let loop ((s1-pos 0) (s2-pos 0))
           (if (not (or (< s1-pos s1-len) (< s2-pos s2-len)))
               0
               (begin
                 (let ((first-diff 0))
                   ;; "while ((s1_pos < s1_len && !c_isdigit (s1[s1_pos]))
                   ;;        || (s2_pos < s2_len && !c_isdigit (s2[s2_pos])))"
                   (let nondig ()
                     (when (or (and (< s1-pos s1-len)
                                    (not (char-numeric? (string-ref s1 s1-pos))))
                               (and (< s2-pos s2-len)
                                    (not (char-numeric? (string-ref s2 s2-pos)))))
                       (let ((c1 (%order s1 s1-pos s1-len))
                             (c2 (%order s2 s2-pos s2-len)))
                         (if (not (= c1 c2))
                             (return (- c1 c2))
                             (begin
                               (set! s1-pos (+ s1-pos 1))
                               (set! s2-pos (+ s2-pos 1))
                               (nondig))))))
                   ;; "while (s1_pos < s1_len && s1[s1_pos] == '0') s1_pos++;"
                   (let z1 ()
                     (when (and (< s1-pos s1-len)
                                (char=? (string-ref s1 s1-pos) #\0))
                       (set! s1-pos (+ s1-pos 1))
                       (z1)))
                   (let z2 ()
                     (when (and (< s2-pos s2-len)
                                (char=? (string-ref s2 s2-pos) #\0))
                       (set! s2-pos (+ s2-pos 1))
                       (z2)))
                   ;; "while (s1_pos < s1_len && s2_pos < s2_len &&
                   ;; c_isdigit (s1[s1_pos]) && c_isdigit (s2[s2_pos]))"
                   (let digits ()
                     (when (and (< s1-pos s1-len) (< s2-pos s2-len)
                                (char-numeric? (string-ref s1 s1-pos))
                                (char-numeric? (string-ref s2 s2-pos)))
                       (when (= first-diff 0)
                         (set! first-diff
                               (- (char->integer (string-ref s1 s1-pos))
                                  (char->integer (string-ref s2 s2-pos)))))
                       (set! s1-pos (+ s1-pos 1))
                       (set! s2-pos (+ s2-pos 1))
                       (digits)))
                   (when (and (< s1-pos s1-len)
                              (char-numeric? (string-ref s1 s1-pos)))
                     (return 1))
                   (when (and (< s2-pos s2-len)
                              (char-numeric? (string-ref s2 s2-pos)))
                     (return -1))
                   (when (not (= first-diff 0))
                     (return first-diff)))
                 (loop s1-pos s2-pos)))))))

    (define (%filevercmp a b)
      ;; `filenvercmp' (`filevercmp.c:140'): "Compare versions A (of
      ;; length ALEN) and B (of length BLEN)." The C's `len < 0'
      ;; (NUL-terminated string) is the only case here.
      ;;--------------------------------------------------------------
      (let ((alen (string-length a)) (blen (string-length b)))
        ;; "Special case for empty versions."
        (cond ((= alen 0) (if (= blen 0) 0 -1))
              ((= blen 0) 1)
              (else
               (call/cc
                (lambda (return)
                  ;; "Special cases for leading '.' : '.' sorts first,
                  ;; then '..', then other names with leading '.', then
                  ;; other names."
                  (cond ((char=? (string-ref a 0) #\.)
                         (unless (char=? (string-ref b 0) #\.)
                           (return -1))
                         (let ((adot (= alen 1)) (bdot (= blen 1)))
                           (when adot (return (if bdot 0 -1)))
                           (when bdot (return 1)))
                         (let ((adotdot (and (= alen 2)
                                             (char=? (string-ref a 1) #\.)))
                               (bdotdot (and (= blen 2)
                                             (char=? (string-ref b 1) #\.))))
                           (when adotdot (return (if bdotdot 0 -1)))
                           (when bdotdot (return 1))))
                        ((char=? (string-ref b 0) #\.) (return 1)))
                  ;; "Cut file suffixes."
                  (let* ((aprefixlen (%file-prefixlen a))
                         (bprefixlen (%file-prefixlen b))
                         ;; "If both suffixes are empty, a second pass
                         ;; would return the same thing."
                         (one-pass? (and (= aprefixlen alen)
                                         (= bprefixlen blen)))
                         (result (%verrevcmp a aprefixlen b bprefixlen)))
                    ;; "Return the initial result if nonzero, or if no
                    ;; second pass is needed. Otherwise, restore the
                    ;; suffixes and try again."
                    (if (or (not (= result 0)) one-pass?)
                        result
                        (%verrevcmp a alen b blen)))))))))))
