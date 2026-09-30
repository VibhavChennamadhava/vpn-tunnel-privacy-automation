#!/usr/bin/env bash
# Offline tests for automation/scripts/verify-vpn.sh.
# A tiny local web server plays the part of "what is my IP", so the test can
# simulate the address changing when a VPN comes up.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT}/automation/scripts/verify-vpn.sh"

command -v python3 >/dev/null || { echo "SKIP: python3 not installed"; exit 0; }
command -v curl >/dev/null || { echo "SKIP: curl not installed"; exit 0; }

TMP="$(mktemp -d)"
SERVER_PID=""
cleanup() {
  if [[ -n "${SERVER_PID}" ]]; then kill "${SERVER_PID}" 2>/dev/null || true; fi
  rm -rf "${TMP}"
}
trap cleanup EXIT

PORT_FILE="${TMP}/port"
cat > "${TMP}/server.py" <<'PY'
import http.server, pathlib, socketserver, sys
ip_file = pathlib.Path(sys.argv[1])
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = ip_file.read_text().encode()
        self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass
with socketserver.TCPServer(("127.0.0.1", 0), H) as s:
    pathlib.Path(sys.argv[2]).write_text(str(s.server_address[1]))
    s.serve_forever()
PY

echo "203.0.113.10" > "${TMP}/ip4"
python3 "${TMP}/server.py" "${TMP}/ip4" "${PORT_FILE}" &
SERVER_PID=$!
for _ in $(seq 1 50); do [[ -s "${PORT_FILE}" ]] && break; sleep 0.1; done
PORT="$(cat "${PORT_FILE}")"

export STATE_DIR="${TMP}/state"
export IP_ECHO_URLS="http://127.0.0.1:${PORT}/"
export IP6_ECHO_URLS="http://127.0.0.1:1/"          # nothing listens: simulates no IPv6
echo "203.0.113.53" > "${TMP}/resolver"
export DNS_PROBE_CMD="cat ${TMP}/resolver"

pass=0
fail=0
ok() { echo "ok   - $1"; pass=$((pass + 1)); }
bad() { echo "FAIL - $1"; fail=$((fail + 1)); }
has() { # description, pattern, file
  if grep -q -- "$2" "$3"; then ok "$1"; else bad "$1"; fi
}

# no baseline yet -> usage error (2)
set +e; "${SCRIPT}" check >/dev/null 2>&1; rc=$?; set -e
if (( rc == 2 )); then ok "check without a baseline exits 2"; else bad "check without a baseline exits 2 (got ${rc})"; fi

"${SCRIPT}" baseline >"${TMP}/baseline.out" 2>&1
has "baseline records the current IP" "203.0.113.10" "${TMP}/baseline.out"

# still on the real connection -> must FAIL
set +e; "${SCRIPT}" check >"${TMP}/c1.out" 2>&1; rc=$?; set -e
if (( rc == 1 )) && grep -q "NOT going through the VPN" "${TMP}/c1.out"; then ok "unchanged IP is reported as a failure"; else bad "unchanged IP is reported as a failure"; cat "${TMP}/c1.out"; fi

# VPN comes up: new IP, new resolver
echo "198.51.100.7" > "${TMP}/ip4"
echo "198.51.100.53" > "${TMP}/resolver"
set +e; "${SCRIPT}" check --expect 198.51.100.7 >"${TMP}/c2.out" 2>&1; rc=$?; set -e
if (( rc == 0 )); then ok "changed IP with matching --expect passes"; else bad "changed IP with matching --expect passes"; cat "${TMP}/c2.out"; fi
has "DNS resolver change is detected" "\[PASS\] DNS resolver" "${TMP}/c2.out"
has "absent IPv6 is not flagged" "\[PASS\] IPv6" "${TMP}/c2.out"

# wrong server
set +e; "${SCRIPT}" check --expect 192.0.2.99 >"${TMP}/c3.out" 2>&1; rc=$?; set -e
if (( rc == 1 )) && grep -q "expected 192.0.2.99" "${TMP}/c3.out"; then ok "wrong --expect is a failure"; else bad "wrong --expect is a failure"; fi

# DNS unchanged -> warning only
echo "203.0.113.53" > "${TMP}/resolver"
set +e; "${SCRIPT}" check >"${TMP}/c4.out" 2>&1; rc=$?; set -e
if (( rc == 0 )) && grep -q "\[WARN\] DNS resolver" "${TMP}/c4.out"; then ok "unchanged resolver is a warning, not a failure"; else bad "unchanged resolver is a warning, not a failure"; cat "${TMP}/c4.out"; fi

# markdown mode redacts addresses
echo "198.51.100.53" > "${TMP}/resolver"
"${SCRIPT}" check --markdown >"${TMP}/c5.out" 2>&1 || true
if grep -q '^| Result | Check | Detail |' "${TMP}/c5.out" && ! grep -qE '198\.51\.100\.7|203\.0\.113\.10' "${TMP}/c5.out"; then
  ok "--markdown prints a table with addresses masked"
else
  bad "--markdown prints a table with addresses masked"; cat "${TMP}/c5.out"
fi
has "masking keeps the first two octets" "198.51.x.x" "${TMP}/c5.out"

# --no-redact keeps them
"${SCRIPT}" check --markdown --no-redact >"${TMP}/c6.out" 2>&1 || true
has "--no-redact shows full addresses" "198.51.100.7" "${TMP}/c6.out"

# IPv6 leak detection: give the stub an IPv6-shaped answer that equals the baseline
echo "2001:db8::1" > "${TMP}/ip4"      # not valid IPv4, so fetch_ip(4) finds nothing
set +e; "${SCRIPT}" check >"${TMP}/c7.out" 2>&1; rc=$?; set -e
if (( rc == 1 )) && grep -q "could not be determined" "${TMP}/c7.out"; then ok "missing IPv4 while connected is a failure"; else bad "missing IPv4 while connected is a failure"; fi

echo
echo "passed: ${pass}  failed: ${fail}"
(( fail == 0 ))
