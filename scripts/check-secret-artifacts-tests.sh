#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCANNER="$SCRIPT_DIR/check-secret-artifacts.py"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/address-atlas-secret-scan.XXXXXX")"
cleanup() {
  find "$TEST_ROOT" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT

detectors=(github github_fine encrypted_pkcs8 pgp_private aws google slack jwt bearer credential_url assignment)
for detector in "${detectors[@]}"; do
  repo="$TEST_ROOT/$detector"
  mkdir -p "$repo/.github"
  git -C "$repo" init -q
  printf '{"version":1,"entries":[]}\n' > "$repo/.github/secret-scan-allowlist.json"
  case "$detector" in
    github) value="ghp_$(printf 'A%.0s' {1..36})" ;;
    github_fine) value="github_""pat_$(printf 'K%.0s' {1..48})" ;;
    encrypted_pkcs8) value="-----BEGIN ""ENCRYPTED PRIVATE KEY-----" ;;
    pgp_private) value="-----BEGIN PGP ""PRIVATE KEY BLOCK-----" ;;
    aws) value="AKIA$(printf 'B%.0s' {1..16})" ;;
    google) value="AIza$(printf 'C%.0s' {1..35})" ;;
    slack) value="xoxb-$(printf 'D%.0s' {1..32})" ;;
    jwt) value="eyJ$(printf 'E%.0s' {1..12}).$(printf 'F%.0s' {1..12}).$(printf 'G%.0s' {1..12})" ;;
    bearer) value="Bearer $(printf 'H%.0s' {1..32})" ;;
    credential_url) value="postgres://user:$(printf 'I%.0s' {1..32})@db.example.test/app" ;;
    assignment) value="API_KEY=$(printf 'Jj7%.0s' {1..12})" ;;
  esac
  printf '%s\n' "$value" > "$repo/canary.txt"
  git -C "$repo" add .
  if python3 "$SCANNER" --root "$repo" > "$repo/stdout" 2> "$repo/stderr"; then
    echo "scanner accepted $detector canary" >&2
    exit 1
  fi
  grep -F 'value suppressed' "$repo/stderr" >/dev/null
  ! grep -F -- "$value" "$repo/stderr" >/dev/null
done

repo="$TEST_ROOT/nul-mixed-content"
mkdir -p "$repo/.github"
git -C "$repo" init -q
printf '{"version":1,"entries":[]}\n' > "$repo/.github/secret-scan-allowlist.json"
nul_canary="ghp_$(printf 'N%.0s' {1..36})"
printf 'binary-prefix\0%s\0binary-suffix\n' "$nul_canary" > "$repo/innocent.bin"
git -C "$repo" add .
if python3 "$SCANNER" --root "$repo" > "$repo/stdout" 2> "$repo/stderr"; then
  echo 'scanner accepted a credential canary hidden behind a NUL byte' >&2
  exit 1
fi
grep -F 'possible github-token; value suppressed' "$repo/stderr" >/dev/null
! grep -F -- "$nul_canary" "$repo/stdout" "$repo/stderr" >/dev/null

repo="$TEST_ROOT/allowlist"
mkdir -p "$repo/.github"
git -C "$repo" init -q
line='CI_PASSWORD=public_fixture_value_1234567890'
printf '%s\n' "$line" > "$repo/fixture.env"
digest="$(printf '%s' "$line" | shasum -a 256 | awk '{print $1}')"
cat > "$repo/.github/secret-scan-allowlist.json" <<JSON
{"version":1,"entries":[{"path":"fixture.env","detector":"credential-assignment","lineSha256":"$digest","reason":"Exact public CI fixture"}]}
JSON
git -C "$repo" add .
python3 "$SCANNER" --root "$repo" >/dev/null
printf '%s\n' 'CI_PASSWORD=different_value_that_must_fail_987654321' > "$repo/fixture.env"
if python3 "$SCANNER" --root "$repo" >/dev/null 2>&1; then
  echo 'changed allowlisted fixture was accepted' >&2
  exit 1
fi

for extension in p12 der jks keystore p8 ppk kdbx; do
  repo="$TEST_ROOT/filename-$extension"
  mkdir -p "$repo/.github"
  git -C "$repo" init -q
  printf '{"version":1,"entries":[]}\n' > "$repo/.github/secret-scan-allowlist.json"
  if [[ "$extension" == p8 ]]; then
    printf 'binary\0private-key-canary\0' > "$repo/release.$extension"
  else
    printf 'not even a real key\n' > "$repo/release.$extension"
  fi
  git -C "$repo" add .
  if python3 "$SCANNER" --root "$repo" >/dev/null 2>&1; then
    echo "private .$extension artifact filename was accepted" >&2
    exit 1
  fi
done

repo="$TEST_ROOT/symlink"
mkdir -p "$repo/.github"
git -C "$repo" init -q
printf '{"version":1,"entries":[]}\n' > "$repo/.github/secret-scan-allowlist.json"
target="$TEST_ROOT/outside-target"
printf '%s\n' 'OUTSIDE_TARGET_SECRET_k7M2p9' > "$target"
ln -s "$target" "$repo/tracked-link.txt"
git -C "$repo" add .
if python3 "$SCANNER" --root "$repo" > "$repo/stdout" 2> "$repo/stderr"; then
  echo 'tracked symlink was accepted' >&2
  exit 1
fi
grep -F 'repository entry must be a regular file' "$repo/stderr" >/dev/null
! grep -F 'OUTSIDE_TARGET_SECRET_k7M2p9' "$repo/stdout" "$repo/stderr" >/dev/null

repo="$TEST_ROOT/oversized"
mkdir -p "$repo/.github"
git -C "$repo" init -q
printf '{"version":1,"entries":[]}\n' > "$repo/.github/secret-scan-allowlist.json"
dd if=/dev/zero of="$repo/oversized.bin" bs=1 count=0 seek=4194305 2>/dev/null
printf '%s\n' 'OVERSIZED_CONTENT_SECRET_x8Q4n1' >> "$repo/oversized.bin"
git -C "$repo" add .
if python3 "$SCANNER" --root "$repo" > "$repo/stdout" 2> "$repo/stderr"; then
  echo 'oversized repository file was accepted' >&2
  exit 1
fi
grep -F 'exceeds the 4194304-byte scan limit' "$repo/stderr" >/dev/null
! grep -F 'OVERSIZED_CONTENT_SECRET_x8Q4n1' "$repo/stdout" "$repo/stderr" >/dev/null

echo 'check-secret-artifacts-tests: 22/22 passed'
