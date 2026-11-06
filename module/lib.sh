#!/system/bin/sh
# Sourced by module scripts and the self-contained uninstall recovery copy.
STATE_DIR=/data/adb/xsof_guard_local
MODULE_DIR=/data/adb/modules/xsof_guard_local
LOCKED=0

. "$MODDIR/runtime.sh"
rt_setup

init_state() {
  umask 077
  rt_install_exec "创建原状态与偏好保存目录" mkdir -p "$STATE_DIR/original" "$STATE_DIR/recovery" || return 1
  rt_install_exec "设置保存目录权限（0700）" chmod 0700 "$STATE_DIR" "$STATE_DIR/original" "$STATE_DIR/recovery" || return 1
  rt_install_exec "清理四个旧记录文件" rm -f "$STATE_DIR/events.log" "$STATE_DIR/events.previous.log" \
    "$STATE_DIR/recovery-output.log" "$STATE_DIR/firewall.last" || return 1
}
log_event() {
  :
}
release_lock() {
  if [ "$LOCKED" = "1" ]; then
    rt_install_exec "清理模块操作锁记录" rm -f "$STATE_DIR/lock/pid" "$STATE_DIR/lock/boot"
    rt_install_exec "删除模块操作锁目录" rmdir "$STATE_DIR/lock" 2>/dev/null
    LOCKED=0
  fi
}
acquire_lock() {
  local tries=0 owner saved_boot this_boot lock_error lock_rc=0
  this_boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
  while :; do
    if lock_error=$(mkdir "$STATE_DIR/lock" 2>&1); then break
    else lock_rc=$?; fi
    owner=$(cat "$STATE_DIR/lock/pid" 2>/dev/null)
    saved_boot=$(cat "$STATE_DIR/lock/boot" 2>/dev/null)
    case "$owner" in
      ''|*[!0-9]*)
        if [ "$tries" -ge 5 ]; then
          # Remove only an empty, abandoned initialization lock.
          rmdir "$STATE_DIR/lock" 2>/dev/null
        fi
        ;;
      *)
        if [ -n "$saved_boot" ] && [ "$saved_boot" != "$this_boot" ] ||
           ! kill -0 "$owner" 2>/dev/null; then
          rm -f "$STATE_DIR/lock/pid" "$STATE_DIR/lock/boot"
          rmdir "$STATE_DIR/lock" 2>/dev/null
        fi
        ;;
    esac
    tries=$((tries + 1))
    if [ "$tries" -ge 30 ]; then
      rt_install_error "获取模块操作锁（已重试 30 次）" "mkdir $STATE_DIR/lock" "$lock_rc" \
        "$lock_error
锁目录：$STATE_DIR/lock
记录的进程：${owner:-未记录}；记录的启动标识：${saved_boot:-未记录}"
      return 1
    fi
    sleep 1
  done
  LOCKED=1
  rt_install_write "写入锁的启动标识" "$STATE_DIR/lock/boot" "$this_boot"
  rt_install_write "写入锁的进程号" "$STATE_DIR/lock/pid" "$$"
}
wait_pm() {
  local tries=0
  while [ "$tries" -lt 120 ]; do
    if pm path android 2>/dev/null | grep -q '^package:'; then return 0; fi
    sleep 2
    tries=$((tries + 1))
  done
  return 1
}
load_dump() {
  DUMP_ERROR=""
  DUMP_RC=0
  DUMP=$(dumpsys -t 12 package --all-components com.miui.securitycenter 2>&1)
  DUMP_RC=$?
  if [ "$DUMP_RC" -ne 0 ]; then
    DUMP_ERROR="dumpsys rc=$DUMP_RC: $(rt_lines "$DUMP" | head -1)"
    return 1
  fi
  [ -n "$DUMP" ] || { DUMP_ERROR="dumpsys 返回为空"; return 1; }
  case "$DUMP" in
    *"DUMP TIMEOUT"*) DUMP_ERROR="dumpsys 超时"; return 1 ;;
  esac
  if ! rt_lines "$DUMP" | awk '
    /^[ \t]*Package \[com\.miui\.securitycenter\]/ { found=1 }
    END { exit !found }'; then
    DUMP_ERROR="未返回手机管家包块：$(rt_lines "$DUMP" | head -1)"
    return 1
  fi
}
component_state() {
  local parsed
  parsed=$(rt_lines "$DUMP" |
    awk -v component="$1" -v user_id=0 -f "$MODDIR/read-component.awk" 2>/dev/null) || {
      echo unknown
      return
    }
  case "$parsed" in default|enabled|disabled|absent|user-absent|unknown) echo "$parsed" ;; *) echo unknown ;; esac
}
component_diagnostic() {
  rt_lines "$DUMP" |
    awk -v component="$1" -v user_id=0 -v diagnose=1 -f "$MODDIR/read-component.awk"
}
is_target() {
  case "$1" in
    com.miui.securitycenter/com.xiaomi.security.xsof.frauddetection.service.MiFraudDetectionService|\
    com.miui.securitycenter/com.xiaomi.security.xsof.MiSafetyDetectService|\
    com.miui.securitycenter/com.xiaomi.security.xsof.frauddetection.provider.FraudDetectionProvider|\
    com.miui.securitycenter/com.xiaomi.security.xsof.XSOFProvider|\
    com.miui.securitycenter/com.miui.antifraud.AntiFraudReceiver) return 0 ;;
    *) return 1 ;;
  esac
}
backup_path() {
  printf '%s/original/%s.state\n' "$STATE_DIR" "${1#*/}"
}
save_original() {
  local target="$1" state="$2" path saved
  path=$(backup_path "$target")
  if [ -f "$path" ]; then
    saved=$(cat "$path")
    case "$saved" in default|enabled|disabled) return 0 ;; *) return 1 ;; esac
  fi
  case "$state" in default|enabled|disabled) ;; *) return 1 ;; esac
  printf '%s\n' "$state" > "$path.tmp.$$" &&
    chmod 0600 "$path.tmp.$$" && mv -f "$path.tmp.$$" "$path"
}
ensure_recovery() {
  local file
  for file in lib.sh runtime.sh firewall.sh read-component.awk components.list recover.sh \
      privacy-targets.sh read-package.awk registration-components.list \
      data-mask.sh masked-packages.list extra-mask-paths.list package-state.sh; do
    cp "$MODDIR/$file" "$STATE_DIR/recovery/$file.tmp" &&
      chmod 0600 "$STATE_DIR/recovery/$file.tmp" &&
      mv -f "$STATE_DIR/recovery/$file.tmp" "$STATE_DIR/recovery/$file" || return 1
  done
  rm -f "$STATE_DIR/recovery/legacy-uid-cleanup.sh"
}
apply_components() {
  local target before after output failed=0
  init_state || return 1
  acquire_lock || return 1
  trap release_lock EXIT
  trap 'release_lock; exit 1' INT TERM
  if [ -f "$MODULE_DIR/disable" ] || [ -f "$MODULE_DIR/remove" ] ||
     [ -f "$STATE_DIR/uninstall.pending" ]; then release_lock; return 0; fi
  ensure_recovery || { log_event "FAIL recovery-copy"; release_lock; return 1; }
  load_dump || { log_event "FAIL package-dump :: $DUMP_ERROR"; release_lock; return 1; }
  while IFS= read -r target; do
    [ -n "$target" ] || continue
    is_target "$target" || { log_event "FAIL unexpected-target"; failed=1; continue; }
    before=$(component_state "$target")
    case "$before" in
      absent|user-absent) continue ;;
      unknown) log_event "UNKNOWN $target ; no change"; failed=1; continue ;;
      default|enabled|disabled) ;;
      *) failed=1; continue ;;
    esac
    save_original "$target" "$before" || {
      log_event "FAIL backup $target ; no change"; failed=1; continue;
    }
    [ "$before" = "disabled" ] && continue
    if [ -f "$MODULE_DIR/disable" ] || [ -f "$MODULE_DIR/remove" ] ||
       [ -f "$STATE_DIR/uninstall.pending" ]; then break; fi
    output=$(pm disable --user 0 "$target" 2>&1)
    if [ "$?" -ne 0 ]; then
      log_event "FAIL disable $target :: $output"; failed=1; continue
    fi
    if load_dump; then after=$(component_state "$target"); else after=unknown; fi
    if [ "$after" = "disabled" ]; then
      log_event "DISABLED $target ; original=$before"
    else
      log_event "FAIL verify $target ; observed=$after :: $output"
      failed=1
    fi
  done < "$MODDIR/components.list"
  release_lock
  return "$failed"
}
restore_components() {
  local target original current expected verb output path failed=0
  init_state || return 1
  acquire_lock || return 1
  trap release_lock EXIT
  trap 'release_lock; exit 1' INT TERM
  load_dump || { log_event "FAIL restore package-dump :: $DUMP_ERROR"; release_lock; return 1; }
  while IFS= read -r target; do
    [ -n "$target" ] || continue
    is_target "$target" || { failed=1; continue; }
    path=$(backup_path "$target")
    [ -f "$path" ] || continue
    original=$(cat "$path")
    case "$original" in
      default) verb=default-state ;;
      enabled) verb=enable ;;
      disabled) verb=disable ;;
      *) log_event "FAIL invalid-backup $target"; failed=1; continue ;;
    esac
    current=$(component_state "$target")
    case "$current" in
      absent|user-absent)
        log_event "RESTORE-SKIP absent $target"
        rm -f "$path"
        continue
        ;;
      unknown)
        log_event "FAIL restore unknown $target"; failed=1; continue
        ;;
    esac
    if [ "$current" = "$original" ]; then
      log_event "RESTORED unchanged $target ; state=$original"
      rm -f "$path"
      continue
    fi
    # Respect a later user/other-module override; only undo our disabled state.
    if [ "$current" != "disabled" ]; then
      log_event "RESTORE-SKIP external-change $target ; current=$current"
      rm -f "$path"
      continue
    fi
    output=$(pm "$verb" --user 0 "$target" 2>&1)
    if [ "$?" -ne 0 ]; then
      log_event "FAIL restore $target :: $output"; failed=1; continue
    fi
    if load_dump; then expected=$(component_state "$target"); else expected=unknown; fi
    if [ "$expected" = "$original" ]; then
      log_event "RESTORED $target ; state=$original"
      rm -f "$path"
    else
      log_event "FAIL restore-verify $target ; observed=$expected"
      failed=1
    fi
  done < "$MODDIR/components.list"
  release_lock
  return "$failed"
}
