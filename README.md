
[![GitHub](https://img.shields.io/static/v1?label=GitHub&message=sosaramosalexis%2Fdeb-autosetRR&color=181717&logo=github)](https://github.com/sosaramosalexis/deb-autosetRR)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![Shell](https://img.shields.io/badge/shell-blue?logo=gnu-bash)]()
[![Platform](https://img.shields.io/badge/platform-Linux-blue)]()

# deb-autosetRR

Interactive Debian installer for a movie automation stack:
Radarr, Prowlarr, qBittorrent, Plex/Jellyfin — plus OMV storage layout support.

## Quick Start

```bash
su -
curl -fsSL https://raw.githubusercontent.com/sosaramosalexis/deb-autosetRR/main/install.sh -o install.sh
bash install.sh
```

Or with sudo:
```bash
curl -fsSL https://raw.githubusercontent.com/sosaramosalexis/deb-autosetRR/main/install.sh | sudo bash
```

## Menu

```
1) Install full media stack (Debian)
2) Install full media stack (OMV)
3) Apply OMV layout (existing install)
4) Fix permissions on existing OMV folders
5) Claim Plex server
6) Purge everything and start fresh
7) Setup share, credentials & configure services
8) Exit
```

### Debian (option 1)
Installs Prowlarr, Radarr, qBittorrent, and your choice of Plex/Jellyfin.
Services run as their own users, qBittorrent temp password is shown in the summary.

### OMV (option 2)
Same as Debian plus:
- Detects `/srv/dev-disk-by-uuid-*` drives and prompts which to use
- Creates `downloads/` (qBittorrent saves here) and `media/Movies/` (Radarr library)
- Configures qBittorrent's save path and Radarr's root folder via API
- Sets group permissions so `radarr`, `qbittorrent`, and `plex` can all access

### Apply OMV layout (option 3)
Runs only the OMV folder/path/permissions setup on an existing install.

### Fix permissions (option 4)
Re-applies group ownership and permissions on existing OMV folders.
Also runnable as `bash install.sh --fix-perms`.

### Claim Plex (option 5)
Prompts for a claim token from https://plex.tv/claim and claims the server.

### Purge (option 6)
Removes all services and config data. Preserves your media/downloads on the data drive.

### Setup share, credentials & configure services (option 7)
Prompts for WebUI credentials, lets you select/format/mount a disk, creates a Samba share, sets up `sambashare` group with permissions, creates `Plex/Downloads` and `Plex/Movies`, and configures Prowlarr / Radarr / qBittorrent auth and download paths via API.

## Default Ports

| Service      | Port |
|-------------|------|
| Radarr      | 7878 |
| Prowlarr    | 9696 |
| qBittorrent | 8080 |
| Plex        | 32400 |
| Jellyfin    | 8096 |

## Notes

- qBittorrent's temp password is shown in the summary after install
- Plex claim is prompted right after install (or later via option 5)
- OMV layout uses `media` group with 775 + sgid so all services can share files
- Run `bash install.sh --fix-perms` anytime if Radarr reports "folder not writable"
