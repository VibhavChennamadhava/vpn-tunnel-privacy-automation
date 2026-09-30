#!/usr/bin/env bash
# new-client.sh: create a WireGuard client on the server and save its config locally.
#
# Usage:
#   new-client.sh -H SERVER_IP [options] NAME
#
# Options:
#   -H HOST   server address (required)
#   -u USER   SSH user, default ubuntu
#   -p PORT   SSH port, default 22
#   -i KEY    SSH identity file
#   -o DIR    where to save the config, default ./clients
#   -e HOST   endpoint written into the config, default the -H value
#   -f        overwrite an existing local file
#   -q        also draw a QR code in the terminal (needs qrencode), for phones
#
# The config contains a private key. It is saved with mode 600 inside a
# directory that ignores itself in git. Never commit or paste it anywhere.
#
# Environment (advanced):
#   REMOTE_PREFIX   command placed before wgctl on the server, default "sudo"
#   WGCTL_REMOTE    path to wgctl on the server, default /usr/local/sbin/wgctl
#   SSH_EXTRA_OPTS  extra ssh options, space separated

set -euo pipefail

USER_NAME="ubuntu"
PORT="22"
KEY=""
OUT_DIR="./clients"
HOST=""
ENDPOINT=""
FORCE=0
QR=0
REMOTE_PREFIX="${REMOTE_PREFIX-sudo}"
WGCTL_REMOTE="${WGCTL_REMOTE:-/usr/local/sbin/wgctl}"
SSH_EXTRA_OPTS="${SSH_EXTRA_OPTS:-}"

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

while getopts ":H:u:p:i:o:e:fqh" opt; do
  case "${opt}" in
    H) HOST="${OPTARG}" ;;
    u) USER_NAME="${OPTARG}" ;;
    p) PORT="${OPTARG}" ;;
    i) KEY="${OPTARG}" ;;
    o) OUT_DIR="${OPTARG}" ;;
    e) ENDPOINT="${OPTARG}" ;;
    f) FORCE=1 ;;
    q) QR=1 ;;
    *) usage ;;
  esac
done
shift $((OPTIND - 1))

NAME="${1:-}"
[[ -n "${HOST}" && -n "${NAME}" ]] || usage
[[ "${NAME}" =~ ^[A-Za-z0-9_-]{1,32}$ ]] || { echo "error: name must match [A-Za-z0-9_-]{1,32}" >&2; exit 2; }
ENDPOINT="${ENDPOINT:-${HOST}}"
# Host and endpoint end up in a remote shell command, so allow only hostname and address characters.
for v in "${HOST}" "${ENDPOINT}"; do
  [[ "${v}" =~ ^[A-Za-z0-9.:_-]{1,253}$ ]] || { echo "error: invalid host or endpoint: ${v}" >&2; exit 2; }
done

mkdir -p "${OUT_DIR}"
chmod 700 "${OUT_DIR}"
# A directory with its own catch-all .gitignore can never be committed by accident.
[[ -f "${OUT_DIR}/.gitignore" ]] || printf '*\n' > "${OUT_DIR}/.gitignore"

DEST="${OUT_DIR}/${NAME}.conf"
if [[ -e "${DEST}" && "${FORCE}" -ne 1 ]]; then
  echo "error: ${DEST} already exists, use -f to overwrite" >&2
  exit 1
fi

ssh_args=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -p "${PORT}")
if [[ -n "${KEY}" ]]; then ssh_args+=(-i "${KEY}" -o IdentitiesOnly=yes); fi
if [[ -n "${SSH_EXTRA_OPTS}" ]]; then
  # shellcheck disable=SC2206
  ssh_args+=(${SSH_EXTRA_OPTS})
fi

umask 077
tmp="$(mktemp "${OUT_DIR}/.${NAME}.XXXXXX")"
trap 'rm -f "${tmp}"' EXIT

# Quoting is done on the remote side by the shell, so keep every value to safe characters.
remote_cmd="${REMOTE_PREFIX} ${WGCTL_REMOTE} add ${NAME} --print --endpoint ${ENDPOINT}"
# shellcheck disable=SC2029  # the command is meant to expand here, values are validated above
if ! ssh "${ssh_args[@]}" "${USER_NAME}@${HOST}" "${remote_cmd}" > "${tmp}"; then
  echo "error: could not create the client on ${HOST}" >&2
  exit 1
fi

grep -q '^\[Interface\]$' "${tmp}" || { echo "error: server did not return a WireGuard config" >&2; exit 1; }

mv "${tmp}" "${DEST}"
chmod 600 "${DEST}"
trap - EXIT
echo "saved ${DEST}"

if (( QR )); then
  if command -v qrencode >/dev/null 2>&1; then qrencode -t ansiutf8 < "${DEST}"; else echo "note: qrencode not installed, skipping QR code" >&2; fi
fi

cat <<EOF

next steps:
  1. ./automation/scripts/verify-vpn.sh baseline      (before connecting)
  2. import ${DEST} into the WireGuard app and connect
  3. ./automation/scripts/verify-vpn.sh check --expect ${ENDPOINT}
EOF
