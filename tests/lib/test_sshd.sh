#!/usr/bin/env bash
# Helper: start a throwaway sshd on 127.0.0.1 for the current user.
# Source this file, then call start_test_sshd "<tmpdir>".
# Sets SSH_PORT, SSH_KEY and SSHD_PID. Returns 1 if sshd is unavailable.
# shellcheck disable=SC2034  # the variables are consumed by the sourcing script

free_port() {
  python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

start_test_sshd() {
  local dir="$1" sshd_bin
  sshd_bin="$(command -v sshd || true)"
  [[ -z "${sshd_bin}" && -x /usr/sbin/sshd ]] && sshd_bin=/usr/sbin/sshd
  [[ -n "${sshd_bin}" ]] || return 1
  command -v ssh-keygen >/dev/null 2>&1 || return 1

  SSH_PORT="$(free_port)"
  SSH_KEY="${dir}/id_test"
  ssh-keygen -q -t ed25519 -N '' -f "${SSH_KEY}"
  ssh-keygen -q -t ed25519 -N '' -f "${dir}/host_key"
  cp "${SSH_KEY}.pub" "${dir}/authorized_keys"
  chmod 600 "${dir}/authorized_keys"

  cat > "${dir}/sshd_config" <<EOF
Port ${SSH_PORT}
ListenAddress 127.0.0.1
HostKey ${dir}/host_key
PidFile ${dir}/sshd.pid
AuthorizedKeysFile ${dir}/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitRootLogin yes
UsePAM no
StrictModes no
AllowTcpForwarding yes
LogLevel ERROR
EOF

  mkdir -p /run/sshd 2>/dev/null || true
  "${sshd_bin}" -D -f "${dir}/sshd_config" -e 2>"${dir}/sshd.log" &
  SSHD_PID=$!

  local _
  for _ in $(seq 1 50); do
    if (echo > "/dev/tcp/127.0.0.1/${SSH_PORT}") 2>/dev/null; then return 0; fi
    sleep 0.1
  done
  echo "sshd did not start:" >&2
  cat "${dir}/sshd.log" >&2
  return 1
}
