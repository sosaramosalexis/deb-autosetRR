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
    echo "  7) Exit"
    read -rp "Choice [1-7]: " choice
    case "$choice" in
      1) main ;;
      2) main_omv ;;
      3) apply_omv_layout_existing ;;
      4) fix_permissions_existing ;;
      5) require_root; claim_plex_server ;;
      6) purge_all ;;
      7) echo "Exiting."; exit 0 ;;
    esac
    echo ""
    read -rp "Press Enter to continue..."
  done
fi
