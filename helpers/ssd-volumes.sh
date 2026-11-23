# Shared by ssd-resume and ssd-off. Sourced, not run. Part of SSD Monitor (AGENTS.md, section 8).
#
# ===== This Mac's setup: edit this part for another Mac =====
# One line per SSD volume: name|APFS volume UUID|where it is mounted (its /etc/fstab path).
# UUIDs never change (disk IDs like disk5s1 can): `diskutil info /Volumes/<name> | grep 'Volume UUID'`.
SSD_VOLUMES=(
  "Repo|52B6730D-CE2B-449F-BBFD-FE2FB331B96E|$HOME/Repo"
  "Downloads|A6156C3B-52D4-48D3-ADF2-6C401A767789|$HOME/Downloads"
  "Developer|607454D2-3480-4754-BB17-718C58B88BF2|$HOME/Library/Developer"
  "Android|3EC72238-B765-4A48-83B3-57457D638B1D|$HOME/Library/Android"
  "AVD|AD8422D5-1189-4D4B-90A8-DEFADEB4D2B2|$HOME/.android/avd"
  "MobileSync|B1ED2927-A59E-4AF9-9436-367DEA8DDDE6|$HOME/Library/Application Support/MobileSync"
  "Gradle|E3C59F39-1840-45F7-ADAA-F248740611E6|$HOME/.gradle"
)
# The enclosure's USB name in the IORegistry (this one has an RTL9220 bridge): the name shown by
# `ioreg -r -c IOUSBHostDevice -d 1 | grep -i '<your enclosure>'`. Its id changes on every reconnect, which is how
# ssd-resume tells a replug from a second run.
SSD_USB_NAME=RTL9220
# Which volumes (names above, one array element each) each service keeps files on: it is restarted when one of
# them went away. An empty list () means none of its files are on the SSD: never restarted.
SSD_SIM_VOLUMES=(Developer)               # the iOS simulator service (~/Library/Developer)
SSD_ADB_VOLUMES=(Android AVD)             # the adb server (Android SDK, emulators)
SSD_GRADLE_VOLUMES=(Gradle Repo Android)  # Gradle and Kotlin daemons
# The folder whose git repos get their stale lock files removed, and where the resume checks that it can write.
# Set SSD_REPO_ROOT in the environment to point a test at a scratch folder.
SSD_REPO_ROOT=${SSD_REPO_ROOT:-$HOME/Repo}
# Where ssd-resume remembers the connection it last fixed up, and ssd-off leaves its planned-unplug marker.
# On the Mac's own disk, like the scripts themselves (~/Local/bin).
SSD_STATE_DIR=$HOME/Local/ssd
# ===== End of this Mac's setup =====

# Split one SSD_VOLUMES entry into V_NAME, V_UUID and V_PATH (no process, no temp file).
ssd_split() { V_NAME=${1%%|*}; V_PATH=${1#*|}; V_UUID=${V_PATH%%|*}; V_PATH=${V_PATH#*|}; }
# UUID -> device of every APFS volume attached, from one `diskutil apfs list` (about 0.6 s), not one diskutil
# call per volume. Loaded on first use; load again when the SSD may have come or gone.
ssd_load_devices() {
  SSD_DEVMAP=" $(diskutil apfs list -plist 2>/dev/null | awk '
    /<key>APFSVolumeUUID<\/key>/   { getline; gsub(/.*<string>|<\/string>.*/, ""); uuid = $0 }
    /<key>DeviceIdentifier<\/key>/ { getline; gsub(/.*<string>|<\/string>.*/, ""); if (uuid != "") { printf "%s=%s ", uuid, $0; uuid = "" } }') "
  SSD_DEVMAP_LOADED=1
}
# Sets DEV to a volume's device node (by UUID), empty if not attached. No process once the map is loaded.
ssd_dev() {
  local rest
  [ -n "${SSD_DEVMAP_LOADED:-}" ] || ssd_load_devices
  DEV=""
  case $SSD_DEVMAP in *" $1="*) rest=${SSD_DEVMAP#*" $1="}; DEV=/dev/${rest%% *} ;; esac
}
# device node of a volume (by UUID), empty if the SSD is not attached
ssd_dev_of() { ssd_dev "$1"; printf '%s' "$DEV"; }
# UUID of the first SSD volume that is attached, empty if none is: the SSD is attached if any of them is
ssd_any_uuid() {
  local e u
  for e in "${SSD_VOLUMES[@]}"; do
    u=${e#*|}; u=${u%%|*}
    ssd_dev "$u"
    if [ -n "$DEV" ]; then printf '%s\n' "$u"; return 0; fi
  done
}
# where a device is mounted right now, empty if not mounted
ssd_mounted_at() { mount | awk -v d="$1" 'index($0, d" on ")==1' | sed -E 's|^[^ ]+ on (.*) \(apfs,.*$|\1|'; }
# is a device mounted read-only right now?
ssd_readonly() { mount | awk -v d="$1" 'index($0, d" on ")==1' | grep -q 'read-only'; }

# The same from one snapshot of the mount table, without a process per question (for loops over the volumes).
# ssd_snapshot_mounts takes the snapshot (take it again after mounting or unmounting); ssd_snap_of DEV sets
# SNAP_AT (where it is mounted, empty if not) and SNAP_RO (1 if read-only), and returns 1 if not mounted.
ssd_snapshot_mounts() { local IFS=$'\n'; set -f; SSD_MOUNT_LINES=($(mount)); set +f; }
ssd_snap_of() {
  local l
  SNAP_AT=""; SNAP_RO=0
  for l in ${SSD_MOUNT_LINES[@]+"${SSD_MOUNT_LINES[@]}"}; do
    case $l in "$1 on "*)
      l=${l#"$1 on "}; SNAP_AT=${l% (*}
      case $l in *read-only*) SNAP_RO=1 ;; esac
      return 0 ;;
    esac
  done
  return 1
}
# IORegistry id of the SSD's current USB connection, empty if not attached
ssd_connection_id() { ioreg -r -c IOUSBHostDevice -n "$SSD_USB_NAME" -d 1 2>/dev/null | sed -nE 's/.*<class IOUSBHostDevice, id (0x[0-9a-f]+),.*/\1/p' | head -1; }
