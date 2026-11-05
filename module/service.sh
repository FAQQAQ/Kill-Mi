#!/system/bin/sh
MODDIR=${0%/*}
. "$MODDIR/lib.sh"
. "$MODDIR/firewall.sh"
. "$MODDIR/privacy-targets.sh"
. "$MODDIR/data-mask.sh"
init_state || exit 1
service_cleanup() {
  (fw_clear)
  (acquire_lock && { dm_cleanup; release_lock; })
}
trap service_cleanup EXIT
trap 'exit 0' INT TERM
log_event "START v1.0.0 ; user=0"
wait_pm || log_event "WAIT package service timeout ; retrying"
while [ -d "$MODDIR" ]; do
  if [ -f "$MODDIR/disable" ] || [ -f "$MODDIR/remove" ] ||
     [ -f "$STATE_DIR/uninstall.pending" ]; then
    log_event "STOP module disabled/removing"
    break
  fi
  (fw_apply)
  (apply_components)
  (pt_apply_targets)
  sleep 60 &
  wait $!
done
