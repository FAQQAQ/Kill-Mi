#!/system/bin/sh
MODDIR=${0%/*}
. "$MODDIR/lib.sh"
. "$MODDIR/hosts-lib.sh"
. "$MODDIR/data-mask.sh"
init_state || exit 1
# Only this boot entry writes early mounts. Do not wait for hosts/PM locks first.
dm_apply || :
acquire_lock || exit 1
trap release_lock EXIT
trap 'release_lock; exit 1' INT TERM
# An older uninstall worker cannot survive this reboot. Keep its unfinished
# component state records, while resuming the newly confirmed installation.
reinstall=0
if [ -f "$MODDIR/reinstall.hosts-mode" ]; then
  saved_mode=$(cat "$MODDIR/reinstall.hosts-mode" 2>/dev/null)
  case "$saved_mode" in
    0|1) hg_save_mode "$saved_mode" || exit 1; reinstall=1 ;;
  esac
fi
if hg_prepare_from_mode; then
  if [ "$reinstall" = "1" ]; then
    rm -f "$STATE_DIR/uninstall.pending" "$MODDIR/reinstall.hosts-mode" || exit 1
    log_event "重新安装已启用"
  fi
  hg_record_boot "$HG_EFFECTIVE" || log_event "HOSTS 启动记录写入失败"
else
  hg_record_boot unknown
  log_event "HOSTS 文件准备失败；状态未知，请检查"
  exit 1
fi
