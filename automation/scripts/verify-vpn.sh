#!/usr/bin/env bash
# verify-vpn.sh: prove that your traffic really leaves through the VPN.
#
# Workflow:
#   1. Before connecting:   verify-vpn.sh baseline
#   2. Connect the VPN (or start the SSH tunnel).
#   3. After connecting:    verify-vpn.sh check [--expect SERVER_IP]
#
# Usage:
#   verify-vpn.sh baseline
#   verify-vpn.sh check [--expect IP] [--markdown] [--no-redact]
#   verify-vpn.sh show
#
# Checking an SSH SOCKS tunnel instead of a device-wide VPN: take the baseline
# without any proxy, then run the check with the proxy set:
#   VERIFY_PROXY=socks5h://127.0.0.1:1080 verify-vpn.sh check --expect SERVER_IP
#
# What is checked:
#   * your public IPv4 changed from the baseline (and equals --expect, if given)
#   * your real IPv6 address is not leaking
#   * DNS lookups no longer go through the resolver you used in the baseline
#   * a tunnel interface exists (informational)
#
# Environment:
#   STATE_DIR        where the baseline is kept (default ~/.cache/vpn-verify)
#   IP_ECHO_URLS     space separated services that return your IPv4 as plain text
#   IP6_ECHO_URLS    same, for IPv6
#   DNS_PROBE_CMD    command that prints the resolver address seen by the internet
#   VERIFY_PROXY     proxy URL for the lookups, for example socks5h://127.0.0.1:1080
#
# Exit status: 0 no failures, 1 at least one failure, 2 usage error or no baseline.

set -euo pipefail

STATE_DIR="${STATE_DIR:-${XDG_CACHE_HOME:-${HOME}/.cache}/vpn-verify}"
IP_ECHO_URLS="${IP_ECHO_URLS:-https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com}"
IP6_ECHO_URLS="${IP6_ECHO_URLS:-https://api6.ipify.org https://ifconfig.me/ip}"
DNS_PROBE_CMD="${DNS_PROBE_CMD:-dig +short +time=3 +tries=1 whoami.akamai.net}"
VERIFY_PROXY="${VERIFY_PROXY:-}"
BASELINE_FILE="${STATE_DIR}/baseline.env"

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

is_ipv4() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
is_ipv6() { [[ "$1" == *:* && "$1" =~ ^[0-9A-Fa-f:]+$ ]]; }

fetch_ip() {
  local family="$1" urls="$2" url ip proxy=()
  [[ -n "${VERIFY_PROXY}" ]] && proxy=(--proxy "${VERIFY_PROXY}")
  for url in ${urls}; do
    ip="$(env -u NO_PROXY -u no_proxy curl "-${family}" -fsS --max-time 6 "${proxy[@]}" "${url}" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ "${family}" == "4" ]] && is_ipv4 "${ip}"; then printf '%s' "${ip}"; return 0; fi
    if [[ "${family}" == "6" ]] && is_ipv6 "${ip}"; then printf '%s' "${ip}"; return 0; fi
  done
  return 0
}

probe_resolver() {
  [[ -n "${VERIFY_PROXY}" ]] && return 0
  local first="${DNS_PROBE_CMD%% *}"
  command -v "${first}" >/dev/null 2>&1 || return 0
  # shellcheck disable=SC2086
  ${DNS_PROBE_CMD} 2>/dev/null | tail -n 1 | tr -d '[:space:]' || true
}

tunnel_interfaces() {
  command -v ip >/dev/null 2>&1 || return 0
  { ip -o link show type wireguard 2>/dev/null; ip -o link show type tun 2>/dev/null; } |
    awk -F': ' '{print $2}' | cut -d@ -f1 | paste -sd, - || true
}

snapshot() {
  IP4="$(fetch_ip 4 "${IP_ECHO_URLS}")"
  IP6="$(fetch_ip 6 "${IP6_ECHO_URLS}")"
  RESOLVER="$(probe_resolver)"
}

cmd_baseline() {
  [[ -z "${VERIFY_PROXY}" ]] || echo "warning: VERIFY_PROXY is set, the baseline should be taken without a proxy" >&2
  snapshot
  [[ -n "${IP4}" ]] || { echo "error: could not determine your public IPv4" >&2; exit 2; }
  mkdir -p "${STATE_DIR}"
  umask 077
  {
    printf 'BASE_IP4=%s\n' "${IP4}"
    printf 'BASE_IP6=%s\n' "${IP6}"
    printf 'BASE_RESOLVER=%s\n' "${RESOLVER}"
    printf 'BASE_TIME=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "${BASELINE_FILE}"
  echo "baseline saved to ${BASELINE_FILE}"
  echo "  ipv4:     ${IP4}"
  echo "  ipv6:     ${IP6:-none}"
  echo "  resolver: ${RESOLVER:-unknown}"
}

cmd_show() {
  [[ -f "${BASELINE_FILE}" ]] || { echo "no baseline recorded yet" >&2; exit 2; }
  cat "${BASELINE_FILE}"
}

mask() {
  local v="$1"
  if (( REDACT == 0 )) || [[ -z "${v}" ]]; then printf '%s' "${v}"; return; fi
  if [[ "${v}" == *:* ]]; then
    awk -F: '{printf "%s:%s::x", $1, $2}' <<<"${v}"
  else
    awk -F. '{printf "%s.%s.x.x", $1, $2}' <<<"${v}"
  fi
}

cmd_check() {
  local expect="" markdown=0
  REDACT=0
  while (( $# )); do
    case "$1" in
      --expect) expect="${2:-}"; shift 2 ;;
      --markdown) markdown=1; REDACT=1; shift ;;
      --no-redact) REDACT=0; shift ;;
      *) usage ;;
    esac
  done
  [[ -f "${BASELINE_FILE}" ]] || { echo "error: no baseline, run 'verify-vpn.sh baseline' before connecting" >&2; exit 2; }
  # shellcheck disable=SC1090
  source "${BASELINE_FILE}"
  snapshot

  local failures=0 rows=()
  add() { # status, name, detail
    printf '[%s] %s: %s\n' "$1" "$2" "$3"
    rows+=("| $1 | $2 | $3 |")
    if [[ "$1" == "FAIL" ]]; then failures=$((failures + 1)); fi
  }

  # shellcheck disable=SC2153  # BASE_* variables come from the sourced baseline file
  if [[ -z "${IP4}" ]]; then
    add FAIL "Public IPv4" "could not be determined (is the tunnel up?)"
  elif [[ "${IP4}" == "${BASE_IP4}" ]]; then
    add FAIL "Public IPv4" "unchanged at $(mask "${IP4}"), traffic is NOT going through the VPN"
  else
    add PASS "Public IPv4" "$(mask "${BASE_IP4}") -> $(mask "${IP4}")"
  fi

  if [[ -n "${expect}" ]]; then
    if [[ "${IP4}" == "${expect}" ]]; then
      add PASS "Exit matches server" "egress address equals the expected server $(mask "${expect}")"
    else
      add FAIL "Exit matches server" "expected $(mask "${expect}"), saw $(mask "${IP4:-nothing}")"
    fi
  fi

  if [[ -z "${BASE_IP6}" && -z "${IP6}" ]]; then
    add PASS "IPv6" "no IPv6 egress before or after, nothing to leak"
  elif [[ -n "${BASE_IP6}" && "${IP6}" == "${BASE_IP6}" ]]; then
    add FAIL "IPv6" "your real IPv6 address $(mask "${IP6}") is still visible, it is leaking around the tunnel"
  elif [[ -z "${IP6}" ]]; then
    add PASS "IPv6" "no IPv6 egress while connected (blocked or blackholed)"
  else
    add PASS "IPv6" "IPv6 egress is $(mask "${IP6}"), different from your real address"
  fi

  if [[ -n "${VERIFY_PROXY}" ]]; then
    add SKIP "DNS resolver" "not testable through a proxy, enable remote DNS in the browser instead"
  elif [[ -z "${RESOLVER}" ]]; then
    add SKIP "DNS resolver" "probe unavailable (install dig, or set DNS_PROBE_CMD)"
  elif [[ -z "${BASE_RESOLVER}" ]]; then
    add WARN "DNS resolver" "now $(mask "${RESOLVER}") but no baseline was recorded to compare"
  elif [[ "${RESOLVER}" == "${BASE_RESOLVER}" ]]; then
    add WARN "DNS resolver" "unchanged at $(mask "${RESOLVER}"); expected if you already used the same public DNS before connecting, otherwise DNS is leaking"
  else
    add PASS "DNS resolver" "$(mask "${BASE_RESOLVER}") -> $(mask "${RESOLVER}")"
  fi

  local ifaces
  ifaces="$(tunnel_interfaces)"
  if [[ -n "${VERIFY_PROXY}" ]]; then
    add INFO "Tunnel interface" "proxy mode, using ${VERIFY_PROXY}"
  elif [[ -n "${ifaces}" ]]; then
    add INFO "Tunnel interface" "${ifaces}"
  else
    add INFO "Tunnel interface" "none detected"
  fi

  if (( markdown )); then
    echo
    echo "| Result | Check | Detail |"
    echo "|---|---|---|"
    printf '%s\n' "${rows[@]}"
  fi

  if (( failures > 0 )); then
    echo "RESULT: ${failures} check(s) failed" >&2
    exit 1
  fi
  echo "RESULT: all checks passed"
}

main() {
  local sub="${1:-}"; [[ -n "${sub}" ]] || usage; shift
  case "${sub}" in
    baseline) cmd_baseline "$@" ;;
    check) cmd_check "$@" ;;
    show) cmd_show "$@" ;;
    *) usage ;;
  esac
}

main "$@"
