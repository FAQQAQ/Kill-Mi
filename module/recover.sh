#!/system/bin/sh
MODDIR=${0%/*}
. "$MODDIR/lib.sh"
. "$MODDIR/firewall.sh"
. "$MODDIR/privacy-targets.sh"
. "$MODDIR/data-mask.sh"
. "$MODDIR/package-state.sh"
init_state || exit 1
# Do not fight an active module. This copy is usable after module deletion.
if [ -d "$MODULE_DIR" ] && [ ! -f "$MODULE_DIR/disable" ] &&
   [ ! -f "$MODULE_DIR/remove" ] && [ ! -f "$STATE_DIR/uninstall.pending" ]; then
  echo "模块仍启用；请先在 Magisk 中移除模块并重启。"
  exit 1
fi
log_event "RESTORE-START"
firewall_cleanup=0
(fw_clear) || firewall_cleanup=1
data_cleanup=0
(acquire_lock && { dm_cleanup; result=$?; release_lock; exit "$result"; }) || data_cleanup=1
wait_pm || {
  log_event "FAIL restore package service timeout ; backup retained"
  exit 1
}
attempt=0
while [ "$attempt" -lt 5 ]; do
  components_restored=0
  restore_components || components_restored=1
  ps_restore_baselines || components_restored=1
  pt_restore_targets || components_restored=1
  [ "$firewall_cleanup" = "0" ] || { (fw_clear) && firewall_cleanup=0; }
  if [ "$data_cleanup" != "0" ]; then
    (acquire_lock && { dm_cleanup; result=$?; release_lock; exit "$result"; }) && data_cleanup=0
  fi
  [ "$components_restored:$firewall_cleanup:$data_cleanup" != "0:0:0" ] || break
  attempt=$((attempt + 1))
  [ "$attempt" -ge 5 ] || sleep 2
done
if [ "$components_restored:$firewall_cleanup:$data_cleanup" = "0:0:0" ]; then
  rm -f "$STATE_DIR/uninstall.pending" "$STATE_DIR/hosts.mode" "$STATE_DIR/hosts.reason" "$STATE_DIR/hosts.boot" "$STATE_DIR/firewall.last" "$STATE_DIR/firewall.boot"
  log_event "RESTORE-DONE"
  echo "组件已恢复，UID 后备规则已清理；hosts 与目录遮蔽随重启撤销。"
else
  log_event "RESTORE-INCOMPLETE ; backup retained for retry"
  echo "部分恢复失败，原状态记录保留在 ${STATE_DIR}。"
  exit 1
fi
