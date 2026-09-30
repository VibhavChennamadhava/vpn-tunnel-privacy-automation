#!/usr/bin/env bash
# Offline tests for automation/terraform/modules/cloud-init/files/wgctl.
# Uses the real wg key tools but never touches a live interface.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WGCTL="${ROOT}/automation/terraform/modules/cloud-init/files/wgctl"

command -v wg >/dev/null || { echo "SKIP: wg not installed"; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
export WG_DIR="${TMP}/wg" WG_IFACE=wg0 WGCTL_LOCK="${TMP}/lock" WGCTL_SKIP_APPLY=1

pass=0
fail=0
check() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "ok   - ${desc}"; pass=$((pass + 1))
  else
    echo "FAIL - ${desc}"; fail=$((fail + 1))
  fi
}
check_fails() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "FAIL - ${desc} (expected a failure)"; fail=$((fail + 1))
  else
    echo "ok   - ${desc}"; pass=$((pass + 1))
  fi
}

# init --------------------------------------------------------------------
check "init succeeds" "${WGCTL}" init --port 51820 --cidr 10.66.66.0/24 --dns "1.1.1.1, 1.0.0.1" --endpoint vpn.example.net
check "server key is mode 600" test "$(stat -c %a "${WG_DIR}/server.key")" = "600"
check "wg0.conf has the server address" grep -q '^Address = 10.66.66.1/24$' "${WG_DIR}/wg0.conf"
check "init is idempotent" "${WGCTL}" init --port 51820 --cidr 10.66.66.0/24 --dns "1.1.1.1"
check_fails "init rejects a /16" "${WGCTL}" init --port 51820 --cidr 10.66.0.0/16 --dns "1.1.1.1"
check_fails "init rejects a bad port" env WG_DIR="${TMP}/other" "${WGCTL}" init --port 99999 --cidr 10.1.1.0/24 --dns "1.1.1.1"

# add ---------------------------------------------------------------------
check "add laptop" "${WGCTL}" add laptop
check "add phone" "${WGCTL}" add phone
check "laptop gets .2" grep -q '^Address = 10.66.66.2/32$' "${WG_DIR}/clients/laptop.conf"
check "phone gets .3" grep -q '^Address = 10.66.66.3/32$' "${WG_DIR}/clients/phone.conf"
check "client config routes everything" grep -q '^AllowedIPs = 0.0.0.0/0, ::/0$' "${WG_DIR}/clients/laptop.conf"
check "client config uses the endpoint" grep -q '^Endpoint = vpn.example.net:51820$' "${WG_DIR}/clients/laptop.conf"
check "client config has a preshared key" grep -q '^PresharedKey = ' "${WG_DIR}/clients/laptop.conf"
check "client config is mode 600" test "$(stat -c %a "${WG_DIR}/clients/laptop.conf")" = "600"
check "peers are in wg0.conf" test "$(grep -c '^\[Peer\]' "${WG_DIR}/wg0.conf")" = "2"
check_fails "duplicate name is rejected" "${WGCTL}" add laptop
check_fails "bad name is rejected" "${WGCTL}" add 'bad name;rm'

# keys are consistent ------------------------------------------------------
client_priv="$(sed -n 's/^PrivateKey = //p' "${WG_DIR}/clients/laptop.conf")"
meta_pub="$(sed -n 's/^pubkey=//p' "${WG_DIR}/clients/laptop.meta")"
derived_pub="$(printf '%s' "${client_priv}" | wg pubkey)"
check "stored public key matches the private key" test "${derived_pub}" = "${meta_pub}"
server_pub_in_client="$(sed -n 's/^PublicKey = //p' "${WG_DIR}/clients/laptop.conf")"
check "client trusts the server public key" test "${server_pub_in_client}" = "$(cat "${WG_DIR}/server.pub")"

# bring-your-own key -------------------------------------------------------
own_pub="$(wg genkey | wg pubkey)"
check "add with --pubkey" "${WGCTL}" add byok --pubkey "${own_pub}"
check "byok config has a placeholder private key" grep -q 'PASTE_YOUR_PRIVATE_KEY_HERE' "${WG_DIR}/clients/byok.conf"
check_fails "invalid --pubkey is rejected" "${WGCTL}" add broken --pubkey 'not-a-key'

# print flag only writes the config to stdout ------------------------------
printed="$("${WGCTL}" add printed --print 2>/dev/null)"
check "--print emits the config on stdout" grep -q '^\[Interface\]$' <<<"${printed}"

# remove and reuse ---------------------------------------------------------
check "remove phone" "${WGCTL}" remove phone
check "phone config is gone" test ! -e "${WG_DIR}/clients/phone.conf"
check "phone block is gone from wg0.conf" bash -c "! grep -q 'client phone' '${WG_DIR}/wg0.conf'"
check "laptop block is still there" grep -q '# BEGIN client laptop' "${WG_DIR}/wg0.conf"
check "freed address is reused" "${WGCTL}" add tablet
check "tablet reuses .3" grep -q '^Address = 10.66.66.3/32$' "${WG_DIR}/clients/tablet.conf"
check_fails "remove of unknown client fails" "${WGCTL}" remove ghost

# list ---------------------------------------------------------------------
check "list shows laptop" bash -c "'${WGCTL}' list | grep -q '^laptop '"

echo
echo "passed: ${pass}  failed: ${fail}"
(( fail == 0 ))
