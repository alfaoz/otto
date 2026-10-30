#!/bin/bash
# end to end against the fake site, in a throwaway Chrome for Testing (your own Chrome is untouched):
#   1. TESTSITE_TLS=cert.pem:key.pem python3 testsite/server.py
#      (http on :8765; with any self-signed cert, https on :8766 for the "payment provider" frames)
#   2. OTTO_DEV_BROWSER=<Chrome for Testing dir> python3 tests/fake_app.py <otto binary> <scratch dir>
#      (a throwaway service that approves everything but entries named *deny*; OTTO_DEV_BROWSER lets that
#      unsigned browser talk to otto, never set it otherwise)
#   3. otto install-browser --dir <profile>, then start Chrome for Testing with OTTO_HOME=<scratch dir> and
#      --headless=new --user-data-dir=<profile> --load-extension=$PWD/extension --remote-debugging-port=9333
#      --host-resolver-rules="MAP evil.test 127.0.0.1, MAP js.stripe.com 127.0.0.1" --ignore-certificate-errors
#   4. OTTO_HOME=<scratch dir> tests/e2e.sh
set -u
here="$(cd "$(dirname "$0")" && pwd)"
C() { node "$here/cdp.mjs" 9333 "$@"; }
site=http://127.0.0.1:8765
pass=0; fail=0
check() { if eval "$2"; then echo "  ok   $1"; pass=$((pass+1)); else echo "  FAIL $1"; fail=$((fail+1)); fi; }

curl -s "$site/reset" >/dev/null
otto status >/dev/null || { echo "otto isn't running"; exit 1; }
# create the test entry once; saving over an existing secret asks the user for Touch ID
if ! otto ls testsite | grep -q '^testsite '; then
  printf '%s' "$(cat "$here/../testsite/.password")" | otto save testsite password --site 127.0.0.1 >/dev/null
  printf 'demo' | otto save testsite username >/dev/null
fi

echo "1. turn on 2FA: the site shows a QR, otto reads it from the tab"
C list | grep -q "$site" || C open "$site/setup" >/dev/null
C goto 127.0.0.1:8765 "$site/setup" >/dev/null; sleep 1.5
code=$(otto enroll testsite --from browser 2>/dev/null)
check "enroll returned a code ($code)" '[[ "$code" =~ ^[0-9]{6}$ ]]'
C eval 127.0.0.1:8765/setup "(()=>{document.querySelector('input[name=code]').value='$code';document.querySelector('form').submit();return 1})()" >/dev/null; sleep 1
check "site accepted the code, 2FA on" 'C text 127.0.0.1:8765 | grep -q "2FA turned on"'

echo "2. log in: password, then 2FA code"
C goto 127.0.0.1:8765 "$site/" >/dev/null; sleep 1
otto fill testsite --submit >/dev/null; sleep 1
check "password accepted, now on the 2FA page" '[ "$(C eval 127.0.0.1:8765 location.pathname)" = "\"/2fa\"" ]'
otto fill-code testsite --submit >/dev/null; sleep 1
check "signed in" 'C text 127.0.0.1:8765 | grep -q "signed in as demo"'

echo "3. six separate code boxes"
C goto 127.0.0.1:8765 "$site/logout" >/dev/null; sleep 1
otto fill testsite --submit >/dev/null; sleep 1
C goto 127.0.0.1:8765 "$site/2fa?boxes=1" >/dev/null; sleep 1
otto fill-code testsite --submit >/dev/null; sleep 1
check "signed in through split boxes" 'C text 127.0.0.1:8765 | grep -q "signed in as demo"'

echo "4. refuses other sites (localhost and 127.0.0.1 count as the same site)"
C goto 127.0.0.1:8765 "https://example.com/" >/dev/null; sleep 2
out=$(otto fill testsite 2>&1); rc=$?
check "no fill when only example.com is open ($out)" '[ $rc -ne 0 ]'

pw="$(cat "$here/../testsite/.password")"
C goto example.com "$site/logout" >/dev/null; sleep 1
out=$(otto fill-code testsite 2>&1); rc=$?
check "no 2FA code typed into a login form's username box ($out)" '[ $rc -ne 0 ] && [ "$(C eval 127.0.0.1:8765 "document.querySelector(\"[name=username]\").value")" = "\"\"" ]'

echo "5. a login form inside a web component (shadow DOM)"
C goto 127.0.0.1:8765 "$site/shadow" >/dev/null; sleep 1
otto fill testsite --submit >/dev/null; sleep 1
check "signed in through the web component" '[ "$(C eval 127.0.0.1:8765 location.pathname)" = "\"/2fa\"" ]'

echo "6. a login form inside a frame"
C goto 127.0.0.1:8765 "$site/framed" >/dev/null; sleep 1.5
otto fill testsite >/dev/null
check "filled inside the frame" '[ "$(C eval 127.0.0.1:8765 "window.seen.u === \"demo\" && window.seen.p === $(printf %s "$pw" | node -e "process.stdout.write(JSON.stringify(require(\"fs\").readFileSync(0,\"utf8\")))")")" = true ]'
check "the page's own search box was left alone" '[ "$(C eval 127.0.0.1:8765 "document.querySelector(\"input\").value")" = "\"\"" ]'

echo "7. a frame from another site is never filled"
C goto 127.0.0.1:8765 "$site/framed-elsewhere" >/dev/null; sleep 1.5
out=$(otto fill testsite 2>&1); rc=$?
check "refused ($out)" '[ $rc -ne 0 ]'
check "nothing reached the other site's frame" '[ "$(C eval 127.0.0.1:8765 "JSON.stringify(window.seen)")" = "\"{}\"" ]'

echo "8. the login moved to another domain: the user allows it once, in writing"
printf 'demo' | otto save moved username --site old-name.example >/dev/null
printf '%s' "$pw" | otto save moved password >/dev/null
C goto 127.0.0.1:8765 "$site/logout" >/dev/null; sleep 1
out=$(otto fill moved 2>&1); rc=$?
check "plain fill refuses and points to fill_on_site" '[ $rc -ne 0 ] && echo "$out" | grep -q fill_on_site'
out=$(otto fill moved --site 127.0.0.1 2>&1); rc=$?
check "a new domain needs a reason" '[ $rc -ne 0 ] && echo "$out" | grep -q reason'
otto fill moved --site 127.0.0.1 --reason "testsite moved to this machine" --submit >/dev/null; sleep 1
check "allowed, filled and signed in" '[ "$(C eval 127.0.0.1:8765 location.pathname)" = "\"/2fa\"" ]'
check "the domain was added to the entry" 'otto ls moved | grep -q "127.0.0.1"'
C goto 127.0.0.1:8765 "$site/logout" >/dev/null; sleep 1
otto fill moved >/dev/null 2>&1
check "after that, a plain fill works there" '[ "$(C eval 127.0.0.1:8765 "document.querySelector(\"[name=username]\").value")" = "\"demo\"" ]'
printf 'demo' | otto save moved-deny username --site old-name.example >/dev/null
printf '%s' "$pw" | otto save moved-deny password >/dev/null
C goto 127.0.0.1:8765 "$site/logout" >/dev/null; sleep 1
out=$(otto fill moved-deny --site 127.0.0.1 --reason "testing a no" 2>&1); rc=$?
check "the user can say no ($out)" '[ $rc -ne 0 ] && echo "$out" | grep -q "didn.t allow"'
check "and nothing was filled" '[ "$(C eval 127.0.0.1:8765 "document.querySelector(\"[name=username]\").value")" = "\"\"" ]'

echo "9. bypass: the user is away, and turned it on for this one entry"
printf 'demo' | otto save away-deny username --site old-name.example >/dev/null
printf '%s' "$pw" | otto save away-deny password >/dev/null
otto bypass away-deny --off >/dev/null 2>&1
C goto 127.0.0.1:8765 "$site/logout" >/dev/null; sleep 1
out=$(otto fill away-deny --site 127.0.0.1 --reason "testing away" 2>&1); rc=$?
check "without bypass nobody is there to allow the new site ($out)" '[ $rc -ne 0 ]'
otto bypass away-deny --reason "TEST: you're travelling and asked me to log in" >/dev/null 2>&1
otto fill away-deny --site 127.0.0.1 --submit >/dev/null; sleep 1
check "with bypass: filled on the new site and signed in, no reason needed" '[ "$(C eval 127.0.0.1:8765 location.pathname)" = "\"/2fa\"" ]'
check "the log says nobody was asked" 'otto log 5 | grep "away-deny" | grep -q "nobody asked.*bypass"'
check "the site wasn't added to the entry" '! otto ls away-deny | grep -q "127.0.0.1"'
otto bypass away-deny --off >/dev/null
C goto 127.0.0.1:8765 "$site/logout" >/dev/null; sleep 1
out=$(otto fill away-deny --site 127.0.0.1 --reason "after" 2>&1); rc=$?
check "bypass off: it asks again ($out)" '[ $rc -ne 0 ] && [ "$(C eval 127.0.0.1:8765 "document.querySelector(\"[name=username]\").value")" = "\"\"" ]'

echo "10. a card on a checkout page (fake_app adds testcard; the user approves each fill)"
C goto 127.0.0.1:8765 "$site/checkout" >/dev/null; sleep 1
out=$(otto fill-card testcard --site 127.0.0.1 2>&1); rc=$?
check "filled the shop's own card form ($out)" '[ $rc -eq 0 ] && [ "$(C eval 127.0.0.1:8765 "[...document.querySelectorAll(\"#pay input, #pay select\")].map((e) => e.value).join()")" = "\"TEST Person,4242424242424242,08,2028,737,34000\"" ]'
check "the shipping postal code was left alone" '[ "$(C eval 127.0.0.1:8765 "document.querySelector(\"[name=ship_zip]\").value")" = "\"\"" ]'
seen='[window.seen.number?.cardnumber, window.seen.expiry?.["exp-date"], window.seen.cvc?.cvc, window.seen.cvc?.postal].join()'
C goto 127.0.0.1:8765 "$site/checkout-framed" >/dev/null; sleep 2
out=$(otto fill-card testcard --site 127.0.0.1 2>&1); rc=$?
check "filled the payment provider's frames ($out)" '[ $rc -eq 0 ] && [ "$(C eval 127.0.0.1:8765 "$seen")" = "\"4242424242424242,08/28,737,34000\"" ]'
C goto 127.0.0.1:8765 "$site/checkout-framed?provider=evil.test" >/dev/null; sleep 2
out=$(otto fill-card testcard --site 127.0.0.1 2>&1); rc=$?
check "frames from a site that isn't a payment provider get nothing ($out)" '[ $rc -ne 0 ] && [ "$(C eval 127.0.0.1:8765 "JSON.stringify(window.seen)")" = "\"{}\"" ]'
C goto 127.0.0.1:8765 "$site/checkout-nested" >/dev/null; sleep 2
out=$(otto fill-card testcard --site 127.0.0.1 2>&1); rc=$?
check "nor a provider's frames inside another site's frame ($out)" '[ $rc -ne 0 ]'
out=$(otto fill testcard 2>&1); rc=$?
check "a card isn't filled as a login ($out)" '[ $rc -ne 0 ] && echo "$out" | grep -q fill_card'

echo "11. nothing secret in the activity log"
check "password absent from the activity log" '! otto log 100 | grep -qF "$pw"'
check "card number absent from the activity log" '! otto log 100 | grep -qE "4242 ?4242"'
echo "$pass passed, $fail failed"
[ $fail -eq 0 ]
