#!/usr/bin/env bash
# Regenerate the root-password-hashed line in answer.toml, or print a hash to
# paste. Usage:
#   scripts/gen-answer.sh 'yourpassword'            # prints the SHA-512 hash
#   scripts/gen-answer.sh 'yourpassword' --write    # rewrites answer.toml in place
set -euo pipefail

PW="${1:?usage: gen-answer.sh <password> [--write]}"

if command -v mkpasswd >/dev/null 2>&1; then
  HASH="$(mkpasswd -m sha-512 "$PW")"
elif command -v openssl >/dev/null 2>&1; then
  HASH="$(openssl passwd -6 "$PW")"
else
  echo "need mkpasswd (whois pkg) or openssl" >&2
  exit 1
fi

if [ "${2:-}" = "--write" ]; then
  ANSWER="$(dirname "$0")/../answer.toml"
  sed -i "s|^root-password-hashed = .*|root-password-hashed = \"${HASH}\"|" "$ANSWER"
  echo "wrote hash to $ANSWER"
else
  echo "$HASH"
fi
