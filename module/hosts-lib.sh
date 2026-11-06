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
  rt_install_write "写入 hosts 设置临时文件" "$path.tmp.$$" "$value" &&
    rt_install_exec "设置 hosts 配置文件权限" chmod 0600 "$path.tmp.$$" &&
    rt_install_exec "保存 hosts 配置文件" mv -f "$path.tmp.$$" "$path"
}
hg_save_mode() {
  case "$1" in
    0|1) hg_write_value "$STATE_DIR/hosts.mode" "$1" ;;
    *) rt_install_error "检查 hosts 开关值" "hosts.mode 必须为 0 或 1" 1 "收到的开关值无效。"; return 1 ;;
  esac
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
  local output rc line
  if [ "${KI_INSTALL_ACTIVE:-0}" = "1" ]; then
    if output=$(sh "$MODDIR/hosts-conflicts.sh" 2>&1); then rc=0; else rc=$?; fi
    if [ "$rc" -gt 1 ]; then
      rt_install_error "检查其他 hosts 模块" "sh $MODDIR/hosts-conflicts.sh" "$rc" "$output"
    else
      while IFS= read -r line || [ -n "$line" ]; do
        ui_print "[hosts 检查] $line"
      done <<__HG_CONFLICT_OUTPUT__
$output
__HG_CONFLICT_OUTPUT__
    fi
    [ "$rc" -ne 0 ]
    return
  fi
  sh "$MODDIR/hosts-conflicts.sh" >/dev/null 2>&1
  [ "$?" -ne 0 ]
}
hg_prepare_payload() {
  local desired="$1" destination="$MODDIR/system/etc/hosts" temporary
  if [ "$desired" = "0" ]; then
    if [ -L "$destination" ]; then
      rt_install_error "关闭 hosts 屏蔽" "检查路径 $destination" 1 "目标 hosts 是符号链接。"
      return 1
    fi
    if [ -e "$destination" ]; then
      [ -f "$destination" ] || {
        rt_install_error "关闭 hosts 屏蔽" "检查路径 $destination" 1 "目标 hosts 存在，但不是普通文件。"
        return 1
      }
      rt_install_exec "创建 hosts 停用目录" mkdir -p "$MODDIR/disabled-payload" || return 1
      rt_install_exec "移出模块 hosts 文件" mv -f "$destination" "$MODDIR/disabled-payload/hosts" || return 1
    fi
    if [ ! -e "$destination" ] && [ ! -L "$destination" ]; then return 0; fi
    rt_install_error "核对 hosts 停用结果" "检查路径 $destination" 1 "模块 hosts 路径仍然存在。"
    return 1
  fi
  [ "$desired" = "1" ] || {
    rt_install_error "准备 hosts 文件" "检查 hosts 开关值" 1 "开关值不是 0 或 1。"
    return 1
  }
  if [ "${KI_INSTALL_ACTIVE:-0}" = "1" ]; then
    rt_install_exec "校验 21 个域名与 hosts 模板" awk -f "$MODDIR/check-hosts.awk" "$MODDIR/domains.list" "$MODDIR/hosts-template" || return 1
  else
    awk -f "$MODDIR/check-hosts.awk" "$MODDIR/domains.list" "$MODDIR/hosts-template" >/dev/null || return 1
  fi
  rt_install_exec "创建模块 hosts 目录" mkdir -p "$MODDIR/system/etc" || return 1
  [ ! -L "$destination" ] || {
    rt_install_error "准备 hosts 文件" "检查路径 $destination" 1 "目标 hosts 是符号链接。"
    return 1
  }
  if [ -e "$destination" ] && [ ! -f "$destination" ]; then
    rt_install_error "准备 hosts 文件" "检查路径 $destination" 1 "目标 hosts 存在，但不是普通文件。"
    return 1
  fi
  temporary="$MODDIR/system/etc/hosts.tmp.$$"
  rt_install_exec "复制 hosts 模板" cp "$MODDIR/hosts-template" "$temporary" &&
    rt_install_exec "设置 hosts 文件权限" chmod 0644 "$temporary" &&
    rt_install_exec "设置 hosts 文件所有者" chown 0:0 "$temporary" &&
    rt_install_exec "设置 hosts 文件 SELinux 标签" chcon u:object_r:system_file:s0 "$temporary" &&
    rt_install_exec "放置模块 hosts 文件" mv -f "$temporary" "$destination"
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
