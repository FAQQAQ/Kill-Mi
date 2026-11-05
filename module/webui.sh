#!/system/bin/sh
MODDIR=${0%/*}
. "$MODDIR/lib.sh"
. "$MODDIR/hosts-lib.sh"
. "$MODDIR/privacy-targets.sh"
print_web_status() {
  local requested boot needed rules disabled=0 unknown=0 target current conflict=0 reason planned
  requested=$(hg_read_mode)
  boot=$(hg_boot_mode)
  hg_conflict && conflict=1
  planned="$requested"
  [ "$conflict" = "0" ] || planned=0
  needed=unknown
  case "$boot:$planned" in
    0:0|1:1) needed=0 ;; 0:1|1:0) needed=1 ;;
  esac
  if awk -f "$MODDIR/check-hosts.awk" "$MODDIR/domains.list" /system/etc/hosts >/dev/null 2>&1; then rules=1; else rules=0; fi
  if load_dump; then
    while IFS= read -r target; do
      [ -n "$target" ] || continue
      current=$(component_state "$target")
      [ "$current" != "disabled" ] || disabled=$((disabled + 1))
      case "$current" in unknown|"") unknown=$((unknown + 1)) ;; esac
    done < "$MODDIR/components.list"
  else unknown=5; fi
  reason=$(cat "$STATE_DIR/hosts.reason" 2>/dev/null)
  case "$reason" in auto-conflict|invalid-config|user) ;; *) reason=none ;; esac
  echo "version=v1.0.0"
  echo "hosts_requested=$requested"
  echo "hosts_boot_mode=$boot"
  echo "reboot_required=$needed"
  echo "hosts_rules_ok=$rules"
  echo "components_disabled=$disabled"
  echo "components_unknown=$unknown"
  echo "hosts_conflicts=$conflict"
  echo "hosts_reason=$reason"
  pt_web_status
}
[ "$(id -u)" = "0" ] || { echo "需要 root 权限" >&2; exit 1; }
case "$1" in
  status) print_web_status ;;
  detail) sh "$MODDIR/status.sh"; exit 0 ;;
  scan) [ "$#" -eq 1 ] || exit 1; sh "$MODDIR/scan.sh" ;;
  set-hosts)
    [ "$#" -eq 2 ] || { echo "参数数量错误" >&2; exit 1; }
    case "$2" in 0|1) ;; *) echo "只允许 0 或 1" >&2; exit 1 ;; esac
    [ "$(id -u)" = "0" ] || { echo "需要 root 权限" >&2; exit 1; }
    init_state || exit 1
    acquire_lock || { echo "其他模块操作正在执行，请稍后重试。" >&2; exit 1; }
    trap release_lock EXIT
    trap 'release_lock; exit 1' INT TERM
    hg_set_mode "$2" || exit 1
    release_lock
    print_web_status
    ;;
  *) echo "用法：webui.sh status | detail | scan | set-hosts 0/1" >&2; exit 1 ;;
esac
