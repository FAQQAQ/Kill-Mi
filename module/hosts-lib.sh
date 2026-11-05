#!/system/bin/sh
# Requires lib.sh to have been sourced. Never sourced by uninstall recovery.
hg_read_mode() {
  local value
  if [ ! -f "$STATE_DIR/hosts.mode" ]; then echo 1; return; fi
  value=$(cat "$STATE_DIR/hosts.mode" 2>/dev/null)
  case "$value" in 0|1) echo "$value" ;; *) echo unknown ;; esac
}
hg_write_value() {
  local path="$1" value="$2"
  printf '%s\n' "$value" > "$path.tmp.$$" &&
    chmod 0600 "$path.tmp.$$" && mv -f "$path.tmp.$$" "$path"
}
hg_save_mode() {
  case "$1" in 0|1) hg_write_value "$STATE_DIR/hosts.mode" "$1" ;; *) return 1 ;; esac
}
hg_boot_mode() {
  local saved_id mode extra current_id
  [ -f "$STATE_DIR/hosts.boot" ] || { echo unknown; return; }
  read -r saved_id mode extra < "$STATE_DIR/hosts.boot"
  current_id=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
  if [ -z "$current_id" ] || [ "$saved_id" != "$current_id" ] || [ -n "$extra" ]; then
    echo unknown
    return
  fi
  case "$mode" in 0|1) echo "$mode" ;; *) echo unknown ;; esac
}
hg_record_boot() {
  local boot_id
  boot_id=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
  [ -n "$boot_id" ] || return 1
  hg_write_value "$STATE_DIR/hosts.boot" "$boot_id $1"
}
hg_conflict() {
  sh "$MODDIR/hosts-conflicts.sh" >/dev/null 2>&1
  [ "$?" -ne 0 ]
}
hg_prepare_payload() {
  local desired="$1" destination="$MODDIR/system/etc/hosts" temporary
  if [ "$desired" = "0" ]; then
    if [ -L "$destination" ]; then return 1; fi
    if [ -e "$destination" ]; then
      [ -f "$destination" ] || return 1
      mkdir -p "$MODDIR/disabled-payload" || return 1
      mv -f "$destination" "$MODDIR/disabled-payload/hosts" || return 1
    fi
    [ ! -e "$destination" ] && [ ! -L "$destination" ]
    return
  fi
  [ "$desired" = "1" ] || return 1
  awk -f "$MODDIR/check-hosts.awk" "$MODDIR/domains.list" "$MODDIR/hosts-template" >/dev/null || return 1
  mkdir -p "$MODDIR/system/etc" || return 1
  [ ! -L "$destination" ] || return 1
  if [ -e "$destination" ] && [ ! -f "$destination" ]; then return 1; fi
  temporary="$MODDIR/system/etc/hosts.tmp.$$"
  cp "$MODDIR/hosts-template" "$temporary" &&
    chmod 0644 "$temporary" &&
    chown 0:0 "$temporary" &&
    chcon u:object_r:system_file:s0 "$temporary" &&
    mv -f "$temporary" "$destination"
}
hg_prepare_from_mode() {
  local mode
  mode=$(hg_read_mode)
  case "$mode" in
    0|1) ;;
    *)
      hg_prepare_payload 0 || return 1
      hg_save_mode 0 || return 1
      hg_write_value "$STATE_DIR/hosts.reason" invalid-config || return 1
      mode=0
      ;;
  esac
  if [ "$mode" = "1" ] && hg_conflict; then
    hg_prepare_payload 0 || return 1
    hg_save_mode 0 || return 1
    hg_write_value "$STATE_DIR/hosts.reason" auto-conflict || return 1
    log_event "HOSTS 自动关闭：检测到其他标准 hosts 模块"
    mode=0
  else
    hg_prepare_payload "$mode" || return 1
    hg_save_mode "$mode" || return 1
  fi
  HG_EFFECTIVE="$mode"
}
hg_set_mode() {
  local desired="$1"
  case "$desired" in 0|1) ;; *) echo "只允许 0 或 1" >&2; return 1 ;; esac
  [ ! -f "$MODULE_DIR/disable" ] && [ ! -f "$MODULE_DIR/remove" ] &&
    [ ! -f "$STATE_DIR/uninstall.pending" ] || {
      echo "模块已停用或正在卸载，不能修改 hosts 开关。" >&2; return 1;
    }
  if [ "$desired" = "1" ] && hg_conflict; then
    echo "检测到其他模块提供 hosts。请保持本模块 hosts 关闭，将域名交给现有软件。" >&2
    return 1
  fi
  hg_prepare_payload "$desired" || { echo "准备下次启动的 hosts 文件失败，设置未确认。" >&2; return 1; }
  hg_save_mode "$desired" || { echo "保存开关失败。" >&2; return 1; }
  hg_write_value "$STATE_DIR/hosts.reason" user
  log_event "HOSTS 开关保存=$desired；重启后生效"
}
