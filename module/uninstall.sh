#!/system/bin/sh
MODDIR=${0%/*}
. "$MODDIR/lib.sh"
. "$MODDIR/firewall.sh"
. "$MODDIR/data-mask.sh"
init_state || exit 1
# This script can run before package service. The worker must survive removal
# of MODDIR, so keep all its dependencies in a private /data/adb directory.
acquire_lock || exit 1
trap release_lock EXIT
trap 'release_lock; exit 1' INT TERM
ensure_recovery || { release_lock; exit 1; }
touch "$STATE_DIR/uninstall.pending" || { release_lock; exit 1; }
release_lock
(fw_clear) || log_event "FAIL UID cleanup ; recovery will retry"
(acquire_lock && { dm_cleanup; release_lock; })
if ! rt_spawn_recovery "$STATE_DIR/recovery/recover.sh" /dev/null; then
  log_event "FAIL recovery-launch ; backup retained"
  exit 1
fi
