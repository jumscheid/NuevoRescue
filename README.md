# NuevoRescue
Automated Shutdown Backup & Disaster Recovery

**Overview**
NuevoRescue runs a Borg + ReaR backup workflow automatically at every clean shutdown or reboot. It also includes a 48-hour safety net so a system never goes more than two days without a fresh backup and rescue ISO.

**How It Works**
	•	On shutdown or reboot, NuevoRescue performs a Borg incremental backup.
	•	The most recent backup is verified with borg check.
	•	If the kernel or /boot changed, a new rescue ISO is built; otherwise the existing ISO is reused.
	•	The newest ISO replaces the previous ISO, while the old one is kept as .prev.
	•	The ISO is SHA-256 checksummed and verified.
	•	A random sample of files is compared against the backup for consistency.
	•	A daily timer ensures that if no shutdown occurs in 48 hours, NuevoRescue runs automatically.

**Features**
	•	Runs at shutdown/reboot and via a 48h safety timer
	•	Borg incremental backups with deduplication
	•	Adaptive ISO rebuilds only when kernel or /boot changes
	•	Rescue ISO rotation (current + previous)
	•	Integrity checks on backup archives and ISOs
	•	Random file self-test against the backup
	•	Safe fstab configuration with nofail and automount
	•	Optional ISO copy to secondary storage
	•	Race protection between shutdown jobs and timer jobs

**Requirements**
	•	Linux server with systemd
	•	External HDD or dedicated partition
	•	Root access
	•	Packages: rear, borgbackup, fuse3, util-linux, coreutils, findutils

**Installation**
	1.	Identify backup disk UUID with lsblk -f.
	2.	Run sudo ./install-nuevorescue.sh.
	3.	Verify services:
systemctl status nuevorescue.service
systemctl list-timers | grep nuevorescue-stale

**File Locations**
	•	Backup repository: /mnt/backup//
	•	Rescue ISOs: /mnt/backup/rear/rescue-.iso and .iso.prev
	•	ISO checksums: /mnt/backup/rear/rescue-.iso.sha256
	•	Logs: /var/log/nuevorescue.log
	•	State files: /var/lib/nuevorescue/

**Restoring a Server**
Option 1: Rescue ISO – burn rescue-.iso to USB, boot, and ReaR will restore from Borg.
Option 2: Manual restore – install minimal Linux, mount /mnt/backup, run borg extract, reinstall bootloader if needed.

**Maintenance**
	•	Logs: /var/log/nuevorescue.log
	•	Last successful run: /var/lib/nuevorescue/last_success
	•	Verify ISO: sha256sum -c /mnt/backup/rear/rescue-.iso.sha256

**Customization**
	•	Mirror ISO: edit /usr/local/sbin/nuevorescue.sh and set COPY_ISO_EXTRA.
	•	Change self-test sample size in script.
	•	Adjust exclusions in /etc/rear/local.conf.

**Troubleshooting**
	•	Backup drive not mounted: verify UUID in /etc/fstab.
	•	Slow shutdowns: ISO rebuild skipped unless kernel or /boot changed.
	•	Overlapping jobs: race protection ensures only one run; check logs.

**License**
MIT License. Use at your own risk.
