#!/usr/bin/env bash
# End-to-end tests for socks-tunnel.sh and new-client.sh against a throwaway local sshd.
#   * the SOCKS tunnel really carries a request to a web server that only the "server" side can reach
#   * new-client.sh fetches a config over SSH from the real wgctl and saves it safely
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TUNNEL="${ROOT}/automation/ssh-tunnel/socks-tunnel.sh"
NEWCLIENT="${ROOT}/automation/scripts/new-client.sh"
WGCTL="${ROOT}/automation/terraform/modules/cloud-init/files/wgctl"

for c in python3 curl ssh; do
  command -v "${c}" >/dev/null 2>&1 || { echo "SKIP: ${c} not installed"; exit 0; }
done

# The scripts under test talk to 127.0.0.1, so ignore any proxy in the environment.
# NO_PROXY must also be unset: curl applies it even when --proxy is given explicitly,
# which would make a direct connection look like a working tunnel.
unset HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY http_proxy https_proxy all_proxy no_proxy

TMP="$(mktemp -d)"
SSHD_PID=""
WEB_PID=""
cleanup() {
  if [[ -n "${WEB_PID}" ]]; then kill "${WEB_PID}" 2>/dev/null || true; fi
  if [[ -n "${SSHD_PID}" ]]; then kill "${SSHD_PID}" 2>/dev/null || true; fi
  rm -rf "${TMP}"
}
trap cleanup EXIT

# shellcheck source=lib/test_sshd.sh
source "${ROOT}/tests/lib/test_sshd.sh"
if ! start_test_sshd "${TMP}"; then echo "SKIP: sshd is not available"; exit 0; fi

pass=0
fail=0
ok() { echo "ok   - $1"; pass=$((pass + 1)); }
bad() { echo "FAIL - $1"; fail=$((fail + 1)); }

ME="$(id -un)"
export SSH_EXTRA_OPTS="-o UserKnownHostsFile=/dev/null"
export STRICT_HOST_KEY_CHECKING=no

# A web server standing in for "something only reachable from the VPN server".
WEB_PORT="$(free_port)"
echo "reached-through-the-tunnel" > "${TMP}/index.html"
(cd "${TMP}" && exec python3 -m http.server "${WEB_PORT}" --bind 127.0.0.1 >/dev/null 2>&1) &
WEB_PID=$!
for _ in $(seq 1 50); do (echo > "/dev/tcp/127.0.0.1/${WEB_PORT}") 2>/dev/null && break; sleep 0.1; done

SOCKS_PORT="$(free_port)"
tunnel() { "${TUNNEL}" -H 127.0.0.1 -u "${ME}" -p "${SSH_PORT}" -i "${SSH_KEY}" -l "${SOCKS_PORT}" "$@"; }

# socks-tunnel.sh ------------------------------------------------------------
if tunnel status >/dev/null 2>&1; then bad "status reports down before start"; else ok "status reports down before start"; fi
if tunnel up >/dev/null 2>&1; then ok "tunnel comes up"; else bad "tunnel comes up"; fi
if tunnel status >/dev/null 2>&1; then ok "status reports up"; else bad "status reports up"; fi
if tunnel up 2>&1 | grep -q "already running"; then ok "a second 'up' is a no-op"; else bad "a second 'up' is a no-op"; fi

body="$(curl -fsS --max-time 8 --proxy "socks5h://127.0.0.1:${SOCKS_PORT}" "http://127.0.0.1:${WEB_PORT}/" || true)"
if [[ "${body}" == "reached-through-the-tunnel" ]]; then ok "SOCKS5 proxy relays a request"; else bad "SOCKS5 proxy relays a request (got '${body}')"; fi

if TEST_URL="http://127.0.0.1:${WEB_PORT}/" tunnel test 2>&1 | grep -q "reached-through-the-tunnel"; then ok "'test' subcommand works"; else bad "'test' subcommand works"; fi

if tunnel down >/dev/null 2>&1; then ok "tunnel stops"; else bad "tunnel stops"; fi
if curl -fsS --max-time 3 --proxy "socks5h://127.0.0.1:${SOCKS_PORT}" "http://127.0.0.1:${WEB_PORT}/" >/dev/null 2>&1; then
  bad "proxy port is closed after 'down'"
else
  ok "proxy port is closed after 'down'"
fi

# new-client.sh --------------------------------------------------------------
export WG_DIR="${TMP}/wg" WGCTL_LOCK="${TMP}/lock" WGCTL_SKIP_APPLY=1 WG_IFACE=wg0
"${WGCTL}" init --port 51820 --cidr 10.66.66.0/24 --dns "1.1.1.1, 1.0.0.1" >/dev/null 2>&1

export WGCTL_REMOTE="${WGCTL}"
export REMOTE_PREFIX="env WG_DIR=${WG_DIR} WGCTL_LOCK=${WGCTL_LOCK} WGCTL_SKIP_APPLY=1"
OUT="${TMP}/clients-out"
newc() { "${NEWCLIENT}" -H 127.0.0.1 -u "${ME}" -p "${SSH_PORT}" -i "${SSH_KEY}" -o "${OUT}" "$@"; }

if newc -e vpn.example.net laptop >/dev/null 2>&1; then ok "new-client fetches a config over SSH"; else bad "new-client fetches a config over SSH"; fi
if grep -q '^Endpoint = vpn.example.net:51820$' "${OUT}/laptop.conf"; then ok "config uses the requested endpoint"; else bad "config uses the requested endpoint"; fi
if [[ "$(stat -c %a "${OUT}/laptop.conf")" == "600" ]]; then ok "saved config is mode 600"; else bad "saved config is mode 600"; fi
if [[ "$(cat "${OUT}/.gitignore")" == "*" ]]; then ok "output directory ignores itself in git"; else bad "output directory ignores itself in git"; fi
if newc laptop >/dev/null 2>&1; then bad "overwriting without -f is refused"; else ok "overwriting without -f is refused"; fi
if newc phone >/dev/null 2>&1 && grep -q '^Address = 10.66.66.3/32$' "${OUT}/phone.conf"; then ok "second client gets the next address"; else bad "second client gets the next address"; fi
if newc 'bad name' >/dev/null 2>&1; then bad "unsafe client name is rejected"; else ok "unsafe client name is rejected"; fi

echo
echo "passed: ${pass}  failed: ${fail}"
(( fail == 0 ))
