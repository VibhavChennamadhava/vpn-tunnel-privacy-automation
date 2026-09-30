#!/usr/bin/env bash
# Renders the cloud-init module offline with OpenTofu/Terraform and validates the result:
#   * the output is valid YAML with the expected structure
#   * embedded files decode and match the sources
#   * the nftables ruleset passes `nft -c` (syntax check) when nft is usable
#   * the embedded wgctl passes shellcheck
#   * cloud-init's own schema validator accepts the document (if installed)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODULE="${ROOT}/automation/terraform/modules/cloud-init"

TF="${TF:-}"
if [[ -z "${TF}" ]]; then
  for c in tofu terraform /tmp/tofu/tofu; do
    if command -v "${c}" >/dev/null 2>&1; then TF="${c}"; break; fi
  done
fi
[[ -n "${TF}" ]] || { echo "SKIP: neither tofu nor terraform found"; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
cp -r "${MODULE}/." "${TMP}/"

cat > "${TMP}/test.auto.tfvars" <<'EOF'
wg_port         = 51820
vpn_cidr        = "10.66.66.0/24"
client_dns      = ["1.1.1.1", "1.0.0.1"]
initial_clients = ["laptop", "phone"]
EOF

cd "${TMP}"
"${TF}" init -backend=false -input=false >/dev/null
"${TF}" apply -auto-approve -input=false >/dev/null
"${TF}" output -raw user_data > "${TMP}/user-data.yaml"

python3 - "${TMP}" "${MODULE}" <<'PY'
import base64, sys, pathlib
try:
    import yaml
except ImportError:
    print("SKIP: PyYAML not installed"); sys.exit(0)

tmp, module = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
raw = (tmp / "user-data.yaml").read_text()
assert raw.startswith("#cloud-config\n"), "missing #cloud-config header"
doc = yaml.safe_load(raw)

def ok(msg): print("ok   -", msg)

assert doc["package_update"] is True; ok("package_update enabled")
for pkg in ("wireguard", "nftables", "fail2ban", "unattended-upgrades"):
    assert pkg in doc["packages"], pkg
ok("required packages present")

files = {f["path"]: f for f in doc["write_files"]}
for path in ("/etc/nftables.conf", "/usr/local/sbin/wgctl",
             "/etc/sysctl.d/99-wireguard.conf", "/etc/ssh/sshd_config.d/00-hardening.conf"):
    assert path in files, path
ok("all write_files entries present")

wgctl = base64.b64decode(files["/usr/local/sbin/wgctl"]["content"]).decode()
assert wgctl == (module / "files" / "wgctl").read_text(); ok("embedded wgctl matches the source file")
assert files["/usr/local/sbin/wgctl"]["permissions"] == "0750"; ok("wgctl is not world readable")

nft = base64.b64decode(files["/etc/nftables.conf"]["content"]).decode()
assert "udp dport 51820 accept" in nft; ok("nftables opens the WireGuard port")
assert "ip saddr 10.66.66.0/24 oifname != \"wg0\" masquerade" in nft; ok("nftables masquerades the VPN network")
assert "policy drop" in nft; ok("nftables default policy is drop")
assert "169.254.0.0/16" in nft; ok("nftables blocks the metadata range for clients")
assert "${" not in nft, "unrendered template variable"; ok("no unrendered template variables")
(tmp / "nftables.conf").write_text(nft)
(tmp / "wgctl").write_text(wgctl)

run = doc["runcmd"]
flat = [" ".join(c) if isinstance(c, list) else c for c in run]
assert any("wgctl init --port 51820 --cidr 10.66.66.0/24" in c for c in flat); ok("runcmd initialises the server")
assert any(c.endswith("wgctl add laptop") for c in flat); ok("runcmd creates the laptop client")
assert any(c.endswith("wgctl add phone") for c in flat); ok("runcmd creates the phone client")
init_idx = next(i for i, c in enumerate(flat) if "wgctl init" in c)
add_idx = next(i for i, c in enumerate(flat) if "wgctl add" in c)
assert init_idx < add_idx; ok("init runs before any client is added")
fw_idx = next(i for i, c in enumerate(flat) if c == "nft -f /etc/nftables.conf")
assert fw_idx < init_idx; ok("firewall is loaded before the VPN starts")
assert flat[-1] == "touch /var/lib/vpn-bootstrap.done"; ok("completion marker is written last")
PY

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -s bash "${TMP}/wgctl" && echo "ok   - shellcheck passes on the embedded wgctl"
fi

if command -v nft >/dev/null 2>&1; then
  if nft -c -f "${TMP}/nftables.conf" 2>"${TMP}/nft.err"; then
    echo "ok   - nft -c accepts the rendered ruleset"
  elif grep -qiE 'operation not permitted|permission denied|netlink' "${TMP}/nft.err"; then
    echo "SKIP - nft cannot run here (no netlink access): $(head -1 "${TMP}/nft.err")"
  else
    echo "FAIL - nft rejected the ruleset:"; cat "${TMP}/nft.err"; exit 1
  fi
fi

if command -v cloud-init >/dev/null 2>&1; then
  if cloud-init schema -c "${TMP}/user-data.yaml" >"${TMP}/ci.out" 2>&1; then
    echo "ok   - cloud-init schema validation passed"
  else
    echo "FAIL - cloud-init schema validation:"; cat "${TMP}/ci.out"; exit 1
  fi
else
  echo "SKIP - cloud-init not installed, schema validation not run"
fi

echo "render test finished"
