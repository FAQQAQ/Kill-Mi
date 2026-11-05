#!/system/bin/sh
# Source after lib.sh. No UID-level rules are used for these targets.
pt_absent_dump() {
  rt_lines "$2" | awk -v package="$1" '
    function trim(s) {sub(/^[ \t]+/,"",s);sub(/[ \t\r]+$/,"",s);return s}
    function depth(s,t) {t=s;sub(/[^ \t].*$/,"",t);return length(t)}
    NF {
      line=trim($0); indent=depth($0)
      if(line=="Unable to find package: " package) missing=1
      else other=1
      if(line=="Hidden system packages:") {active=0; stopped=1}
      if(line ~ /^Package \[/) {
        active=0
        if(!seen && !stopped && index(line,"Package [" package "]")==1) {
          active=1;seen=1;root=indent
        }
        next
      }
      if(active && indent<=root) active=0
      if(active && indent==root+2 && line=="pkg=null") null_code=1
    }
    END { exit !((missing && !other) || null_code) }'
}
pt_empty_system_dir() {
  local path="$1" visible
  [ -d "$path" ] || return 1
  visible=$(find "$path" -type f -name '*.apk' -print 2>/dev/null) || return 1
  [ -z "$visible" ]
}
pt_is_registration_target() {
  case "$1" in
    com.xiaomi.registration/com.xiaomi.registration.autoregistration.AutoRegReceiver|\
    com.xiaomi.registration/com.xiaomi.registration.autoregistration.AutoRegIntentService|\
    com.xiaomi.registration/com.xiaomi.registration.autoregistration.RegistrationJobService) return 0 ;;
    *) return 1 ;;
  esac
}
pt_active() {
  [ ! -f "$MODULE_DIR/disable" ] && [ ! -f "$MODULE_DIR/remove" ] &&
    [ ! -f "$STATE_DIR/uninstall.pending" ]
}
pt_load_registration() {
  PT_REG_ABSENT=0
  PT_REG_DUMP=$(dumpsys -t 12 package --all-components com.xiaomi.registration 2>&1)
  [ "$?" = "0" ] && [ -n "$PT_REG_DUMP" ] || return 1
  case "$PT_REG_DUMP" in *"DUMP TIMEOUT"*) return 1 ;; esac
  if pt_absent_dump com.xiaomi.registration "$PT_REG_DUMP"; then
    PT_REG_ABSENT=1
    PT_REG_USERS=""
    return 0
  fi
  PT_REG_USERS=$(rt_lines "$PT_REG_DUMP" |
    awk -v package=com.xiaomi.registration -f "$MODDIR/read-package.awk") || return 1
  [ -n "$PT_REG_USERS" ]
}
pt_registration_state() {
  [ "${PT_REG_ABSENT:-0}" != "1" ] || { echo absent; return; }
  local value
  value=$(rt_lines "$PT_REG_DUMP" |
    awk -v component="$1" -v user_id=0 -f "$MODDIR/read-component.awk") || value=unknown
  case "$value" in default|enabled|disabled|absent|user-absent) echo "$value" ;; *) echo unknown ;; esac
}
pt_load_analytics() {
  local dump
  PT_ANALYTICS_ROWS=""
  PT_ANALYTICS_ABSENT=0
  dump=$(dumpsys -t 12 package com.miui.analytics 2>&1)
  [ "$?" = "0" ] && [ -n "$dump" ] || return 1
  case "$dump" in *"DUMP TIMEOUT"*) return 1 ;; esac
  if pt_absent_dump com.miui.analytics "$dump"; then
    PT_ANALYTICS_ABSENT=1
    return 0
  fi
  PT_ANALYTICS_ROWS=$(rt_lines "$dump" |
    awk -v package=com.miui.analytics -f "$MODDIR/read-package.awk") || return 1
  [ -n "$PT_ANALYTICS_ROWS" ]
}
pt_analytics_state() {
  local value
  value=$(rt_lines "$PT_ANALYTICS_ROWS" | awk -v user="$1" '
    $1==user { found++; if($2=="false") value="absent"; else if($2=="true" && $3~/^[0-4]$/) value=$3; else value="unknown" }
    END { if(found==1) print value; else print "unknown" }') || value=unknown
  case "$value" in 0|1|2|3|4|absent) echo "$value" ;; *) echo unknown ;; esac
}
pt_package_path() {
  printf '%s/original/package.com.miui.analytics.user-%s.state\n' "$STATE_DIR" "$1"
}
pt_save_package() {
  local path="$1" state="$2" saved
  case "$state" in 0|1|2|3|4) ;; *) return 1 ;; esac
  if [ -f "$path" ]; then
    saved=$(cat "$path")
    case "$saved" in 0|1|2|3|4) return 0 ;; *) return 1 ;; esac
  fi
  printf '%s\n' "$state" > "$path.tmp.$$" &&
    chmod 0600 "$path.tmp.$$" && mv -f "$path.tmp.$$" "$path"
}
pt_package_verb() {
  case "$1" in
    0) echo default-state ;; 1) echo enable ;; 2) echo disable ;;
    3) echo disable-user ;; 4) echo disable-until-used ;; *) return 1 ;;
  esac
}
pt_apply_targets() {
  local target before after user installed state path failed=0
  init_state || return 1
  acquire_lock || return 1
  trap release_lock EXIT
  trap 'release_lock; exit 1' INT TERM
  pt_active || { release_lock; return 0; }
  ensure_recovery || { release_lock; return 1; }
  if pt_load_registration; then
    while IFS= read -r target; do
      [ -n "$target" ] || continue
      pt_is_registration_target "$target" || { failed=1; continue; }
      before=$(pt_registration_state "$target")
      case "$before" in
        absent|user-absent) continue ;; unknown) failed=1; continue ;;
      esac
      save_original "$target" "$before" || { failed=1; continue; }
      [ "$before" != "disabled" ] || continue
      pt_active || break
      if ! pm disable --user 0 "$target" >/dev/null 2>&1; then failed=1; continue; fi
      if pt_load_registration; then after=$(pt_registration_state "$target"); else after=unknown; fi
      [ "$after" = "disabled" ] || failed=1
    done < "$MODDIR/registration-components.list"
  else failed=1; fi
  if pt_load_analytics; then
    while read -r user installed state; do
      [ -n "$user" ] || continue
      case "$installed:$state" in false:*) continue ;; true:[0-4]) ;; *) failed=1; continue ;; esac
      path=$(pt_package_path "$user")
      pt_save_package "$path" "$state" || { failed=1; continue; }
      case "$state" in 2|3) continue ;; esac
      pt_active || break
      if ! pm disable-user --user "$user" com.miui.analytics >/dev/null 2>&1; then failed=1; continue; fi
      if pt_load_analytics; then after=$(pt_analytics_state "$user"); else after=unknown; fi
      [ "$after" = "3" ] || failed=1
    done <<__PT_ANALYTICS_USERS__
$PT_ANALYTICS_ROWS
__PT_ANALYTICS_USERS__
  else failed=1; fi
  release_lock
  return "$failed"
}
pt_restore_targets() {
  local target path original current after verb user failed=0 reg_needed=0 analytics_needed=0
  init_state || return 1
  acquire_lock || return 1
  trap release_lock EXIT
  trap 'release_lock; exit 1' INT TERM
  while IFS= read -r target; do
    [ -n "$target" ] || continue
    pt_is_registration_target "$target" || { failed=1; continue; }
    path=$(backup_path "$target")
    [ ! -f "$path" ] || reg_needed=1
  done < "$MODDIR/registration-components.list"
  if [ "$reg_needed" = "1" ]; then
    if pt_load_registration && [ "$PT_REG_ABSENT" = "0" ]; then
      while IFS= read -r target; do
        [ -n "$target" ] || continue
        pt_is_registration_target "$target" || { failed=1; continue; }
        path=$(backup_path "$target")
        [ -f "$path" ] || continue
        original=$(cat "$path")
        case "$original" in default) verb=default-state ;; enabled) verb=enable ;; disabled) verb=disable ;; *) failed=1; continue ;; esac
        current=$(pt_registration_state "$target")
        case "$current" in
          absent|user-absent) rm -f "$path"; continue ;;
          unknown) failed=1; continue ;;
        esac
        if [ "$current" = "$original" ] || [ "$current" != "disabled" ]; then rm -f "$path"; continue; fi
        if ! pm "$verb" --user 0 "$target" >/dev/null 2>&1; then failed=1; continue; fi
        if pt_load_registration; then after=$(pt_registration_state "$target"); else after=unknown; fi
        if [ "$after" = "$original" ]; then rm -f "$path"; else failed=1; fi
      done < "$MODDIR/registration-components.list"
    else failed=1; fi
  fi
  for path in "$STATE_DIR"/original/package.com.miui.analytics.user-*.state; do
    [ ! -f "$path" ] || analytics_needed=1
  done
  if [ "$analytics_needed" = "1" ]; then
    if pt_load_analytics; then
      for path in "$STATE_DIR"/original/package.com.miui.analytics.user-*.state; do
        [ -f "$path" ] || continue
        user=${path##*/package.com.miui.analytics.user-}
        user=${user%.state}
        case "$user" in ''|*[!0-9]*) failed=1; continue ;; esac
        original=$(cat "$path")
        verb=$(pt_package_verb "$original") || { failed=1; continue; }
        current=$(pt_analytics_state "$user")
        case "$current" in absent) rm -f "$path"; continue ;; unknown) failed=1; continue ;; esac
        # Only undo our disable-user state. Other later overrides are retained.
        if [ "$current" = "$original" ] || [ "$current" != "3" ]; then rm -f "$path"; continue; fi
        if ! pm "$verb" --user "$user" com.miui.analytics >/dev/null 2>&1; then failed=1; continue; fi
        if pt_load_analytics; then after=$(pt_analytics_state "$user"); else after=unknown; fi
        if [ "$after" = "$original" ]; then rm -f "$path"; else failed=1; fi
      done
    else failed=1; fi
  fi
  release_lock
  return "$failed"
}
pt_read_status() {
  local target state user installed
  PT_REG_MODE=frozen
  PT_ANALYTICS_MODE=frozen
  PT_REG_DISABLED=0
  PT_REG_UNKNOWN=0
  PT_ANALYTICS_DISABLED=0
  PT_ANALYTICS_TOTAL=0
  PT_ANALYTICS_UNKNOWN=0
  if pt_load_registration; then
    while IFS= read -r target; do
      [ -n "$target" ] || continue
      if ! pt_is_registration_target "$target"; then PT_REG_UNKNOWN=$((PT_REG_UNKNOWN+1)); continue; fi
      state=$(pt_registration_state "$target")
      case "$state" in disabled) PT_REG_DISABLED=$((PT_REG_DISABLED+1)) ;; unknown) PT_REG_UNKNOWN=$((PT_REG_UNKNOWN+1)) ;; esac
    done < "$MODDIR/registration-components.list"
  else PT_REG_UNKNOWN=3; fi
  if pt_load_analytics; then
    while read -r user installed state; do
      [ -n "$user" ] || continue
      case "$installed" in
        false) continue ;;
        true)
          PT_ANALYTICS_TOTAL=$((PT_ANALYTICS_TOTAL+1))
          case "$state" in 2|3) PT_ANALYTICS_DISABLED=$((PT_ANALYTICS_DISABLED+1)) ;; 0|1|4) ;; *) PT_ANALYTICS_UNKNOWN=$((PT_ANALYTICS_UNKNOWN+1)) ;; esac
          ;;
        *) PT_ANALYTICS_UNKNOWN=$((PT_ANALYTICS_UNKNOWN+1)) ;;
      esac
    done <<__PT_ANALYTICS_STATUS__
$PT_ANALYTICS_ROWS
__PT_ANALYTICS_STATUS__
  else PT_ANALYTICS_UNKNOWN=1; fi
  if [ "${PT_REG_ABSENT:-0}" = "1" ]; then
    PT_REG_MODE=absent
    pt_empty_system_dir /product/priv-app/AutoRegistration && PT_REG_MODE=masked
  fi
  if [ "${PT_ANALYTICS_ABSENT:-0}" = "1" ] || [ "$PT_ANALYTICS_TOTAL:$PT_ANALYTICS_UNKNOWN" = "0:0" ]; then
    PT_ANALYTICS_MODE=absent
    pt_empty_system_dir /product/app/AnalyticsCore && PT_ANALYTICS_MODE=masked
  fi
}
pt_web_status() {
  pt_read_status
  printf 'registration_mode=%s\nanalytics_mode=%s\n' "$PT_REG_MODE" "$PT_ANALYTICS_MODE"
  printf 'registration_disabled=%s\nregistration_unknown=%s\n' "$PT_REG_DISABLED" "$PT_REG_UNKNOWN"
  printf 'analytics_disabled=%s\nanalytics_total=%s\nanalytics_unknown=%s\n' "$PT_ANALYTICS_DISABLED" "$PT_ANALYTICS_TOTAL" "$PT_ANALYTICS_UNKNOWN"
}
pt_detail() {
  local target state user installed seen=0
  echo '--- 运营商注册组件（user 0）---'
  if pt_load_registration; then
    while IFS= read -r target; do
      [ -n "$target" ] || continue
      pt_is_registration_target "$target" || continue
      state=$(pt_registration_state "$target")
      printf '%s : %s\n' "$state" "${target#*/}"
    done < "$MODDIR/registration-components.list"
  else echo '状态读取失败'; fi
  echo '--- Analytics ---'
  if pt_load_analytics; then
    while read -r user installed state; do
      [ -n "$user" ] || continue
      [ "$installed" != "false" ] || continue
      seen=1
      if [ "$installed" != "true" ]; then state=unknown; fi
      case "$state" in 0) state='默认' ;; 1) state='已启用' ;; 2) state='已禁用' ;; 3) state='已禁用（用户）' ;; 4) state='停用至使用' ;; *) state='未知' ;; esac
      printf 'user %s：%s\n' "$user" "$state"
    done <<__PT_ANALYTICS_DETAIL__
$PT_ANALYTICS_ROWS
__PT_ANALYTICS_DETAIL__
    if [ "$seen" = "0" ]; then
      if [ "${PT_ANALYTICS_ABSENT:-0}" = "1" ] && pt_empty_system_dir /product/app/AnalyticsCore; then echo '已遮蔽，包管理器未登记'
      else echo '未发现已安装用户'; fi
    fi
  else echo '状态读取失败'; fi
}
