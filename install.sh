#!/usr/bin/env bash
set -euo pipefail

echo "[deb-autosetRR] version d028586 (fix-local-outside-function)" >&2



SERVARR_SCRIPT_URL="https://raw.githubusercontent.com/Servarr/Wiki/master/servarr/servarr-install-script.sh"
JELLYFIN_INSTALL_URL="https://repo.jellyfin.org/install-debuntu.sh"
PLEX_KEY_URL="https://downloads.plex.tv/plex-keys/PlexSign.v2.key"
PLEX_REPO_URL="https://repo.plex.tv/deb/"
PLEX_KEYRING="/etc/apt/keyrings/plexmediaserver.v2.gpg"
QB_USER="qbittorrent"
QB_GROUP="media"

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Please run this installer as root:"
    echo "  su -"
    echo "  bash install.sh"
    echo ""
    echo "Or, if sudo is already configured:"
    echo "  curl -fsSL https://raw.githubusercontent.com/sosaramosalexis/deb-autosetRR/main/install.sh | sudo bash"
    exit 1
  fi
}

require_debian_apt() {
  if ! command -v apt-get >/dev/null 2>&1; then
    echo "This installer is intended for Debian-based systems with apt-get."
    exit 1
  fi
}

install_base_packages() {
  echo "Updating package lists and upgrading system..."
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

  echo "Installing base dependencies..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates \
    curl \
    gnupg \
    libsqlite3-0 \
    sqlite3 \
    wget
}

install_servarr_app() {
  local app_name="$1"
  local menu_choice="$2"
  local script_path

  script_path="$(mktemp)"
  curl -fsSL "${SERVARR_SCRIPT_URL}" -o "${script_path}"
  chmod +x "${script_path}"

  echo "Installing ${app_name} with the Servarr installer..."
  printf '%s\n\n\nyes\n' "${menu_choice}" | bash "${script_path}"
  rm -f "${script_path}"
}

install_qbittorrent() {
  echo "Installing qBittorrent nox..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y qbittorrent-nox

  if ! getent group "${QB_GROUP}" >/dev/null; then
    groupadd "${QB_GROUP}"
  fi

  if ! id "${QB_USER}" >/dev/null 2>&1; then
    adduser --system --no-create-home --ingroup "${QB_GROUP}" "${QB_USER}"
  fi

  mkdir -p /var/lib/qbittorrent-nox
  chown -R "${QB_USER}:${QB_GROUP}" /var/lib/qbittorrent-nox

  cat >/etc/systemd/system/qbittorrent-nox.service <<EOF
[Unit]
Description=qBittorrent nox service
After=network-online.target
Wants=network-online.target

[Service]
Type=exec
User=${QB_USER}
Group=${QB_GROUP}
UMask=0002
ExecStart=/usr/bin/qbittorrent-nox --profile=/var/lib/qbittorrent-nox --confirm-legal-notice
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now qbittorrent-nox.service

  sleep 3
  QB_TEMP_PASS=$(journalctl -u qbittorrent-nox -n 30 --no-pager 2>/dev/null \
    | grep -oP 'password is set to: \K.*' \
    | head -1) || QB_TEMP_PASS=""
  export QB_TEMP_PASS
}

install_plex() {
  echo "Installing Plex Media Server..."

  local arch
  arch="$(dpkg --print-architecture 2>/dev/null || true)"
  if [[ "$arch" != "amd64" ]]; then
    echo "Plex only supports amd64 (detected: ${arch:-unknown}). Use Jellyfin instead."
    return 1
  fi

  rm -f /etc/apt/sources.list.d/plex*.list /etc/apt/sources.list.d/plex*.sources
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL "${PLEX_KEY_URL}" | gpg --dearmor -o "${PLEX_KEYRING}"
  echo "deb [signed-by=${PLEX_KEYRING}] ${PLEX_REPO_URL} public main" \
    >/etc/apt/sources.list.d/plex.list

  # Pre-create plex user and data directory to avoid postinst Permission denied
  if ! getent passwd plex &>/dev/null; then
    adduser --system --no-create-home --ingroup nogroup plex 2>/dev/null || useradd -r -s /usr/sbin/nologin -g nogroup plex
  fi
  mkdir -p /var/lib/plexmediaserver
  chown -R plex:nogroup /var/lib/plexmediaserver
  chmod 755 /var/lib/plexmediaserver

  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y plexmediaserver || {
    echo "Repo install failed. Falling back to latest direct .deb..."
    local plex_deb plex_url
    plex_deb="$(mktemp)"

    if command -v python3 &>/dev/null; then
      plex_url=$(curl -fsSL https://plex.tv/api/downloads/1.json 2>/dev/null | \
        python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    for r in d['computer']['Linux']['releases']:
        if r['distro']=='ubuntu' and 'x86_64' in r.get('build',''):
            print(r['url'])
            break
except:
    pass
" 2>/dev/null)
    fi

    if [[ -z "$plex_url" ]]; then
      echo "Could not fetch latest Plex version. Aborting."
      rm -f "$plex_deb"
      return 1
    fi

    curl -fsSL -o "$plex_deb" "$plex_url"
    dpkg -i "$plex_deb" || DEBIAN_FRONTEND=noninteractive apt-get install -y -f
    systemctl daemon-reload
    rm -f "$plex_deb"
  }

  systemctl enable --now plexmediaserver 2>/dev/null || true

  echo "Waiting for Plex to start..."
  for i in $(seq 1 15); do
    if systemctl is-active --quiet plexmediaserver 2>/dev/null; then
      break
    fi
    sleep 2
  done

  if ! systemctl is-active --quiet plexmediaserver; then
    echo "Plex service failed to start. Diagnostics:"
    systemctl status plexmediaserver --no-pager 2>&1 | head -25
    echo ""
    echo "Journal logs:"
    journalctl -u plexmediaserver -n 30 --no-pager 2>/dev/null || true
    echo ""
    echo "Common causes: unmet dependencies, missing libraries, or permission issues."
    echo "Try: systemctl restart plexmediaserver && journalctl -u plexmediaserver -f"
    return 1
  fi

  claim_plex_server
}

claim_plex_server() {
  if ! systemctl is-active --quiet plexmediaserver 2>/dev/null; then
    echo "Plex is not running. Start it first: systemctl start plexmediaserver"
    return 1
  fi

  local PLEX_CLAIM_TOKEN
  echo "Go to https://plex.tv/claim and copy your claim token."
  read -rp "Paste it here (or leave empty to skip): " PLEX_CLAIM_TOKEN

  if [[ -n "${PLEX_CLAIM_TOKEN}" ]]; then
    local response http_code
    response=$(curl -s -X POST \
      -w "%{http_code}" \
      "http://localhost:32400/myplex/claim?token=${PLEX_CLAIM_TOKEN}")
    http_code="${response: -3}"
    response="${response::-3}"
    if [[ "$http_code" == "200" ]] || echo "$response" | grep -qi "success"; then
      echo "Plex claimed successfully!"
    else
      echo "Claim failed (HTTP $http_code)."
      echo "$response"
      echo "Make sure the token is valid at https://plex.tv/claim"
    fi
  else
    echo "Skipped. Claim later at http://$(hostname -I | awk '{print $1}'):32400/web"
  fi
}

install_jellyfin() {
  echo "Installing Jellyfin..."
  curl -fsSL "${JELLYFIN_INSTALL_URL}" | bash
}

choose_media_server() {
  echo "Choose a media server to install:"
  echo "  1) Plex Media Server"
  echo "  2) Jellyfin Server"
  echo "  3) Skip media server"
  read -rp "Choice [1-3]: " choice
  case "$choice" in
    1) install_plex ;;
    2) install_jellyfin ;;
    *) echo "Skipping media server installation." ;;
  esac
}

print_summary() {
  local ip_local

  ip_local="$(hostname -I 2>/dev/null | awk '{print $1}')"
  ip_local="${ip_local:-SERVER_IP}"

  echo ""
  echo "Done."
  echo "Radarr:      http://${ip_local}:7878"
  echo "Prowlarr:    http://${ip_local}:9696"
  echo "qBittorrent: http://${ip_local}:8080"
  if [[ -n "${QB_TEMP_PASS:-}" ]]; then
    echo "qBit Pass:   ${QB_TEMP_PASS}  (change on first login)"
  else
    echo "qBit Pass:   check 'journalctl -u qbittorrent-nox -n 20'"
  fi
  echo "Plex:        http://${ip_local}:32400/web"
  echo "Jellyfin:    http://${ip_local}:8096"
  if [[ "${OMV_MODE:-0}" -eq 1 ]]; then
    echo ""
    echo "OMV Storage Layout:"
    echo "  Downloads: ${DOWNLOADS_PATH:-}"
    echo "  Movies:    ${MEDIA_PATH:-}"
    echo "  Point Plex library to: ${DATA_PATH:-}/media"
  fi
}

setup_omv_storage() {
  local drives=()
  while IFS= read -r dir; do
    drives+=("$dir")
  done < <(find /srv -maxdepth 1 -name 'dev-disk-by-uuid-*' 2>/dev/null | sort)

  if [[ ${#drives[@]} -eq 0 ]]; then
    echo "No OMV drives found at /srv/dev-disk-by-uuid-*"
    read -rp "Enter your storage path [/srv/data]: " DATA_PATH
    DATA_PATH="${DATA_PATH:-/srv/data}"
  else
    echo "Available drives:"
    for i in "${!drives[@]}"; do
      echo "  $((i+1))) ${drives[$i]}"
    done
    local sel
    read -rp "Select drive [1]: " sel
    sel="${sel:-1}"
    DATA_PATH="${drives[$((sel-1))]}"
  fi

  DOWNLOADS_PATH="${DATA_PATH}/downloads"
  MEDIA_PATH="${DATA_PATH}/media/Movies"

  mkdir -p "$DOWNLOADS_PATH" "$MEDIA_PATH"
  fix_omv_permissions
}

fix_omv_permissions() {
  echo "Setting up permissions..."
  if ! getent group "${QB_GROUP}" >/dev/null; then
    groupadd "${QB_GROUP}"
  fi

  local users=()
  for u in radarr prowlarr qbittorrent plex; do
    if id "$u" >/dev/null 2>&1; then
      usermod -aG "${QB_GROUP}" "$u"
      users+=("$u")
    fi
  done

  if [[ -d "${DOWNLOADS_PATH:-}" ]]; then
    chown -R "qbittorrent:${QB_GROUP}" "$DOWNLOADS_PATH"
    chmod -R 775 "$DOWNLOADS_PATH"
    find "$DOWNLOADS_PATH" -type d -exec chmod g+s {} +
    echo "  Permissions set: $DOWNLOADS_PATH (qbittorrent:media, 775)"
  fi

  if [[ -d "${MEDIA_PATH:-}" ]]; then
    chown -R "radarr:${QB_GROUP}" "$MEDIA_PATH"
    chmod -R 775 "$MEDIA_PATH"
    find "$MEDIA_PATH" -type d -exec chmod g+s {} +
    echo "  Permissions set: $MEDIA_PATH (radarr:media, 775)"
  fi

  if [[ -d "${DATA_PATH:-}/media" ]]; then
    chmod -R 755 "${DATA_PATH}/media"
    echo "  Read permission set: ${DATA_PATH}/media (for Plex scan)"
  fi

  echo "  Users in '${QB_GROUP}' group: ${users[*]:-none}"
  echo ""
  echo "  ⚠️  If Radarr still says 'folder not writable', run this:"
  echo "       bash install.sh --fix-perms"
}

configure_qbit_download_path() {
  local path="$1"
  local qb_conf="/var/lib/qbittorrent-nox/qBittorrent/qBittorrent.conf"

  systemctl stop qbittorrent-nox.service 2>/dev/null || true
  mkdir -p "$(dirname "$qb_conf")"

  if [[ -f "$qb_conf" ]]; then
    sed -i "s|^Downloads\\\\SavePath=.*|Downloads\\\\SavePath=${path}|" "$qb_conf"
  else
    cat > "$qb_conf" <<EOF
[Preferences]
Downloads\\SavePath=${path}
Downloads\\PreAllocation=false
Connection\\PortRangeMin=6881
EOF
  fi

  chown -R "${QB_USER}:${QB_GROUP}" "/var/lib/qbittorrent-nox"
  systemctl start qbittorrent-nox.service
  echo "qBittorrent downloads path set to: $path"
}

configure_radarr_root_folder() {
  local path="$1"
  local radarr_conf

  for candidate in "/var/lib/radarr/config.xml" "/home/radarr/.config/Radarr/config.xml" "/opt/Radarr/config.xml"; do
    if [[ -f "$candidate" ]]; then
      radarr_conf="$candidate"
      break
    fi
  done

  if [[ -z "${radarr_conf:-}" ]]; then
    echo "Radarr config not found at any known path. Set root folder manually:"
    echo "  Settings → Media Management → Root Folders → Add: $path"
    return
  fi

  local api_key
  api_key=$(grep -oP '(?<=<ApiKey>)[^<]+' "$radarr_conf" 2>/dev/null) || true
  if [[ -z "$api_key" ]]; then
    echo "Radarr API key not found in config. Set root folder manually."
    return
  fi

  for i in $(seq 1 12); do
    if curl -s "http://localhost:7878/api/v3/system/status?apiKey=${api_key}" >/dev/null 2>&1; then
      break
    fi
    sleep 5
  done

  curl -s -X POST "http://localhost:7878/api/v3/rootfolder?apiKey=${api_key}" \
    -H "Content-Type: application/json" \
    -d "{\"path\":\"${path}\"}" >/dev/null 2>&1 && echo "Radarr root folder added: $path" \
    || echo "Could not add Radarr root folder. Add manually: Settings → Media Management → Root Folders"
}

main() {
  require_root
  require_debian_apt
  install_base_packages

  install_servarr_app "Prowlarr" "2"
  install_servarr_app "Radarr" "3"
  install_qbittorrent
  choose_media_server
  print_summary
}

main_omv() {
  OMV_MODE=1
  require_root
  require_debian_apt
  install_base_packages

  setup_omv_storage

  install_servarr_app "Prowlarr" "2"
  install_servarr_app "Radarr" "3"
  install_qbittorrent

  configure_qbit_download_path "$DOWNLOADS_PATH"
  configure_radarr_root_folder "$MEDIA_PATH"

  fix_omv_permissions
  choose_media_server
  print_summary

  echo ""
  echo "OMV Layout:"
  echo "  qBittorrent saves to: $DOWNLOADS_PATH"
  echo "  Radarr library:      $MEDIA_PATH"
  echo "  Point Plex to:       ${DATA_PATH}/media"
}

apply_omv_layout_existing() {
  require_root
  echo "This will NOT install any packages — only apply the OMV storage layout."
  setup_omv_storage

  if systemctl is-active --quiet qbittorrent-nox 2>/dev/null; then
    configure_qbit_download_path "$DOWNLOADS_PATH"
  else
    echo "qBittorrent not running. Set download path manually after starting it."
  fi

  if systemctl is-active --quiet radarr 2>/dev/null; then
    configure_radarr_root_folder "$MEDIA_PATH"
  else
    echo "Radarr not running. Add root folder manually in Settings → Media Management."
  fi

  echo ""
  echo "OMV Layout applied:"
  echo "  Downloads: $DOWNLOADS_PATH"
  echo "  Movies:    $MEDIA_PATH"
}

fix_permissions_existing() {
  require_root
  echo "Fix permissions for existing OMV layout..."
  setup_omv_storage
  fix_omv_permissions
}

purge_all() {
  require_root

  echo "This will REMOVE all installed services and their config data:"
  echo "  - Radarr, Prowlarr, qBittorrent, Plex, Jellyfin"
  read -rp "Continue? [y/N]: " confirm
  [[ "$confirm" =~ ^[yY] ]] || return

  echo "Stopping services..."
  for svc in radarr prowlarr qbittorrent-nox plexmediaserver jellyfin; do
    systemctl stop "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
  done

  echo "Removing packages..."
  DEBIAN_FRONTEND=noninteractive apt-get remove --purge -y \
    radarr prowlarr qbittorrent-nox plexmediaserver jellyfin 2>/dev/null || true

  echo "Removing config and data directories..."
  rm -rf /var/lib/radarr /var/lib/prowlarr /var/lib/qbittorrent-nox /var/lib/plexmediaserver /var/lib/jellyfin
  rm -rf /home/radarr /home/prowlarr /home/qbittorrent
  rm -f /etc/apt/sources.list.d/plex*.list /etc/apt/sources.list.d/plex*.sources
  rm -f /etc/apt/keyrings/plexmediaserver.v2.gpg

  echo ""
  echo "Purge complete. The OMV storage layout on your data drive was preserved."
}

setup_share_and_creds() {
  local WEBUI_USER WEBUI_PASS
  local MOUNT_PATH MOUNT_NAME DISK_NAME DISK_SEL
  local SHARE_NAME SUDO_CALLER
  local line name size mp mountpoint uuid part_mp existing_fs fstype

  SUDO_CALLER="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"

  echo ""
  echo "============================================"
  echo "  WebUI Credentials"
  echo "============================================"
  read -rp "Enter WebUI username [admin]: " WEBUI_USER
  WEBUI_USER="${WEBUI_USER:-admin}"
  read -rsp "Enter WebUI password: " WEBUI_PASS
  echo ""

  echo ""
  echo "============================================"
  echo "  Disk Setup"
  echo "============================================"
  read -rp "Do you want to set up a disk for the media share? [y/N]: " setup_disk
  if [[ "$setup_disk" =~ ^[yY] ]]; then
    local -a disks=()
    local -a disk_sizes=()
    echo ""
    echo "Available disks:"
    while IFS= read -r line; do
      name=$(echo "$line" | awk '{print $1}')
      size=$(echo "$line" | awk '{print $2}')
      model=$(lsblk -dnlo MODEL "/dev/${name}" 2>/dev/null)
      [[ -z "$model" ]] && model="N/A"

      if lsblk -lno MOUNTPOINT "/dev/${name}" 2>/dev/null | grep -qxF '/'; then
        tag="[OS]  ← system disk, DO NOT FORMAT"
      else
        tag="[DATA]"
      fi

      echo "  $(( ${#disks[@]} + 1 ))) /dev/${name}  (${size})  ${model}  ${tag}"
      disks+=("$name")
      disk_sizes+=("$size")
    done < <(lsblk -dnlo NAME,SIZE,TYPE 2>/dev/null | awk '$3=="disk"')

    if [[ ${#disks[@]} -eq 0 ]]; then
      echo "No disks found."
    else
      read -rp "Select disk [1]: " DISK_SEL
      DISK_SEL="${DISK_SEL:-1}"
      DISK_NAME="${disks[$((DISK_SEL-1))]}"

      part_mp=$(lsblk -lno MOUNTPOINT "/dev/${DISK_NAME}" 2>/dev/null | grep -v '^$' | head -1) || true

      if [[ -n "$part_mp" ]]; then
        MOUNT_PATH="$part_mp"
        echo "Disk has mounted partitions, using mount point: $MOUNT_PATH"
        read -rp "Use this path for the media share? [Y/n]: " use_mp
        if [[ "$use_mp" =~ ^[nN] ]]; then
          MOUNT_PATH=""
        fi
      fi

      if [[ -z "${MOUNT_PATH:-}" ]]; then
        existing_fs=$(blkid -s TYPE -o value "/dev/${DISK_NAME}" 2>/dev/null || echo "")
        if [[ -n "$existing_fs" ]]; then
          echo "Disk /dev/${DISK_NAME} already has a ${existing_fs} filesystem."
          read -rp "Mount it as-is without formatting? [Y/n]: " mount_asis
          if [[ ! "$mount_asis" =~ ^[nN] ]]; then
            read -rp "Enter a name for the mount point [/mnt/media]: " MOUNT_NAME
            MOUNT_NAME="${MOUNT_NAME:-media}"
            MOUNT_PATH="/mnt/${MOUNT_NAME}"
            mkdir -p "$MOUNT_PATH"
            uuid=$(blkid -s UUID -o value "/dev/${DISK_NAME}" 2>/dev/null)
            if [[ -n "$uuid" ]]; then
              echo "UUID=${uuid}  ${MOUNT_PATH}  ${existing_fs}  defaults,nofail  0  2" >> /etc/fstab
              echo "Added to /etc/fstab by UUID."
            fi
            mount "/dev/${DISK_NAME}" "$MOUNT_PATH" 2>/dev/null || echo "Mount failed. Mount manually."
          else
            read -rp "Do you want to format it as ext4? ALL DATA WILL BE LOST! [y/N]: " fmt_confirm
            if [[ "$fmt_confirm" =~ ^[yY] ]]; then
              echo "Formatting /dev/${DISK_NAME} as ext4..."
              mkfs.ext4 -F "/dev/${DISK_NAME}"
            fi
          fi
        else
          echo "Disk /dev/${DISK_NAME} has no detected filesystem."
          read -rp "Do you want to format it as ext4? [y/N]: " fmt_confirm
          if [[ "$fmt_confirm" =~ ^[yY] ]]; then
            echo "Formatting /dev/${DISK_NAME} as ext4..."
            mkfs.ext4 -F "/dev/${DISK_NAME}"
          fi
        fi

        if [[ -z "${MOUNT_PATH:-}" ]]; then
          read -rp "Enter a name for the mount point [/mnt/media]: " MOUNT_NAME
          MOUNT_NAME="${MOUNT_NAME:-media}"
          MOUNT_PATH="/mnt/${MOUNT_NAME}"
          mkdir -p "$MOUNT_PATH"
          uuid=$(blkid -s UUID -o value "/dev/${DISK_NAME}" 2>/dev/null)
          fstype="${existing_fs:-ext4}"
          if [[ -n "$uuid" ]]; then
            echo "UUID=${uuid}  ${MOUNT_PATH}  ${fstype}  defaults,nofail  0  2" >> /etc/fstab
            echo "Added to /etc/fstab by UUID."
            mount UUID="${uuid}" "$MOUNT_PATH" 2>/dev/null || mount "/dev/${DISK_NAME}" "$MOUNT_PATH" 2>/dev/null || echo "Mount failed. Mount manually."
          else
            mount "/dev/${DISK_NAME}" "$MOUNT_PATH" 2>/dev/null || echo "Mount failed. Mount manually."
          fi
        fi
      fi
    fi
  fi

  if [[ -z "${MOUNT_PATH:-}" ]]; then
    read -rp "Enter path for media share [/srv/media]: " MOUNT_PATH
    MOUNT_PATH="${MOUNT_PATH:-/srv/media}"
    mkdir -p "$MOUNT_PATH"
  fi

  local PLEX_DOWNLOADS="${MOUNT_PATH}/Plex/Downloads"
  local PLEX_MOVIES="${MOUNT_PATH}/Plex/Movies"

  echo ""
  echo "============================================"
  echo "  Samba Share"
  echo "============================================"
  read -rp "Set up a Samba share? [y/N]: " setup_samba
  if [[ "$setup_samba" =~ ^[yY] ]]; then
    if ! command -v smbd >/dev/null 2>&1; then
      echo "Installing Samba..."
      DEBIAN_FRONTEND=noninteractive apt-get install -y samba
    fi
    read -rp "Enter share name [media]: " SHARE_NAME
    SHARE_NAME="${SHARE_NAME:-media}"
    if grep -q "^\\[${SHARE_NAME}\\]" /etc/samba/smb.conf 2>/dev/null; then
      echo "Share '${SHARE_NAME}' already exists in smb.conf."
    else
      cat >> /etc/samba/smb.conf <<EOF

[${SHARE_NAME}]
  path = ${MOUNT_PATH}
  browseable = yes
  read only = no
  valid users = @sambashare
  create mask = 0775
  directory mask = 0775
  force group = sambashare
EOF
      echo "Share '${SHARE_NAME}' added to smb.conf."
    fi
    systemctl restart smbd 2>/dev/null || true
  fi

  echo ""
  echo "============================================"
  echo "  Group & Permissions"
  echo "============================================"
  read -rp "Set up sambashare group? [y/N]: " setup_group
  if [[ "$setup_group" =~ ^[yY] ]]; then
    if ! getent group sambashare >/dev/null; then
      groupadd sambashare
      echo "Created group 'sambashare'."
    fi
    local -a group_users=()
    for u in prowlarr radarr qbittorrent plex "$SUDO_CALLER"; do
      if id "$u" >/dev/null 2>&1; then
        usermod -aG sambashare "$u" 2>/dev/null || true
        group_users+=("$u")
      fi
    done
    echo "Users added to sambashare: ${group_users[*]}"
    if command -v smbpasswd >/dev/null 2>&1; then
      echo "Setting Samba password for ${SUDO_CALLER} (matches WebUI password)..."
      printf "%s\n%s" "$WEBUI_PASS" "$WEBUI_PASS" | smbpasswd -a -s "$SUDO_CALLER" 2>/dev/null \
        || printf "%s\n%s" "$WEBUI_PASS" "$WEBUI_PASS" | smbpasswd -s "$SUDO_CALLER" 2>/dev/null \
        || echo "  Warning: could not set Samba password. Run 'smbpasswd ${SUDO_CALLER}' manually."
    fi
    chown "root:sambashare" "$MOUNT_PATH"
    chmod 2770 "$MOUNT_PATH"
  fi

  echo ""
  echo "============================================"
  echo "  Creating Directories"
  echo "============================================"
  mkdir -p "$PLEX_DOWNLOADS" "$PLEX_DOWNLOADS/tmp" "$PLEX_MOVIES"
  echo "Created: $PLEX_DOWNLOADS"
  echo "Created: $PLEX_DOWNLOADS/tmp"
  echo "Created: $PLEX_MOVIES"

  echo ""
  echo "============================================"
  echo "  Configuring Prowlarr Authentication"
  echo "============================================"
  if [[ -f /var/lib/prowlarr/config.xml ]]; then
    local prowlarr_key
    prowlarr_key=$(grep -oP '(?<=<ApiKey>)[^<]+' /var/lib/prowlarr/config.xml 2>/dev/null) || true
    if [[ -n "$prowlarr_key" ]]; then
      local i
      for i in $(seq 1 12); do
        if curl -s "http://localhost:9696/api/v1/system/status?apiKey=${prowlarr_key}" >/dev/null 2>&1; then
          break
        fi
        sleep 5
      done
      local prowlarr_config
      prowlarr_config=$(curl -s "http://localhost:9696/api/v1/config/host/1?apiKey=${prowlarr_key}" 2>/dev/null) || true
      if [[ -n "$prowlarr_config" ]]; then
        local new_config
        new_config=$(WEBUI_USER="$WEBUI_USER" WEBUI_PASS="$WEBUI_PASS" python3 -c "
import os, json, sys
d = json.load(sys.stdin)
d['authenticationMethod'] = 'Forms'
d['username'] = os.environ['WEBUI_USER']
d['password'] = os.environ['WEBUI_PASS']
print(json.dumps(d))
" <<< "$prowlarr_config" 2>/dev/null) || new_config=""
        if [[ -n "$new_config" ]]; then
          curl -s -X PUT "http://localhost:9696/api/v1/config/host/1?apiKey=${prowlarr_key}" \
            -H "Content-Type: application/json" \
            -d "$new_config" >/dev/null 2>&1 && echo "Prowlarr auth configured." \
            || echo "Failed to configure Prowlarr auth."
        fi
      fi
    else
      echo "Prowlarr API key not found."
    fi
  else
    echo "Prowlarr config not found. Skipping."
  fi

  echo ""
  echo "============================================"
  echo "  Configuring Radarr Authentication"
  echo "============================================"
  local radarr_conf=""
  for candidate in "/var/lib/radarr/config.xml" "/home/radarr/.config/Radarr/config.xml" "/opt/Radarr/config.xml"; do
    if [[ -f "$candidate" ]]; then
      radarr_conf="$candidate"
      break
    fi
  done
  if [[ -n "$radarr_conf" ]]; then
    local radarr_key
    radarr_key=$(grep -oP '(?<=<ApiKey>)[^<]+' "$radarr_conf" 2>/dev/null) || true
    if [[ -n "$radarr_key" ]]; then
      for i in $(seq 1 12); do
        if curl -s "http://localhost:7878/api/v3/system/status?apiKey=${radarr_key}" >/dev/null 2>&1; then
          break
        fi
        sleep 5
      done
      local radarr_host_config
      radarr_host_config=$(curl -s "http://localhost:7878/api/v3/config/host/1?apiKey=${radarr_key}" 2>/dev/null) || true
      if [[ -n "$radarr_host_config" ]]; then
        local new_config
        new_config=$(WEBUI_USER="$WEBUI_USER" WEBUI_PASS="$WEBUI_PASS" python3 -c "
import os, json, sys
d = json.load(sys.stdin)
d['authenticationMethod'] = 'Forms'
d['username'] = os.environ['WEBUI_USER']
d['password'] = os.environ['WEBUI_PASS']
print(json.dumps(d))
" <<< "$radarr_host_config" 2>/dev/null) || new_config=""
        if [[ -n "$new_config" ]]; then
          curl -s -X PUT "http://localhost:7878/api/v3/config/host/1?apiKey=${radarr_key}" \
            -H "Content-Type: application/json" \
            -d "$new_config" >/dev/null 2>&1 && echo "Radarr auth configured." \
            || echo "Failed to configure Radarr auth."
        fi
      fi
    else
      echo "Radarr API key not found."
    fi
  else
    echo "Radarr config not found. Skipping."
  fi

  echo ""
  echo "============================================"
  echo "  Configuring qBittorrent"
  echo "============================================"
  if systemctl is-active --quiet qbittorrent-nox 2>/dev/null; then
    local qb_response
    local cookie_file
    cookie_file="$(mktemp)"
    qb_response=$(curl -s -c "$cookie_file" \
      "http://localhost:8080/api/v2/auth/login" \
      --data "username=admin&password=adminadmin" 2>/dev/null)
    if [[ "$qb_response" != "Ok." ]]; then
      local temp_pass
      temp_pass=$(journalctl -u qbittorrent-nox -n 30 --no-pager 2>/dev/null | grep -oP 'temporary password is provided for this session: \K\S+' | tail -1) || temp_pass=""
      if [[ -n "$temp_pass" ]]; then
        qb_response=$(curl -s -c "$cookie_file" \
          "http://localhost:8080/api/v2/auth/login" \
          --data "username=admin&password=${temp_pass}" 2>/dev/null)
      fi
    fi
    if [[ "$qb_response" == "Ok." ]]; then
      echo "Logged into qBittorrent."
      curl -s -b "$cookie_file" \
        "http://localhost:8080/api/v2/app/setPreferences" \
        --data-urlencode "json={\"web_ui_username\":\"${WEBUI_USER}\",\"web_ui_password\":\"${WEBUI_PASS}\"}" >/dev/null 2>&1 || true
      curl -s -b "$cookie_file" \
        "http://localhost:8080/api/v2/app/setPreferences" \
        --data-urlencode "json={\"save_path\":\"${PLEX_DOWNLOADS}\",\"temp_path\":\"${PLEX_DOWNLOADS}/tmp\",\"temp_path_enabled\":true}" >/dev/null 2>&1 || true
      echo "qBittorrent configured."
    else
      echo "Could not log into qBittorrent. Set credentials manually."
    fi
    rm -f "$cookie_file"
  else
    echo "qBittorrent is not running. Skipping."
  fi

  echo ""
  echo "============================================"
  echo "  Configuring Radarr Root Folder"
  echo "============================================"
  if systemctl is-active --quiet radarr 2>/dev/null; then
    configure_radarr_root_folder "$PLEX_MOVIES"
  else
    echo "Radarr not running. Skipping."
  fi

  local ip_local
  ip_local="$(hostname -I 2>/dev/null | awk '{print $1}')"
  ip_local="${ip_local:-SERVER_IP}"
  echo ""
  echo "============================================"
  echo "  Setup Complete - Summary"
  echo "============================================"
  echo "WebUI Username:  ${WEBUI_USER}"
  echo "WebUI Password:  ${WEBUI_PASS}"
  echo "Mount Path:      ${MOUNT_PATH}"
  echo "Downloads:       ${PLEX_DOWNLOADS}"
  echo "Movies:          ${PLEX_MOVIES}"
  echo ""
  echo "Prowlarr:        http://${ip_local}:9696"
  echo "Radarr:          http://${ip_local}:7878"
  echo "qBittorrent:     http://${ip_local}:8080"
  echo "Plex:            http://${ip_local}:32400/web"
  echo ""
}

if [[ "${1:-}" == "--claim-plex" ]]; then
  require_root
  claim_plex_server
elif [[ "${1:-}" == "--apply-omv-layout" ]]; then
  apply_omv_layout_existing
elif [[ "${1:-}" == "--fix-perms" ]]; then
  fix_permissions_existing
elif [[ "${1:-}" == "--purge" ]]; then
  purge_all
else
  while true; do
    echo ""
    echo "Choose an option:"
    echo "  1) Install full media stack (Debian)"
    echo "  2) Install full media stack (OMV)"
    echo "  3) Apply OMV layout (existing install)"
    echo "  4) Fix permissions on existing OMV folders"
    echo "  5) Claim Plex server"
    echo "  6) Purge everything and start fresh"
    echo "  7) Setup share, credentials & configure services"
    echo "  8) Exit"
    read -rp "Choice [1-8]: " choice
    case "$choice" in
      1) main ;;
      2) main_omv ;;
      3) apply_omv_layout_existing ;;
      4) fix_permissions_existing ;;
      5) require_root; claim_plex_server ;;
      6) purge_all ;;
      7) require_root; setup_share_and_creds ;;
      8) echo "Exiting."; exit 0 ;;
    esac
    echo ""
    read -rp "Press Enter to continue..."
  done
fi
