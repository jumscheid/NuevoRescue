#!/usr/bin/env bash
set -euo pipefail

BACKUP_MOUNT="/mnt/backup"
REPO_DIR_DEFAULT="${BACKUP_MOUNT}/$(hostname)"
ISO_DIR_DEFAULT="${BACKUP_MOUNT}/rear"
COPY_ISO_EXTRA=""

SERVICE_NAME="nuevorescue.service"
STALE_SERVICE="nuevorescue-stale.service"
STALE_TIMER="nuevorescue-stale.timer"
SCRIPT_PATH="/usr/local/sbin/nuevorescue.sh"
LOG_FILE="/var/log/nuevorescue.log"
STATE_DIR="/var/lib/nuevorescue"
REAR_CONF="/etc/rear/local.conf"

detect_pkg() {
  if command -v apt >/dev/null 2>&1; then echo apt; return; fi
  if command -v dnf >/dev/null 2>&1; then echo dnf; return; fi
  if command -v yum >/dev/null 2>&1; then echo yum; return; fi
  echo "Unsupported distro." >&2; exit 1
}

PKG=$(detect_pkg)
case "$PKG" in
  apt)  apt update -y; DEBIAN_FRONTEND=noninteractive apt install -y rear borgbackup fuse3 util-linux coreutils findutils ;;
  dnf)  dnf install -y rear borgbackup fuse3 util-linux coreutils findutils || true ;;
  yum)  yum install -y epel-release || true; yum install -y rear borgbackup fuse3 util-linux coreutils findutils || true ;;
esac

echo
echo "=== NuevoRescue: Backup Disk UUID Setup for ${BACKUP_MOUNT} ==="
lsblk -f || true
read -r -p "Enter the UUID of the backup partition (blank to skip fstab editing): " BACKUP_UUID || BACKUP_UUID=""
read -r -p "Borg repo path [default: ${REPO_DIR_DEFAULT}]: " REPO_DIR_IN || true
read -r -p "ISO output dir [default: ${ISO_DIR_DEFAULT}]: " ISO_DIR_IN || true
read -r -p "Optional second ISO copy location (blank to skip): " COPY_ISO_EXTRA_IN || true

REPO_DIR="${REPO_DIR_IN:-$REPO_DIR_DEFAULT}"
ISO_DIR="${ISO_DIR_IN:-$ISO_DIR_DEFAULT}"
COPY_ISO_EXTRA="${COPY_ISO_EXTRA_IN:-$COPY_ISO_EXTRA}"

mkdir -p "$ISO_DIR" "$STATE_DIR"
touch "$LOG_FILE"
chmod 700 "$STATE_DIR"
chmod 640 "$LOG_FILE"

if [[ -n "${BACKUP_UUID}" ]]; then
  echo "Configuring /etc/fstab for ${BACKUP_MOUNT} (UUID=${BACKUP_UUID})..."
  mkdir -p "$BACKUP_MOUNT"
  FS_TYPE=$(blkid -t "UUID=${BACKUP_UUID}" -o value -s TYPE 2>/dev/null || echo ext4)
  FSTAB_LINE="UUID=${BACKUP_UUID}  ${BACKUP_MOUNT}  ${FS_TYPE}  defaults,nofail,x-systemd.automount,x-systemd.device-timeout=10  0  2"
  grep -q "UUID=${BACKUP_UUID}" /etc/fstab && sed -i "s|^UUID=${BACKUP_UUID} .*|${FSTAB_LINE}|" /etc/fstab || echo "$FSTAB_LINE" >> /etc/fstab
  systemctl daemon-reload
  mount "${BACKUP_MOUNT}" 2>/dev/null || true
else
  echo "Skipping fstab editing. Ensure ${BACKUP_MOUNT} is mounted for backups."
fi

mkdir -p /etc/rear
cat > "$REAR_CONF" <<EOF
# NuevoRescue generated
OUTPUT=ISO
OUTPUT_URL=file://${ISO_DIR}
BACKUP=BORG
BACKUP_URL=file://${REPO_DIR}
BACKUP_PROG_EXCLUDE=( ${BACKUP_MOUNT} /proc /sys /dev /run /tmp )
EOF

# main script
cat > "$SCRIPT_PATH" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail

BACKUP_MOUNT="/mnt/backup"
REPO_DIR="/mnt/backup/$(hostname)"
ISO_DIR="/mnt/backup/rear"
COPY_ISO_EXTRA=""
LOG_FILE="/var/log/nuevorescue.log"
STATE_DIR="/var/lib/nuevorescue"

ISO_FIXED="${ISO_DIR}/rescue-$(hostname).iso"
ISO_PREV="${ISO_FIXED}.prev"
ISO_SHA="${ISO_FIXED}.sha256"
LAST_SUCCESS="${STATE_DIR}/last_success"

LOCK_FILE="/run/nuevorescue.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "$(date '+%F %T') NuevoRescue: another run is active; skipping." >> "$LOG_FILE"
  exit 0
fi

log() { printf "%s %s\n" "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE" >/dev/console 2>/dev/null || true; }

do_run() {
  log "NuevoRescue: workflow start"
  /usr/sbin/rear mkbackup >>"$LOG_FILE" 2>&1 && log "NuevoRescue: backup completed"
  borg check --last 1 "$REPO_DIR" >>"$LOG_FILE" 2>&1 && log "NuevoRescue: borg check passed"
  /usr/sbin/rear mkrescue >>"$LOG_FILE" 2>&1 && log "NuevoRescue: rescue ISO built"
  date +%s > "$LAST_SUCCESS"
  log "NuevoRescue: workflow done"
}

maybe_run_maintenance() {
  now=$(date +%s)
  last=0
  [[ -f "$LAST_SUCCESS" ]] && last=$(cat "$LAST_SUCCESS")
  delta=$(( now - last ))
  if (( delta >= 172800 )); then
    log "NuevoRescue: no successful run in >=48h; starting maintenance backup..."
    do_run
  else
    log "NuevoRescue: last run $delta seconds ago; maintenance not needed."
  fi
}

mode="${1:-shutdown}"
if [[ "$mode" == "--maintenance" ]]; then
  maybe_run_maintenance
else
  do_run
fi
EOS
chmod +x "$SCRIPT_PATH"

# shutdown service
cat > "/etc/systemd/system/${SERVICE_NAME}" <<EOF
[Unit]
Description=NuevoRescue: run backup and rescue ISO at shutdown
DefaultDependencies=no
Before=shutdown.target reboot.target halt.target
Conflicts=${STALE_SERVICE}
After=${STALE_SERVICE}

[Service]
Type=oneshot
ExecStart=${SCRIPT_PATH}
RemainAfterExit=yes
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=halt.target reboot.target shutdown.target
EOF

# stale service + timer
cat > "/etc/systemd/system/${STALE_SERVICE}" <<EOF
[Unit]
Description=NuevoRescue: 48h safety run

[Service]
Type=oneshot
ExecStart=${SCRIPT_PATH} --maintenance
StandardOutput=journal+console
StandardError=journal+console
EOF

cat > "/etc/systemd/system/${STALE_TIMER}" <<'EOF'
[Unit]
Description=NuevoRescue daily stale check

[Timer]
OnCalendar=daily
AccuracySec=10min
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable "${SERVICE_NAME}"
systemctl enable "${STALE_TIMER}"
systemctl start "${STALE_TIMER}" || true

echo "NuevoRescue installed. Logs: ${LOG_FILE}"
