#!/usr/bin/env bash
# Project NOMAD on Proxmox VE
# Upstream CT pattern: https://github.com/community-scripts/ProxmoxVE/blob/main/ct/ubuntu.sh
# Application:          https://github.com/Crosstalk-Solutions/project-nomad
#
# Creates an unprivileged Ubuntu 26.04 LXC (nesting + keyctl, so Docker works),
# installs Docker Engine from Docker's Ubuntu apt repository, and only then
# deploys Project NOMAD:
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

# The engine loads install/${var_install}.sh from a scripts root that contains
# both ct/ and install/. This file carries that installer with it, so a single
# download still deploys NOMAD.
_nomad_write_install_script() {
  local dest="$1"
  mkdir -p "$(dirname "$dest")"
  cat >"$dest" <<'EOF'
#!/usr/bin/env bash
# Runs inside the Ubuntu 26.04 LXC. Deploy Project NOMAD non-interactively.
# Copyright (c) 2021-2026 community-scripts ORG
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/Crosstalk-Solutions/project-nomad

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

NOMAD_INSTALL_URL="https://raw.githubusercontent.com/Crosstalk-Solutions/project-nomad/refs/heads/main/install/install_nomad.sh"

msg_info "Installing Project NOMAD prerequisites"
$STD apt-get install -y sudo curl ca-certificates gnupg iproute2 pciutils
msg_ok "Installed prerequisites"

# disk-collector bind-mounts / with rslave. The installer aborts unless /
# propagation is shared or slave, which a fresh LXC root usually is not.
msg_info "Configuring root mount propagation"
prop="$(findmnt -no PROPAGATION --target / 2>/dev/null || true)"
case "$prop" in
shared* | slave*) ;;
*)
  if ! mount --make-rshared /; then
    msg_error "Could not set shared mount propagation on /. Project NOMAD requires it."
    exit 1
  fi
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
$STD systemctl enable nomad-mount-propagation.service
msg_ok "Root mount propagation is shared"

# Official Engine install for Ubuntu, including 26.04 (Resolute). Done before
# the NOMAD installer so that script finds Docker + Compose and does not fall
# through to https://get.docker.com.
msg_info "Installing Docker Engine"
for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
  apt-get remove -y "$pkg" >/dev/null 2>&1 || true
done
$STD apt-get install -y ca-certificates curl
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
. /etc/os-release
cat >/etc/apt/sources.list.d/docker.sources <<DOCK
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME:-$VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
DOCK
$STD apt-get update
$STD apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
$STD systemctl enable --now docker
msg_ok "Installed Docker Engine"

msg_info "Confirming Docker is running"
if ! systemctl is-active --quiet docker; then
  msg_error "Docker is installed but the service is not active. NOMAD will not be installed."
  exit 1
fi
if ! docker info >/tmp/docker-info.log 2>&1; then
  msg_error "docker info failed. NOMAD will not be installed."
  cat /tmp/docker-info.log
  exit 1
fi
if ! docker compose version >/tmp/docker-compose.log 2>&1; then
  msg_error "Docker Compose v2 is not available. NOMAD will not be installed."
  cat /tmp/docker-compose.log
  exit 1
fi
if ! docker run --rm hello-world >/tmp/docker-hello.log 2>&1; then
  msg_error "Docker could not run a container (hello-world). NOMAD will not be installed."
  cat /tmp/docker-hello.log
  exit 1
fi
docker rmi hello-world >/dev/null 2>&1 || true
msg_ok "Docker Engine and Compose are ready ($(docker compose version --short 2>/dev/null || docker compose version))"

msg_info "Deploying Project NOMAD"
curl -fsSL --retry 5 --retry-delay 2 "$NOMAD_INSTALL_URL" -o /tmp/install_nomad.sh
chmod 755 /tmp/install_nomad.sh
# Upstream asks twice (continue, then Apache-2.0 terms) and has no unattended flag.
if ! printf 'y\ny\n' | bash /tmp/install_nomad.sh; then
  msg_error "Project NOMAD installer failed"
  exit 1
fi
rm -f /tmp/install_nomad.sh
msg_ok "Deployed Project NOMAD"

motd_ssh
customize
cleanup_lxc
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
unset _nomad_self _nomad_root _dir

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
build_container
description

msg_ok "Completed successfully!\n"
echo -e "${CREATING}${GN}Project NOMAD setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW}Access it using the following URL:${CL}"
echo -e "${GATEWAY}${BGN}http://${IP}:8080${CL}"
echo -e "${INFO}${YW}Container logs (Dozzle):${CL}"
echo -e "${GATEWAY}${BGN}http://${IP}:9999${CL}"
