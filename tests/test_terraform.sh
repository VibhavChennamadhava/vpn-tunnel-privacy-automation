#!/usr/bin/env bash
# Static checks for automation/terraform:
#   * formatting
#   * `validate` against the real Oracle provider schema
#   * input validation rules reject unsafe values (checked with `plan`, which fails
#     on bad variables before it ever needs cloud credentials)
#
# No cloud credentials are needed and nothing is created.
# Set TF_CLI_CONFIG_FILE if you need a provider mirror (for example in a sandbox).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${ROOT}/automation/terraform"

TF="${TF:-}"
if [[ -z "${TF}" ]]; then
  for c in tofu terraform /tmp/tofu/tofu; do
    if command -v "${c}" >/dev/null 2>&1; then TF="${c}"; break; fi
  done
fi
[[ -n "${TF}" ]] || { echo "SKIP: neither tofu nor terraform found"; exit 0; }

pass=0
fail=0
ok() { echo "ok   - $1"; pass=$((pass + 1)); }
bad() { echo "FAIL - $1"; fail=$((fail + 1)); }

if "${TF}" fmt -check -recursive "${SRC}" >/dev/null 2>&1; then ok "terraform fmt is clean"; else bad "terraform fmt found unformatted files"; fi

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
cp -r "${SRC}/." "${TMP}/"
cd "${TMP}"

if ! "${TF}" init -backend=false -input=false -no-color >"${TMP}/init.log" 2>&1; then
  echo "SKIP: could not download providers (offline?). Remaining checks need them."
  tail -3 "${TMP}/init.log"
  echo "passed: ${pass}  failed: ${fail}"
  (( fail == 0 ))
  exit $?
fi
ok "init succeeded"

if "${TF}" validate -no-color >"${TMP}/validate.log" 2>&1; then ok "validate passes against the provider schema"; else bad "validate failed"; cat "${TMP}/validate.log"; fi

base=(-input=false -no-color
  -var compartment_ocid=ocid1.compartment.oc1..example
  -var "ssh_public_key=ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAItest test@example"
  -var admin_cidr=203.0.113.7/32)

expect_rejected() {
  local desc="$1" needle="$2"; shift 2
  local out
  out="$("${TF}" plan "${base[@]}" "$@" 2>&1 || true)"
  if grep -q "Invalid value for variable" <<<"${out}" && grep -q "${needle}" <<<"${out}"; then ok "${desc}"; else bad "${desc}"; echo "${out}" | head -8; fi
}

expect_rejected "SSH from 0.0.0.0/0 is rejected" "must not be 0.0.0.0/0" -var admin_cidr=0.0.0.0/0
expect_rejected "a malformed admin CIDR is rejected" "valid CIDR" -var admin_cidr=not-a-cidr
expect_rejected "a non-SSH-key string is rejected" "OpenSSH public key" -var ssh_public_key=garbage
expect_rejected "a /16 VPN network is rejected" "must be a /24" -var vpn_cidr=10.66.0.0/16
expect_rejected "a client name with a space is rejected" "Client names" -var 'initial_clients=["ok","bad name"]'

# With valid inputs the only failure allowed is missing cloud credentials.
out="$("${TF}" plan "${base[@]}" 2>&1 || true)"
if grep -q "Invalid value for variable" <<<"${out}"; then bad "valid inputs were rejected"; else ok "valid inputs pass variable validation"; fi

echo
echo "passed: ${pass}  failed: ${fail}"
(( fail == 0 ))
