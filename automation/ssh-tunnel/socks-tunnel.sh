#!/usr/bin/env bash
# socks-tunnel.sh: start, stop and test an SSH SOCKS5 tunnel (ssh -D).
#
# Usage:
#   socks-tunnel.sh [options] up|down|status|test
#
# Options (each also has an environment variable):
#   -H HOST   server address or ssh_config alias          (TUNNEL_HOST)
#   -u USER   login name                                   (TUNNEL_USER)
#   -p PORT   SSH port, default 22                         (TUNNEL_PORT)
#   -i KEY    identity file                                (TUNNEL_KEY)
#   -l PORT   local SOCKS port, default 1080               (LOCAL_PORT)
#   -b ADDR   bind address, default 127.0.0.1              (BIND_ADDR)
#
# Defaults can also live in ~/.config/vpn-lab/tunnel.conf (shell syntax, same names).
#
# Other environment:
#   TEST_URL                   address fetched by 'test' (default https://api.ipify.org)
#   STRICT_HOST_KEY_CHECKING   default accept-new
#   SSH_EXTRA_OPTS             extra ssh options, space separated
#
# Nothing has to be installed on the server. This is plain OpenSSH dynamic
# forwarding, so the server only needs sshd with AllowTcpForwarding enabled.

set -euo pipefail

CONFIG_FILE="${XDG_CONFIG_HOME:-${HOME}/.config}/vpn-lab/tunnel.conf"
if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${CONFIG_FILE}"
fi

TUNNEL_HOST="${TUNNEL_HOST:-}"
TUNNEL_USER="${TUNNEL_USER:-}"
TUNNEL_PORT="${TUNNEL_PORT:-22}"
TUNNEL_KEY="${TUNNEL_KEY:-}"
LOCAL_PORT="${LOCAL_PORT:-1080}"
BIND_ADDR="${BIND_ADDR:-127.0.0.1}"
TEST_URL="${TEST_URL:-https://api.ipify.org}"
STRICT_HOST_KEY_CHECKING="${STRICT_HOST_KEY_CHECKING:-accept-new}"
SSH_EXTRA_OPTS="${SSH_EXTRA_OPTS:-}"

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

while getopts ":H:u:p:i:l:b:h" opt; do
  case "${opt}" in
    H) TUNNEL_HOST="${OPTARG}" ;;
    u) TUNNEL_USER="${OPTARG}" ;;
    p) TUNNEL_PORT="${OPTARG}" ;;
    i) TUNNEL_KEY="${OPTARG}" ;;
    l) LOCAL_PORT="${OPTARG}" ;;
    b) BIND_ADDR="${OPTARG}" ;;
    *) usage ;;
  esac
done
shift $((OPTIND - 1))

ACTION="${1:-}"
[[ -n "${ACTION}" ]] || usage
[[ -n "${TUNNEL_HOST}" ]] || { echo "error: no server given, use -H HOST or set TUNNEL_HOST" >&2; exit 2; }
[[ "${LOCAL_PORT}" =~ ^[0-9]+$ ]] || { echo "error: invalid local port" >&2; exit 2; }

TARGET="${TUNNEL_USER:+${TUNNEL_USER}@}${TUNNEL_HOST}"
SOCK_DIR="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}"
SOCK="${SOCK_DIR}/vpn-lab-tunnel-$(id -u)-${LOCAL_PORT}.sock"

ssh_args=(
  -o ExitOnForwardFailure=yes
  -o ServerAliveInterval=30
  -o ServerAliveCountMax=3
  -o BatchMode=yes
  -o "StrictHostKeyChecking=${STRICT_HOST_KEY_CHECKING}"
  -p "${TUNNEL_PORT}"
)
if [[ -n "${TUNNEL_KEY}" ]]; then ssh_args+=(-i "${TUNNEL_KEY}" -o IdentitiesOnly=yes); fi
if [[ -n "${SSH_EXTRA_OPTS}" ]]; then
  # shellcheck disable=SC2206
  ssh_args+=(${SSH_EXTRA_OPTS})
fi

is_up() { ssh -S "${SOCK}" -O check "${ssh_args[@]}" "${TARGET}" >/dev/null 2>&1; }

case "${ACTION}" in
  up)
    if is_up; then echo "tunnel already running on ${BIND_ADDR}:${LOCAL_PORT}"; exit 0; fi
    rm -f "${SOCK}"
    ssh -fN -M -S "${SOCK}" -D "${BIND_ADDR}:${LOCAL_PORT}" "${ssh_args[@]}" "${TARGET}"
    echo "SOCKS5 tunnel up on ${BIND_ADDR}:${LOCAL_PORT} via ${TARGET}"
    echo "point your browser at SOCKS host ${BIND_ADDR}, port ${LOCAL_PORT}, SOCKS v5, with remote DNS enabled"
    ;;
  down)
    if is_up; then
      ssh -S "${SOCK}" -O exit "${ssh_args[@]}" "${TARGET}" >/dev/null 2>&1 || true
      echo "tunnel stopped"
    else
      echo "tunnel was not running"
    fi
    ;;
  status)
    if is_up; then
      ssh -S "${SOCK}" -O check "${ssh_args[@]}" "${TARGET}" 2>&1 | sed 's/^/ssh: /'
      echo "listening on ${BIND_ADDR}:${LOCAL_PORT}"
    else
      echo "tunnel is not running"
      exit 1
    fi
    ;;
  test)
    # socks5h makes curl send the hostname to the proxy, so DNS is resolved on the server too.
    # NO_PROXY is cleared because curl would otherwise bypass the tunnel for listed hosts.
    out="$(env -u NO_PROXY -u no_proxy curl -fsS --max-time 10 --proxy "socks5h://${BIND_ADDR}:${LOCAL_PORT}" "${TEST_URL}")"
    echo "exit address through the tunnel: ${out}"
    ;;
  *) usage ;;
esac
