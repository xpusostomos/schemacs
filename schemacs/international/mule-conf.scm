(define-library (schemacs international mule-conf)
  ;; GNU Emacs's `lisp/international/mule-conf.el', the two
  ;; password-prompt variables it defines. They live in this file in
  ;; Emacs - not in `simple.el' - and `comint.el''s default
  ;; `comint-password-prompt-regexp' is built from both.
  ;;
  ;; **Only these two are here.** The rest of `mule-conf.el' defines
  ;; the coding systems and charsets Emacs is built with
  ;; (`utf-8', `iso-2022-7bit', `latin-iso8859-*', ...). Those are in
  ;; `charset.scm''s generated registry and `coding.scm''s table here,
  ;; built from the same data in the same order (see `charset.scm''s
  ;; header) - so redefining them in this file would be a second copy.

  (import (scheme base)
          (only (schemacs custom) define-custom))

  (export *password-word-equivalents* *password-colon-equivalents*)

  (begin

    (define-custom *password-word-equivalents*
      '("password" "passcode" "passphrase" "pass phrase" "pin"
        "decryption key" "encryption key" ; From ccrypt.
        ;; These are sorted according to the GNU en_US locale.
        "암호"                   ; ko
        "パスワード"             ; ja
        "ପ୍ରବେଶ ସଙ୍କେତ"          ; or
        "ពាក្យសម្ងាត់"            ; km
        "adgangskode"            ; da
        "contraseña"             ; es
        "contrasenya"            ; ca
        "geslo"                  ; sl
        "hasło"                  ; pl
        "heslo"                  ; cs, sk
        "iphasiwedi"             ; zu
        "jelszó"                 ; hu
        "lösenord"               ; sv
        "lozinka"                ; hr, sr
        "mật khẩu"               ; vi
        "mot de passe"           ; fr
        "parola"                 ; tr
        "pasahitza"              ; eu
        "passord"                ; nb
        "passwort"               ; de
        "pasvorto"               ; eo
        "salasana"               ; fi
        "senha"                  ; pt
        "slaptažodis"            ; lt
        "wachtwoord"             ; nl
        "كلمة السر"              ; ar
        "ססמה"                   ; he
        "лозинка"                ; sr
        "пароль"                 ; kk, ru, uk
        "गुप्तशब्द"              ; mr
        "शब्दकूट"                ; hi
        "પાસવર્ડ"                ; gu
        "సంకేతపదము"              ; te
        "ਪਾਸਵਰਡ"                 ; pa
        "ಗುಪ್ತಪದ"                ; kn
        "கடவுச்சொல்"             ; ta
        "അടയാളവാക്ക്"            ; ml
        "গুপ্তশব্দ"               ; as
        "পাসওয়ার্ড"              ; bn_IN
        "රහස්පදය"                ; si
        "密码"                   ; zh_CN
        "密碼")                  ; zh_TW
      "List of words equivalent to \"password\".
This is used by Shell mode and other parts of Emacs to recognize
password prompts, including prompts in languages other than
English.  Different case choices should not be assumed to be
included; callers should bind `case-fold-search' to t."
      :type '(repeat string)
      :version "27.1"
      :group 'processes)

    (define-custom *password-colon-equivalents*
      ;; `(describe-char-fold-equivalences ?:)' - the last entry is
      ;; taken from history.
      (list #\: #\： #\﹕ #\︓ #\៖)
      "List of characters equivalent to trailing colon in \"password\" prompts."
      :type '(repeat character)
      :version "30.1"
      :group 'processes)))
