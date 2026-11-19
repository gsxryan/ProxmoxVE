#!/usr/bin/env bash
# Project NOMAD on Proxmox VE
# Upstream CT pattern: https://github.com/community-scripts/ProxmoxVE/blob/main/ct/ubuntu.sh
# Application:          https://github.com/Crosstalk-Solutions/project-nomad
#
# Creates an unprivileged Ubuntu 26.04 LXC (console mode "shell", so the
# Proxmox console is a root shell and not the tty1 login). Docker and
# Project NOMAD are installed afterwards by the engine's var_post_install
# hook, which uses pct exec on the host. Ubuntu 26.04 agetty otherwise
# sits at "login:" eating noVNC cursor replies (^[[24;80R) and the step
# after "Container customized" never continues.
#   https://docs.docker.com/engine/install/ubuntu/
#   https://raw.githubusercontent.com/Crosstalk-Solutions/project-nomad/refs/heads/main/install/install_nomad.sh
#
# Run on the Proxmox VE host (not inside a guest):
#   bash nomad.sh
#
# Defaults follow Project NOMAD's published minimum (2 vCPU, 4 GiB RAM) with
# 32 GiB disk so the management stack has room. Libraries and local AI want
# much more (about 32 GiB RAM and 250 GiB disk). Override before launch, e.g.:
#   var_cpu=8 var_ram=32768 var_disk=250 bash nomad.sh

# install/nomad-install.sh is what the engine runs with lxc-attach while it
# still owns the terminal. Keep that step to base OS setup. Docker and NOMAD
# run later from the host post-install hook.
_nomad_write_install_script() {
  local dest="$1"
  mkdir -p "$(dirname "$dest")"
  cat >"$dest" <<'EOF'
#!/usr/bin/env bash
# Base Ubuntu setup only. Docker and Project NOMAD are the host post-install hook.
# Copyright (c) 2021-2026 community-scripts ORG
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://ubuntu.com/

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors

# tty1 on Ubuntu 26.04 is agetty. It sends ESC[6n, Proxmox noVNC answers
# ^[[24;80R, and that answer is used as the login name, so the console
# never reaches a shell. TERM=linux stops the query; autologin skips the prompt.
if command -v systemctl >/dev/null 2>&1; then
  install -d /etc/systemd/system/container-getty@1.service.d \
    /etc/systemd/system/container-getty@2.service.d \
    /etc/systemd/system/console-getty.service.d
  for unit in container-getty@1 container-getty@2; do
    cat >"/etc/systemd/system/${unit}.service.d/override.conf" <<'UNIT'
[Service]
Environment=TERM=linux
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear --keep-baud tty%I 115200,38400,9600 linux
UNIT
  done
  cat >/etc/systemd/system/console-getty.service.d/override.conf <<'UNIT'
[Service]
Environment=TERM=linux
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear --keep-baud console 115200,38400,9600 linux
UNIT
  grep -q '^TERM=linux' /etc/environment 2>/dev/null || echo 'TERM=linux' >>/etc/environment
  systemctl daemon-reload 2>/dev/null || true
fi

setting_up_container
network_check
update_os

motd_ssh
customize
cleanup_lxc
EOF
  chmod 755 "$dest"
}

# Standalone guest script. No helper-script functions: pct exec runs it later.
_nomad_write_guest_script() {
  local dest="$1"
  cat >"$dest" <<'EOF'
#!/usr/bin/env bash
# Inside the Ubuntu 26.04 LXC. Docker first, then Project NOMAD.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
NOMAD_INSTALL_URL="https://raw.githubusercontent.com/Crosstalk-Solutions/project-nomad/refs/heads/main/install/install_nomad.sh"

echo "Installing prerequisites"
apt-get update
apt-get install -y sudo curl ca-certificates gnupg iproute2 pciutils

echo "Configuring root mount propagation"
prop="$(findmnt -no PROPAGATION --target / 2>/dev/null || true)"
case "$prop" in
shared* | slave*) ;;
*)
  mount --make-rshared /
  ;;
esac
cat >/etc/systemd/system/nomad-mount-propagation.service <<'UNIT'
[Unit]
Description=Shared root mount propagation for Project NOMAD
After=local-fs.target
Before=docker.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'prop=$(findmnt -no PROPAGATION --target / || true); case "$prop" in shared*|slave*) exit 0;; *) exec mount --make-rshared /;; esac'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
systemctl enable nomad-mount-propagation.service

echo "Installing Docker Engine"
for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
  apt-get remove -y "$pkg" >/dev/null 2>&1 || true
done
apt-get install -y ca-certificates curl
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
# shellcheck disable=SC1091
. /etc/os-release
cat >/etc/apt/sources.list.d/docker.sources <<DOCK
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME:-$VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
DOCK
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker

echo "Confirming Docker is running"
if ! systemctl is-active --quiet docker; then
  echo "Docker is installed but the service is not active. NOMAD will not be installed." >&2
  exit 1
fi
if ! docker info >/tmp/docker-info.log 2>&1; then
  echo "docker info failed. NOMAD will not be installed." >&2
  cat /tmp/docker-info.log >&2
  exit 1
fi
if ! docker compose version >/tmp/docker-compose.log 2>&1; then
  echo "Docker Compose v2 is not available. NOMAD will not be installed." >&2
  cat /tmp/docker-compose.log >&2
  exit 1
fi
if ! docker run --rm hello-world >/tmp/docker-hello.log 2>&1; then
  echo "Docker could not run a container (hello-world). NOMAD will not be installed." >&2
  cat /tmp/docker-hello.log >&2
  exit 1
fi
docker rmi hello-world >/dev/null 2>&1 || true
echo "Docker Engine and Compose are ready ($(docker compose version --short 2>/dev/null || docker compose version))"

echo "Deploying Project NOMAD"
curl -fsSL --retry 5 --retry-delay 2 "$NOMAD_INSTALL_URL" -o /tmp/install_nomad.sh
chmod 755 /tmp/install_nomad.sh
# Upstream asks twice (continue, then Apache-2.0 terms) and has no unattended flag.
printf 'y\ny\n' | bash /tmp/install_nomad.sh
rm -f /tmp/install_nomad.sh
echo "Deployed Project NOMAD"
EOF
  chmod 755 "$dest"
}

# Host hook. The engine runs this after the CT is up. pct exec does not use
# the guest console, so a login prompt cannot swallow the script.
_nomad_write_post_hook() {
  local dest="$1"
  local guest="$2"
  cat >"$dest" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ -z "\${CTID:-}" ]]; then
  echo "Post-install hook: CTID is not set" >&2
  exit 1
fi
say() {
  printf '%s\n' "\$*"
  printf '%s\n' "\$*" >/dev/tty 2>/dev/null || true
}
say "Installing Docker and Project NOMAD in CT \${CTID} with pct exec"
pct push "\${CTID}" "${guest}" /root/nomad-guest-setup.sh
set -o pipefail
if [[ -e /dev/tty ]]; then
  pct exec "\${CTID}" -- bash /root/nomad-guest-setup.sh | tee /dev/tty
else
  pct exec "\${CTID}" -- bash /root/nomad-guest-setup.sh
fi
pct exec "\${CTID}" -- rm -f /root/nomad-guest-setup.sh
say "Project NOMAD is ready at http://\${IP:-<container-ip>}:8080"
EOF
  chmod 755 "$dest"
}

# The engine runs the guest setup with `lxc-attach` on the host terminal.
# On Ubuntu 26.04 that attach sits on tty1, which is stuck at the login in
# the screenshot. Fix getty first, then attach with stdin closed so
# cursor-position replies cannot be typed in as a username.
_nomad_write_attach_wrapper() {
  local dest="$1"
  mkdir -p "$(dirname "$dest")"
  cat >"$dest" <<'EOF'
#!/bin/bash
real=/usr/bin/lxc-attach
[[ -x "$real" ]] || exit 127
ctid=""
prev=""
for a in "$@"; do
  [[ "$prev" == "-n" ]] && ctid="$a"
  prev="$a"
done
cmd=()
seen=0
for a in "$@"; do
  if [[ $seen -eq 1 ]]; then
    cmd+=("$a")
  elif [[ "$a" == "--" ]]; then
    seen=1
  fi
done
if [[ -z "$ctid" || ${#cmd[@]} -eq 0 ]]; then
  exec "$real" "$@"
fi
log="/tmp/nomad-ct-${ctid}.log"
note() {
  printf '%s\n' "$*" >>"$log"
  printf '%s\n' "$*" >/dev/tty 2>/dev/null || printf '%s\n' "$*"
}
note ""
note "Container ${ctid}: this is the step after \"Container customized\"."
note "Live log (other shell): tail -f ${log}"
flag="${TMPDIR:-/tmp}/nomad-console-fixed-${ctid}"
if [[ ! -f "$flag" ]]; then
  note "Container ${ctid}: writing the tty1 console fix."
  if "$real" -n "$ctid" -- bash -s >>"$log" 2>&1 <<'FIX'; then
set +e
if command -v systemctl >/dev/null 2>&1; then
  install -d /etc/systemd/system/container-getty@1.service.d \
    /etc/systemd/system/container-getty@2.service.d \
    /etc/systemd/system/console-getty.service.d
  for unit in container-getty@1 container-getty@2; do
    cat >"/etc/systemd/system/${unit}.service.d/override.conf" <<'UNIT'
[Service]
Environment=TERM=linux
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear --keep-baud tty%I 115200,38400,9600 linux
UNIT
  done
  cat >/etc/systemd/system/console-getty.service.d/override.conf <<'UNIT'
[Service]
Environment=TERM=linux
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear --keep-baud console 115200,38400,9600 linux
UNIT
  grep -q '^TERM=linux' /etc/environment 2>/dev/null || echo 'TERM=linux' >>/etc/environment
  systemctl daemon-reload 2>/dev/null || true
fi
FIX
    touch "$flag" 2>/dev/null || true
  else
    note "Container ${ctid}: console fix did not apply; continuing."
  fi
fi
note "Container ${ctid}: base setup output follows."
session="$(printf '%s\n' "${cmd[@]}" | sed -n 's/.*\.install-\([0-9A-Fa-f][0-9A-Fa-f]*\)\.pid.*/\1/p' | head -n 1)"
wait_ready() {
  local i
  for i in $(seq 1 60); do
    if ! pct status "$ctid" 2>/dev/null | grep -q 'status: running'; then
      note "Container ${ctid} is not running (reboot?). Starting it (${i}/60)..."
      pct start "$ctid" >/dev/null 2>&1 || true
      sleep 5
      continue
    fi
    if "$real" -n "$ctid" -- true </dev/null >/dev/null 2>&1; then
      return 0
    fi
    note "Container ${ctid} is up but not accepting commands yet (${i}/60)..."
    sleep 5
  done
  note "Container ${ctid} did not accept commands within 5 minutes."
  return 1
}
run_once() {
  set -o pipefail
  "$real" -n "$ctid" -- "${cmd[@]}" </dev/null 2>&1 | tee -a "$log"
  return "${PIPESTATUS[0]}"
}
if [[ -z "$session" ]]; then
  run_once
  exit $?
fi
rc=1
for try in 1 2 3; do
  if ! wait_ready; then
    rc=1
    continue
  fi
  note "Install attempt ${try}/3 in container ${ctid}."
  note "In-container log: pct exec ${ctid} -- tail -f /root/.install-${session}.log"
  "$real" -n "$ctid" -- bash -c "touch /root/.install-${session}.log; echo \"[\$(date '+%Y-%m-%d %H:%M:%S')] install attempt ${try}\" >> /root/.install-${session}.log" </dev/null >/dev/null 2>&1 || true
  run_once
  rc=$?
  bytes="$("$real" -n "$ctid" -- bash -c "wc -c < /root/.install-${session}.log 2>/dev/null || echo 0" </dev/null 2>/dev/null | tr -d '[:space:]')"
  [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
  if [[ $rc -eq 0 ]]; then
    exit 0
  fi
  running="$(pct status "$ctid" 2>/dev/null || true)"
  if [[ "$running" == "status: running" && "$bytes" -gt 150 ]]; then
    note "Install exited ${rc} after writing ${bytes} bytes. Not retrying a real failure."
    exit "$rc"
  fi
  note "No install log yet (exit ${rc}, ${bytes} bytes). The container may still be rebooting. Retrying."
  sleep 10
done
exit "$rc"
EOF
  chmod 755 "$dest"
}

_nomad_self="${BASH_SOURCE[0]:-}"
_nomad_root=""
if [[ -n "$_nomad_self" && -f "$_nomad_self" ]]; then
  _dir="$(cd "$(dirname "$_nomad_self")" >/dev/null 2>&1 && pwd || true)"
  while [[ -n "${_dir:-}" && "$_dir" != "/" ]]; do
    if [[ -d "${_dir}/ct" && -d "${_dir}/install" ]]; then
      _nomad_root="$_dir"
      break
    fi
    _dir="$(dirname "$_dir")"
  done
fi
if [[ -z "$_nomad_root" ]]; then
  _nomad_root="$(mktemp -d "${TMPDIR:-/tmp}/nomad-pve.XXXXXX")"
  mkdir -p "${_nomad_root}/ct" "${_nomad_root}/install"
  export COMMUNITY_SCRIPTS_ROOT="${_nomad_root}"
fi
_nomad_write_install_script "${_nomad_root}/install/nomad-install.sh"
_nomad_stage="$(mktemp -d "${TMPDIR:-/tmp}/nomad-post.XXXXXX")"
_nomad_write_guest_script "${_nomad_stage}/nomad-guest-setup.sh"
_nomad_write_post_hook "${_nomad_stage}/nomad-post-install.sh" "${_nomad_stage}/nomad-guest-setup.sh"
_nomad_write_attach_wrapper "${_nomad_stage}/bin/lxc-attach"
unset _nomad_self _dir

# Re-run Docker + Project NOMAD inside a container that already exists.
# The create step can fail after "Container customized" when the guest reboots
# and the first attach finds no install log. Example:
#   NOMAD_CTID=103 bash nomad.sh
if [[ -n "${NOMAD_CTID:-}" ]]; then
  echo "Retrying Project NOMAD install in existing container ${NOMAD_CTID}"
  echo "Live log: tail -f /tmp/nomad-ct-${NOMAD_CTID}.log"
  ready=0
  for i in $(seq 1 60); do
    if ! pct status "$NOMAD_CTID" 2>/dev/null | grep -q 'status: running'; then
      echo "Container ${NOMAD_CTID} is not running (reboot?). Starting it (${i}/60)..."
      pct start "$NOMAD_CTID" >/dev/null 2>&1 || true
      sleep 5
      continue
    fi
    if pct exec "$NOMAD_CTID" -- true >/dev/null 2>&1; then
      ready=1
      break
    fi
    echo "Container ${NOMAD_CTID} is up but not accepting commands yet (${i}/60)..."
    sleep 5
  done
  if [[ "$ready" -ne 1 ]]; then
    echo "Container ${NOMAD_CTID} did not accept commands within 5 minutes." >&2
    exit 1
  fi
  pct push "$NOMAD_CTID" "${_nomad_stage}/nomad-guest-setup.sh" /root/nomad-guest-setup.sh
  set -o pipefail
  pct exec "$NOMAD_CTID" -- bash /root/nomad-guest-setup.sh 2>&1 | tee -a "/tmp/nomad-ct-${NOMAD_CTID}.log"
  rc=${PIPESTATUS[0]}
  pct exec "$NOMAD_CTID" -- rm -f /root/nomad-guest-setup.sh >/dev/null 2>&1 || true
  exit "$rc"
fi

_cs_boot="${COMMUNITY_SCRIPTS_CORE_DIR:-$(dirname "${BASH_SOURCE[0]}")/../../core}/core/build.func"
source "$_cs_boot" 2>/dev/null || source <(curl -fsSL "${COMMUNITY_SCRIPTS_CORE_URL:-https://raw.githubusercontent.com/community-scripts/core/main}/core/build.func")
# Copyright (c) 2021-2026 tteck
# Author: tteck (tteckster)
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/Crosstalk-Solutions/project-nomad

APP="Nomad"
var_tags="${var_tags:-offline;education;docker}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-4096}"
var_disk="${var_disk:-32}"
var_os="${var_os:-ubuntu}"
var_version="${var_version:-26.04}"
# Upstream installer supports x86_64 only (ARM64 is incomplete).
var_arm64="${var_arm64:-no}"
var_unprivileged="${var_unprivileged:-1}"
var_gpu="${var_gpu:-yes}"

header_info "$APP"
variables
# APP "Nomad" already maps to install/nomad-install.sh; keep it explicit.
var_install="nomad-install"
export var_install
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources
  if [[ ! -f /opt/project-nomad/compose.yml ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi
  msg_info "Updating Ubuntu"
  apt_update_safe
  $STD apt -y upgrade
  msg_ok "Updated Ubuntu"
  if [[ -x /opt/project-nomad/update_nomad.sh ]]; then
    msg_info "Updating Project NOMAD"
    # Upstream update script asks for a single confirmation and has no flag.
    if ! printf 'y\n' | bash /opt/project-nomad/update_nomad.sh; then
      msg_error "Project NOMAD update failed"
      exit 1
    fi
    msg_ok "Updated Project NOMAD"
  else
    msg_warn "No /opt/project-nomad/update_nomad.sh — base OS was updated only"
  fi
  msg_ok "Updated successfully!"
  exit
}

start
# shell: Proxmox opens a root shell instead of the tty1 login that is eating
# cursor-position replies. Set after the wizard so Default cannot clear it.
CT_CMODE=shell
export CT_CMODE
VERBOSE=yes
var_verbose=yes
export VERBOSE var_verbose
var_post_install="${_nomad_stage}/nomad-post-install.sh"
export var_post_install
export PATH="${_nomad_stage}/bin:${PATH}"
build_container
description

msg_ok "Completed successfully!\n"
echo -e "${CREATING}${GN}Project NOMAD setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW}Access it using the following URL:${CL}"
echo -e "${GATEWAY}${BGN}http://${IP}:8080${CL}"
echo -e "${INFO}${YW}Container logs (Dozzle):${CL}"
echo -e "${GATEWAY}${BGN}http://${IP}:9999${CL}"
