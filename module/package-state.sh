#!/system/bin/sh
# Source after lib.sh. Only small PackageManager enabled-state records are saved.
ps_is_target() {
  case "$1" in
    com.miui.guardprovider|com.mobiletools.systemhelper|com.xiaomi.trustservice|\
    com.miui.analytics|com.xiaomi.registration) return 0 ;;
    *) return 1 ;;
  esac
}
ps_is_user() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  case "$1" in 0|[1-9]*) return 0 ;; *) return 1 ;; esac
}
ps_absent_dump() {
  rt_lines "$2" | awk -v package="$1" '
    NF {
      sub(/\r$/, "")
      if($0=="Unable to find package: " package) found++
      else bad=1
    }
    END { exit (bad || found!=1) }'
}
ps_load_package() {
  local package="$1" dump
  PS_ROWS=""
  PS_ABSENT=0
  ps_is_target "$package" || return 1
  dump=$(dumpsys -t 12 package "$package" 2>&1)
  [ "$?" = "0" ] && [ -n "$dump" ] || return 1
  case "$dump" in
    *"DUMP TIMEOUT"*|*"Permission Denial"*|*"SecurityException"*) return 1 ;;
  esac
  if ps_absent_dump "$package" "$dump"; then
    PS_ABSENT=1
    return 0
  fi
  PS_ROWS=$(rt_lines "$dump" |
    awk -v package="$package" -f "$MODDIR/read-package.awk") || return 1
  [ -n "$PS_ROWS" ]
}
ps_user_row() {
  rt_lines "$PS_ROWS" | awk -v user="$1" '
    $1==user { count++; value=$2 " " $3 }
    END {
      if(count==1) print value
      else if(count==0) print "missing unknown"
      else print "unknown unknown"
    }'
}
ps_state_path() {
  printf '%s/original/package.%s.user-%s.state\n' "$STATE_DIR" "$1" "$2"
}
ps_save_state() {
  local package="$1" user="$2" state="$3" path saved
  ps_is_target "$package" && ps_is_user "$user" || return 1
  case "$state" in 0|1|2|3|4) ;; *) return 1 ;; esac
  path=$(ps_state_path "$package" "$user")
  [ ! -L "$path" ] || return 1
  if [ -e "$path" ]; then
    [ -f "$path" ] || return 1
    saved=$(cat "$path")
    case "$saved" in 0|1|2|3|4) return 0 ;; *) return 1 ;; esac
  fi
  printf '%s\n' "$state" > "$path.tmp.$$" &&
    chmod 0600 "$path.tmp.$$" && mv -f "$path.tmp.$$" "$path"
}
ps_state_verb() {
  case "$1" in
    0) echo default-state ;; 1) echo enable ;; 2) echo disable ;;
    3) echo disable-user ;; 4) echo disable-until-used ;; *) return 1 ;;
  esac
}
ps_save_baselines() {
  # The installer already holds the module lock after volume-key confirmation.
  local package user installed state extra failed=0
  init_state || return 1
  [ -r "$MODDIR/masked-packages.list" ] || return 1
  while IFS= read -r package; do
    [ -n "$package" ] || continue
    ps_is_target "$package" || { failed=1; continue; }
    if ! ps_load_package "$package"; then failed=1; continue; fi
    [ "$PS_ABSENT" = "0" ] || continue
    while read -r user installed state extra; do
      [ -n "$user" ] || continue
      if ! ps_is_user "$user" || [ -n "$extra" ]; then failed=1; continue; fi
      case "$installed:$state" in
        false:*) continue ;;
        true:[0-4]) ps_save_state "$package" "$user" "$state" || failed=1 ;;
        *) failed=1 ;;
      esac
    done <<__PS_SAVE_USERS__
$PS_ROWS
__PS_SAVE_USERS__
  done < "$MODDIR/masked-packages.list"
  return "$failed"
}
ps_restore_baselines() {
  # Run as a separate operation/subshell, without a caller-held lock.
  local package path user original installed current extra verb after row needed failed=0
  init_state || return 1
  acquire_lock || return 1
  trap release_lock EXIT
  trap 'release_lock; exit 1' INT TERM
  for package in com.miui.guardprovider com.mobiletools.systemhelper \
      com.xiaomi.trustservice com.miui.analytics com.xiaomi.registration; do
    needed=0
    for path in "$STATE_DIR/original/package.$package.user-"*.state; do
      [ ! -e "$path" ] && [ ! -L "$path" ] || needed=1
    done
    [ "$needed" = "1" ] || continue
    if ! ps_load_package "$package" || [ "$PS_ABSENT" != "0" ]; then
      failed=1
      continue
    fi
    for path in "$STATE_DIR/original/package.$package.user-"*.state; do
      [ -e "$path" ] || [ -L "$path" ] || continue
      if [ -L "$path" ] || [ ! -f "$path" ]; then failed=1; continue; fi
      user=${path##*/package.$package.user-}
      user=${user%.state}
      ps_is_user "$user" || { failed=1; continue; }
      original=$(cat "$path")
      verb=$(ps_state_verb "$original") || { failed=1; continue; }
      row=$(ps_user_row "$user") || { failed=1; continue; }
      read -r installed current extra <<__PS_RESTORE_ROW__
$row
__PS_RESTORE_ROW__
      [ -z "$extra" ] || { failed=1; continue; }
      case "$installed:$current" in
        false:*) rm -f "$path" || failed=1; continue ;;
        true:[0-4]) ;;
        *) failed=1; continue ;;
      esac
      if [ "$current" = "$original" ]; then rm -f "$path" || failed=1; continue; fi
      # A missing masked APK can reset its parent to default. Also undo our
      # disable-user fallback, while preserving later explicit 1/2/4 overrides.
      case "$current" in
        0) ;;
        3)
          if [ "$package" != com.miui.analytics ]; then
            rm -f "$path" || failed=1
            continue
          fi
          ;;
        *) rm -f "$path" || failed=1; continue ;;
      esac
      if ! pm "$verb" --user "$user" "$package" >/dev/null 2>&1; then
        failed=1
        continue
      fi
      if ! ps_load_package "$package" || [ "$PS_ABSENT" != "0" ]; then
        failed=1
        continue
      fi
      after=$(ps_user_row "$user") || { failed=1; continue; }
      if [ "$after" = "true $original" ]; then rm -f "$path" || failed=1
      else failed=1; fi
    done
  done
  release_lock
  return "$failed"
}
