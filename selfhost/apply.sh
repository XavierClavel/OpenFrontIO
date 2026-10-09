#!/bin/sh
# shellcheck disable=SC2016 # the `$` in quoted Perl and TypeScript is literal
#
# Prepares a checkout for building the self-hosted image. It rewrites the
# working tree, so run it on a checkout you can throw away: the image workflow
# (.github/workflows/k8s-image.yml) runs it on its own fresh checkout, and
# selfhost/README.md shows how to do the same by hand.
#
# 1. Swaps upstream's proprietary/ for selfhost/proprietary/. It refuses if
#    upstream has a file with no replacement, so a proprietary asset added
#    upstream fails the build instead of shipping in the image.
# 2. Renames the game. The license's additional terms (LICENSE, "ADDITIONAL
#    TERMS") bar a modified version from using "OpenFront" as its primary
#    title. The "© OpenFront and Contributors" notice they also require is left
#    untouched.
# 3. Removes the Steam promotions. They sell OpenFront's Steam release, which
#    this game is not, and with the new logo beside them read as if it were.
# 4. Removes the ads, and the ad and ad-blocker scripts that serve them. Their
#    revenue is OpenFront's, and nothing in the license requires keeping them.
set -eu

# Must stay safe as-is in HTML text, a double-quoted attribute and JSON. Change
# the wordmark in selfhost/make-assets.py along with it.
NAME="PictaFront"

cd "$(dirname "$0")/.."

missing=$(
    cd proprietary
    find . -type f | sed 's#^\./##' | sort | while read -r f; do
        [ -e "../selfhost/proprietary/$f" ] || echo "  $f"
    done
)
if [ -n "$missing" ]; then
    echo "apply.sh: upstream proprietary/ has files with no replacement in selfhost/proprietary/:" >&2
    echo "$missing" >&2
    exit 1
fi
rm -rf proprietary
cp -R selfhost/proprietary proprietary
echo "Replaced proprietary/ with selfhost/proprietary/."

# retitle FILE REGEX: REGEX has two groups around the text to replace. Fails
# when it matches nothing, so an upstream markup change stops the build rather
# than shipping the old title.
retitle() {
    if ! NAME="$NAME" perl -0777 -pe "s{$2}{\$1\$ENV{NAME}\$2} or exit 1" "$1" > "$1.tmp"; then
        rm -f "$1.tmp"
        echo "apply.sh: no match for $2 in $1; has upstream changed it?" >&2
        exit 1
    fi
    mv "$1.tmp" "$1"
}
retitle index.html '(<title data-i18n="main\.title">)[^<]*(</title>)'
retitle index.html '(<meta property="og:title" content=")[^"]*(")'

# The page title after the client loads, in every language that translates it.
for f in resources/lang/*.json; do
    jq -e '.main.title' "$f" > /dev/null 2>&1 || continue
    jq --arg name "$NAME" '.main.title = $name' "$f" > "$f.tmp"
    mv "$f.tmp" "$f"
done
if [ "$(jq -r '.main.title' resources/lang/en.json)" != "$NAME" ]; then
    echo "apply.sh: main.title in resources/lang/en.json was not renamed" >&2
    exit 1
fi

# Installed-app name.
jq --arg name "$NAME" '.name = $name | .short_name = $name' resources/manifest.json > resources/manifest.json.tmp
mv resources/manifest.json.tmp resources/manifest.json

# The logo images' alt text. Cosmetic, so a miss only warns.
for f in src/client/components/DesktopNavBar.ts src/client/components/MobileNavBar.ts src/client/components/PlayPage.ts; do
    NAME="$NAME" perl -pi -e 's{alt="OpenFront"}{alt="$ENV{NAME}"}g' "$f"
    grep -qF "alt=\"$NAME\"" "$f" || echo "apply.sh: warning: no logo alt text renamed in $f" >&2
done

echo "Renamed the game to \"$NAME\"."

# patch FILE FROM TO: replaces the exact text FROM with TO. Fails when FROM is
# absent, so an upstream change stops the build rather than bringing a
# promotion back. Each TO keeps the original call, so no import goes unused
# for the build's `tsc --noEmit`.
patch() {
    if ! FROM="$2" TO="$3" perl -0777 -pe 's/\Q$ENV{FROM}\E/$ENV{TO}/g or exit 1' "$1" > "$1.tmp"; then
        rm -f "$1.tmp"
        echo "apply.sh: '$2' not found in $1; has upstream changed it?" >&2
        exit 1
    fi
    mv "$1.tmp" "$1"
}
# The store widget (home page on phones, end-of-game window) and the footer's
# "Buy on Steam" button already render nothing inside the Steam app; make that
# unconditional.
patch src/client/components/SteamWishlist.ts \
    'if (steamSDK.isOnSteam()) return nothing;' \
    'if (steamSDK.isOnSteam() || true) return nothing;'
patch src/client/components/SteamWishlistButton.ts \
    'if (steamSDK.isOnSteam()) return nothing;' \
    'if (steamSDK.isOnSteam() || true) return nothing;'
# The end-of-game window then picks one of its other promos, as it does in the
# Steam app, instead of a "Buy on Steam" heading over an empty widget.
patch src/client/hud/layers/WinModal.ts \
    'const canWishlist = !steamSDK.isOnSteam();' \
    'const canWishlist = false && !steamSDK.isOnSteam();'
# The popup offering to open lobby links in the Steam app. Main.ts only offers
# it when this element exists, and otherwise joins in the browser.
patch index.html '<steam-handoff-modal></steam-handoff-modal>' ''
# ...and the setting that would pick Steam for those links without asking.
patch src/client/UserSettingModal.ts '${canHandOffToSteam()' '${false && canHandOffToSteam()'

echo "Removed the Steam promotions."

# edit FILE PERL: applies the Perl substitution PERL to the whole file (so `.`
# needs /s to cross lines). Fails when it matches nothing, like patch.
edit() {
    if ! perl -0777 -pe "$2 or exit 1" "$1" > "$1.tmp"; then
        rm -f "$1.tmp"
        echo "apply.sh: no match for $2 in $1; has upstream changed it?" >&2
        exit 1
    fi
    mv "$1.tmp" "$1"
}
# The client's one switch for ads: Playwire's homepage and in-game units, and
# the Admiral ad-blocker popup, all wait on window.adsEnabled. Upstream turns it
# off for players who bought something; this turns it off for everyone.
edit src/client/Main.ts 's{(window\.adsEnabled =\s*)(!isAdFree)}{$1false && $2}'
# The scripts index.html loads whatever that switch says. (?:(?!</script>).)
# keeps each match inside one <script> element.
edit index.html 's{\n[ \t]*<script data-cfasync="false">\s*window\.ramp = (?:(?!</script>).)*</script>}{}s'
edit index.html 's{\n[ \t]*<script>\s*window\.googletag = (?:(?!</script>).)*</script>}{}s'
edit index.html 's{\n[ \t]*<script\s+async\s+src="https://www\.googletagmanager\.com/gtag/js\?id=AW-[^"]*"\s*></script>\s*<script>(?:(?!</script>).)*gtag\("config", "AW-[^"]*"\);\s*</script>}{}s'
edit index.html 's{\n[ \t]*<footer>\s*<script[^>]*\ssrc="[^"]*/ramp\.js"[^>]*></script>\s*</footer>}{}s'
# CrazyGames' SDK only serves its own ads, when the game is embedded there;
# detecting that (CrazyGamesSDK.isOnCrazyGames) does not need it.
edit index.html 's{\n[ \t]*<!-- CrazyGames SDK -->\s*<script\s+src="https://sdk\.crazygames\.com/[^"]*"\s+async\s*></script>}{}s'
if grep -nE 'AdShield|window\.ramp|ramp\.js|googletag\.|gtag/js\?id=AW-|crazygames-sdk' index.html >&2; then
    echo "apply.sh: ad scripts left in index.html (above)" >&2
    exit 1
fi
# Authorizes OpenFront's ad sellers to sell inventory on whatever domain serves it.
rm resources/public/ads.txt
# "Enjoying OpenFront? ... any purchase makes you ad-free": a one-time upsell to
# OpenFront's store, shown to everyone the API cannot vouch for, which here is
# everyone.
edit src/client/components/PurchaseNudgeModal.ts 's{(if \(\s*)(crazyGamesSDK\.isOnCrazyGames\(\) \|\|)}{$1true || $2}'

echo "Removed the ads."
