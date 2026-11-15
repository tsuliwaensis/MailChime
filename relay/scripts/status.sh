#!/bin/bash
# Read-only relay status check. Never prints the secret or puts it in curl's arguments.
set +x
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
secrets_file="$script_dir/../.secrets.env"
relay_url='https://rhpt.mym5n442j7.workers.dev'
device_secret=''

if [[ "${1:-}" == '--help' ]]; then
  printf 'Usage: %s [--prompt]\nReads DEVICE_SECRET from relay/.secrets.env, or prompts if unavailable.\n' "$0"
  exit 0
fi
if [[ $# -gt 1 || ( $# -eq 1 && "$1" != '--prompt' ) ]]; then
  printf 'Usage: %s [--prompt]\n' "$0" >&2
  exit 2
fi

if [[ "${1:-}" != '--prompt' && -r "$secrets_file" ]]; then
  # Parse the expected assignment as data; do not execute/source the secrets file.
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    case "$line" in
      DEVICE_SECRET=*)
        device_secret="${line#DEVICE_SECRET=}"
        if [[ "$device_secret" == \"*\" || "$device_secret" == \'*\' ]]; then
          device_secret="${device_secret:1:${#device_secret}-2}"
        fi
        break
        ;;
    esac
  done < "$secrets_file"
fi

if [[ -z "$device_secret" ]]; then
  if [[ ! -t 0 ]]; then
    printf 'No device secret found. Run interactively with --prompt.\n' >&2
    exit 1
  fi
  read -r -s -p 'Device secret (input hidden; press Return): ' device_secret
  printf '\n' >&2
fi
if [[ ${#device_secret} -lt 32 || "$device_secret" == *$'\r'* || "$device_secret" == *$'\n'* ]]; then
  printf 'Invalid device secret. Check DEVICE_SECRET in relay/.secrets.env or use --prompt.\n' >&2
  exit 1
fi
trap 'unset device_secret line' EXIT

# Header goes over stdin, rather than appearing in the process argument list.
if printf 'Authorization: Bearer %s\n' "$device_secret" |
  /usr/bin/curl --connect-timeout 10 --max-time 20 --fail --silent --show-error \
    --header @- "$relay_url/status"; then
  printf '\n'
else
  printf '\nStatus check failed. HTTP 401 means the device secret was rejected; 404 means the route is unavailable.\n' >&2
  exit 1
fi
