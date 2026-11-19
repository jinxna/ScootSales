#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP="$ROOT/flutter_mobile_app"
BUILDS=${SCOOT_BUILDS_DIR:-/d/builds/scoot-sales-mobile}
API=${PLATFORM_API_URL:-https://control.scootsales.my}
COPILOT=${COPILOT_URL:-https://scootsales.my}
SITE=${COMPANY_SITE:-https://scootsales.my}
KEYS=${COMPANY_REGISTRY_KEYS:-}
PACKAGE=my.scootsales.app
KEY_ENTRY='[a-z0-9][a-z0-9._-]{0,63}=[A-Za-z0-9_-]{43}'

fail() { echo "REFUSED: $*" >&2; exit 1; }
pass() { echo "ok    $*" | tee -a "$CHECKS"; }

TOOLS=${ANDROID_BUILD_TOOLS:-$(ls -d "${LOCALAPPDATA:-}/Android/Sdk/build-tools"/* 2>/dev/null | sort -V | tail -1)}
[ -x "$TOOLS/aapt2.exe" ] || [ -x "$TOOLS/aapt2" ] || fail "aapt2 not found. Set ANDROID_BUILD_TOOLS to an Android SDK build-tools folder."
AAPT2=$( [ -x "$TOOLS/aapt2.exe" ] && echo "$TOOLS/aapt2.exe" || echo "$TOOLS/aapt2" )
APKSIGNER=$( [ -f "$TOOLS/apksigner.bat" ] && echo "$TOOLS/apksigner.bat" || echo "$TOOLS/apksigner" )

[[ "$KEYS" =~ ^$KEY_ENTRY(,$KEY_ENTRY)*$ ]] || fail "COMPANY_REGISTRY_KEYS is missing or not keyId=publicKey. Use the line that 'scoot-deploy public-key' prints on the droplet."
[[ "$API" =~ ^https://[a-z0-9.-]+$ ]] || fail "PLATFORM_API_URL must be an https origin with no path, got '$API'."
[[ "$COPILOT" =~ ^https://[a-z0-9.-]+$ ]] || fail "COPILOT_URL must be an https origin with no path, got '$COPILOT'."

VERSION_LINE=$(grep -E '^version: ' "$APP/pubspec.yaml" | head -1)
[[ "$VERSION_LINE" =~ ^version:\ ([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)$ ]] || fail "pubspec.yaml version line '$VERSION_LINE' is not x.y.z+N."
VERSION=${BASH_REMATCH[1]}
CODE=${BASH_REMATCH[2]}

PREVIOUS_APK=$(ls "$BUILDS"/*-build*/*.apk 2>/dev/null | sed -E 's/.*-build([0-9]+)\/[^/]*$/\1 &/' | sort -n | tail -1 | cut -d' ' -f2- || true)
if [ -z "$PREVIOUS_APK" ] && ls -d "$BUILDS"/*-build* > /dev/null 2>&1; then
  fail "no build folder in $BUILDS holds an APK, so the signing certificate cannot be compared. Put the last shipped APK back in its folder."
fi
PREVIOUS_CODE=$(ls -d "$BUILDS"/*-build* 2>/dev/null | sed -E 's/.*-build([0-9]+)$/\1/' | sort -n | tail -1 || true)
PREVIOUS_CODE=${PREVIOUS_CODE:-0}
[ "$CODE" -gt "$PREVIOUS_CODE" ] || fail "versionCode $CODE is not above the newest build $PREVIOUS_CODE in $BUILDS. Raise the +N in flutter_mobile_app/pubspec.yaml."

RECORD=$(curl -fsS --max-time 20 "$SITE/workspace.json") || fail "could not read $SITE/workspace.json."
python -I -c '
import base64, json, sys
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
keys = dict(entry.split("=", 1) for entry in sys.argv[1].split(","))
record = json.loads(sys.argv[2])
raw = lambda s: base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))
key = keys.get(record["keyId"])
if key is None:
    sys.exit("REFUSED: the live company record is signed with key " + record["keyId"] + ", which COMPANY_REGISTRY_KEYS does not hold.")
Ed25519PublicKey.from_public_bytes(raw(key)).verify(raw(record["signature"]), record["payload"].encode())
' "$KEYS" "$RECORD" || fail "COMPANY_REGISTRY_KEYS does not check the live company record at $SITE/workspace.json."

OUT="$BUILDS/$(date +%Y-%m-%d)-build$CODE"
[ ! -e "$OUT" ] || fail "$OUT already exists."
STAGE="$BUILDS/.staging-build$CODE"
rm -rf "$STAGE"
mkdir -p "$STAGE"
CHECKS="$STAGE/checks.txt"
APK="$STAGE/scoot-sales-$VERSION-build$CODE.apk"
echo "build $VERSION ($CODE) from commit $(git -C "$ROOT" rev-parse --short HEAD), uncommitted files: $(git -C "$ROOT" status --porcelain | wc -l)" > "$CHECKS"
pass "live company record at $SITE is signed by a key in COMPANY_REGISTRY_KEYS"

echo "building $APK"
(cd "$APP" && flutter build apk --release \
  --dart-define "PLATFORM_API_URL=$API" \
  --dart-define "COMPANY_LOOKUP_URL=$API/v1/companies" \
  --dart-define "COPILOT_URL=$COPILOT" \
  --dart-define "COMPANY_REGISTRY_KEYS=$KEYS") > "$STAGE/build.log" 2>&1 \
  || { tail -20 "$STAGE/build.log"; fail "flutter build failed, see $STAGE/build.log"; }
cp "$APP/build/app/outputs/flutter-apk/app-release.apk" "$APK"
(cd "$APP/android" && ./gradlew --stop > /dev/null 2>&1) || echo "note: the Gradle daemon did not stop; stop it before the next heavy job"

BADGING=$("$AAPT2" dump badging "$APK" | head -1)
[[ "$BADGING" == *"name='$PACKAGE' versionCode='$CODE' versionName='$VERSION'"* ]] || fail "the APK says: $BADGING"
pass "package $PACKAGE, versionCode $CODE, versionName $VERSION"

NEW_CERT=$("$APKSIGNER" verify --print-certs "$APK" | grep -m1 'certificate SHA-256 digest' | awk '{print $NF}')
[ -n "$NEW_CERT" ] || fail "apksigner found no signing certificate."
if [ -n "$PREVIOUS_APK" ]; then
  OLD_CERT=$("$APKSIGNER" verify --print-certs "$PREVIOUS_APK" | grep -m1 'certificate SHA-256 digest' | awk '{print $NF}')
  [ "$NEW_CERT" = "$OLD_CERT" ] || fail "signing certificate $NEW_CERT differs from $PREVIOUS_APK ($OLD_CERT). Phones cannot update over the old app."
  pass "same signing certificate as $(basename "$PREVIOUS_APK") (${NEW_CERT:0:16}...)"
else
  pass "first build in $BUILDS: no earlier APK to compare the signing certificate with"
fi

LIBS=$(mktemp -d)
unzip -q -o "$APK" 'lib/*/libapp.so' -d "$LIBS"
for LIB in "$LIBS"/lib/*/libapp.so; do
  ABI=$(basename "$(dirname "$LIB")")
  for NEEDED in "$API" "$API/v1/companies" "$COPILOT" "$KEYS" "I have an invitation code"; do
    grep -a -q -F "$NEEDED" "$LIB" || fail "$ABI app code does not contain '${NEEDED:0:40}'. A real phone would miss that feature."
  done
  pass "$ABI holds the platform address, company lookup, Scout address, company key and the invitation button"
done
rm -rf "$LIBS"

cat >> "$CHECKS" <<EOF

Still to do by hand, in this order:
1. Emulator: adb uninstall $PACKAGE only if an old debug app is on it, adb install "$OUT/$(basename "$APK")", open the app, read logcat for ClassNotFoundException, channel-error and ANR. Expect the Sign in screen with "I have an invitation code".
2. Emulator: sign in as a test salesperson, Start Work, record one order, Stop Work.
3. Real phone (owner or tester): install over the last build without uninstalling, so saved data stays. Check sign in, the invitation code button, Start Work with real GPS, an order with photo and signature, and work with no signal that sends later.
4. Send to testers only after the owner says yes.
EOF
mv "$STAGE" "$OUT"
echo
cat "$OUT/checks.txt"
echo
echo "APK: $OUT/$(basename "$APK")"
