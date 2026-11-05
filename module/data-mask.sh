#!/system/bin/sh
# Source after lib.sh. Boot apply is a singleton; cleanup uses the module lock.
DM_APP_ROOT=/data/app
DM_MOUNTINFO=/proc/self/mountinfo
DM_BOOTID=/proc/sys/kernel/random/boot_id
DM_SOURCE=xsof_guard_mask
# Empty in production; local mock tests may explicitly set a temporary prefix.
DM_EXTRA_TEST_ROOT=""
dm_active() {
  [ ! -f "$MODULE_DIR/disable" ] && [ ! -f "$MODULE_DIR/remove" ] || return 1
  [ -f "$STATE_DIR/uninstall.pending" ] || return 0
  case "$(cat "$MODDIR/reinstall.hosts-mode" 2>/dev/null)" in 0|1) return 0 ;; *) return 1 ;; esac
}
dm_allowed_package() {
  case "$1" in
    com.miui.guardprovider|com.mobiletools.systemhelper|com.xiaomi.trustservice|com.miui.analytics|com.xiaomi.registration) return 0 ;;
    *) return 1 ;;
  esac
}
dm_namespace_ok() {
  local current global
  current=$(readlink /proc/self/ns/mnt 2>/dev/null)
  global=$(readlink /proc/1/ns/mnt 2>/dev/null)
  [ -n "$current" ] && [ "$current" = "$global" ]
}
dm_root_ok() {
  local canonical
  [ -d "$DM_APP_ROOT" ] && [ ! -L "$DM_APP_ROOT" ] &&
    [ -r "$DM_APP_ROOT" ] && [ -x "$DM_APP_ROOT" ] || return 1
  canonical=$(cd "$DM_APP_ROOT" 2>/dev/null && pwd -P) || return 1
  [ "$canonical" = "$DM_APP_ROOT" ]
}
dm_valid_path() {
  local package="$1" path="$2" relative parent basename suffix canonical
  dm_allowed_package "$package" || return 1
  case "$path" in ''|*[!A-Za-z0-9_./=+~-]*) return 1 ;; esac
  case "$path" in "$DM_APP_ROOT"/*) relative=${path#"$DM_APP_ROOT"/} ;; *) return 1 ;; esac
  case "$relative" in
    "$package"-*) case "$relative" in */*) return 1 ;; esac ;;
    '~~'*/*)
      parent=${relative%/*}
      case "$parent" in */*|'~~') return 1 ;; esac
      basename=${relative##*/}
      case "$basename" in "$package"-*) ;; *) return 1 ;; esac
      [ ! -L "$DM_APP_ROOT/$parent" ] || return 1
      ;;
    *) return 1 ;;
  esac
  basename=${path##*/}
  suffix=${basename#"$package"-}
  case "$suffix" in ''|*[!A-Za-z0-9_=+-]*) return 1 ;; esac
  [ -d "$path" ] && [ ! -L "$path" ] || return 1
  canonical=$(cd "$path" 2>/dev/null && pwd -P) || return 1
  [ "$canonical" = "$path" ]
}
dm_extra_row_allowed() {
  case "$1|$2|$3|$4" in
    'com.mobiletools.systemhelper|/mi_ext/system/priv-app/com.mobiletools.systemhelper|com.mobiletools.systemhelper.apk|42fbfebedd8711b2ca22d3d969324f7ed7c757d838e143bf6cf4d2e8e1ed8556'|\
    'com.mobiletools.systemhelper|/mnt/vendor/mi_ext/system/priv-app/com.mobiletools.systemhelper|com.mobiletools.systemhelper.apk|42fbfebedd8711b2ca22d3d969324f7ed7c757d838e143bf6cf4d2e8e1ed8556'|\
    'com.mobiletools.systemhelper|/product/pangu/system/priv-app/SystemHelper|SystemHelper.apk|1de8d965e295db27e189aa179cdb45438d7f759cffbb43ce55f840b614ff6c65'|\
    'com.mobiletools.systemhelper|/mi_ext/system/priv-app/SystemHelper|SystemHelper.apk|e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'|\
    'com.mobiletools.systemhelper|/mnt/vendor/mi_ext/system/priv-app/SystemHelper|SystemHelper.apk|e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'|\
    'com.mobiletools.systemhelper|/system/priv-app/SystemHelper|SystemHelper.apk|e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'|\
    'com.miui.analytics|/data/app/vmdl1090565328.tmp|m.apk|a3656199f013e2f68bc20022f941122a13ce99e33c5df1cef054c9267189d73f') return 0 ;;
    *) return 1 ;;
  esac
}
dm_extra_actual() {
  case "$DM_EXTRA_TEST_ROOT" in
    "") printf '%s\n' "$1" ;;
    /*) printf '%s%s\n' "$DM_EXTRA_TEST_ROOT" "$1" ;;
    *) return 1 ;;
  esac
}
dm_extra_directory_ok() {
  local path="$1" parent canonical
  case "$path" in ''|*[!A-Za-z0-9_./=+~-]*) return 1 ;; esac
  [ -d "$path" ] && [ -r "$path" ] && [ -x "$path" ] || return 1
  parent="$path"
  while [ "$parent" != / ]; do
    [ ! -L "$parent" ] || return 1
    parent=${parent%/*}
    [ -n "$parent" ] || parent=/
  done
  canonical=$(cd "$path" 2>/dev/null && pwd -P) || return 1
  [ "$canonical" = "$path" ]
}
dm_extra_hash_ok() {
  local path="$1" apk="$2" expected="$3" result actual
  [ -f "$path/$apk" ] && [ ! -L "$path/$apk" ] || return 1
  if command -v sha256sum >/dev/null 2>&1; then
    result=$(sha256sum "$path/$apk" 2>/dev/null) || return 1
  elif [ -n "$RT_BB" ]; then
    result=$("$RT_BB" sha256sum "$path/$apk" 2>/dev/null) || return 1
  else return 1; fi
  actual=${result%% *}
  [ "$actual" = "$expected" ]
}
dm_valid_any() {
  local package="$1" path="$2" row_package logical apk expected extra actual
  dm_allowed_package "$package" || return 1
  if dm_root_ok && dm_valid_path "$package" "$path"; then return 0; fi
  [ -r "$MODDIR/extra-mask-paths.list" ] || return 1
  while read -r row_package logical apk expected extra; do
    [ -n "$row_package" ] || continue
    [ -z "$extra" ] && dm_extra_row_allowed "$row_package" "$logical" "$apk" "$expected" || continue
    [ "$row_package" = "$package" ] || continue
    actual=$(dm_extra_actual "$logical") || continue
    [ "$path" = "$actual" ] || continue
    dm_extra_directory_ok "$path" && return 0
  done < "$MODDIR/extra-mask-paths.list"
  return 1
}
dm_valid_owned_path() {
  local package="$1" path="$2" state relative parent uuid basename suffix canonical
  dm_allowed_package "$package" && dm_namespace_ok || return 1
  state=$(dm_mount_state "$path")
  case "$state" in owned|owned-unsafe) ;; *) return 1 ;; esac
  dm_valid_any "$package" "$path" && return 0
  # PackageManager can rename an already covered update's parent after scanning
  # it. This exception only recognizes our existing mount, never a new target.
  dm_root_ok || return 1
  case "$path" in ''|*[!A-Za-z0-9_./=+~-]*) return 1 ;; esac
  case "$path" in "$DM_APP_ROOT"/*) relative=${path#"$DM_APP_ROOT"/} ;; *) return 1 ;; esac
  case "$relative" in */*) ;; *) return 1 ;; esac
  parent=${relative%/*}
  basename=${relative##*/}
  case "$parent" in */*) return 1 ;; *==deleted==) uuid=${parent%==deleted==} ;; *) return 1 ;; esac
  rt_lines "$uuid" | awk '
    { n=split($0,a,"-"); if(n!=5 || length(a[1])!=8 || length(a[2])!=4 ||
      length(a[3])!=4 || length(a[4])!=4 || length(a[5])!=12) exit 1
      for(i=1;i<=n;i++) if(a[i] !~ /^[0-9a-fA-F]+$/) exit 1
      found=1 }
    END { if(!found) exit 1 }' || return 1
  case "$basename" in "$package"-*) suffix=${basename#"$package"-} ;; *) return 1 ;; esac
  case "$suffix" in ''|*[!A-Za-z0-9_=+-]*) return 1 ;; esac
  [ -d "$path" ] && [ ! -L "$path" ] && [ ! -L "$DM_APP_ROOT/$parent" ] || return 1
  canonical=$(cd "$path" 2>/dev/null && pwd -P) || return 1
  [ "$canonical" = "$path" ]
}
dm_current_paths() {
  dm_namespace_ok && [ -r "$DM_MOUNTINFO" ] || return 1
  awk -v source="$DM_SOURCE" '
    NF {
      lines++; separator=0
      for(i=7;i<=NF;i++) if($i=="-") {
        separator=i
        if($(i+1)=="tmpfs" && $(i+2)==source && !seen[$5]++) print $5
        break
      }
      if($1 !~ /^[0-9]+$/ || $2 !~ /^[0-9]+$/ || $3 !~ /^[0-9]+:[0-9]+$/ ||
         !separator || NF<separator+3) bad=1
    }
    END { if(!lines || bad) exit 1 }' "$DM_MOUNTINFO" 2>/dev/null
}
dm_apply_extra() {
  local package logical apk expected extra path state failed=0
  [ -r "$MODDIR/extra-mask-paths.list" ] || return 1
  while read -r package logical apk expected extra; do
    [ -n "$package" ] || continue
    if [ -n "$extra" ] || ! dm_extra_row_allowed "$package" "$logical" "$apk" "$expected"; then failed=1; continue; fi
    path=$(dm_extra_actual "$logical") || { failed=1; continue; }
    [ -e "$path" ] || [ -L "$path" ] || continue
    dm_extra_directory_ok "$path" || { failed=1; continue; }
    state=$(dm_mount_state "$path")
    case "$state" in
      owned) dm_add_record "$package" "$path"; continue ;;
      none) ;;
      *) failed=1; continue ;;
    esac
    # A shared-propagation alias can already be covered by the preceding row.
    # Its now-hidden APK must not be re-read before recognizing that mount.
    dm_extra_hash_ok "$path" "$apk" "$expected" || { failed=1; continue; }
    dm_active || { failed=1; break; }
    if mount -t tmpfs -o mode=0755,nodev,nosuid,noexec "$DM_SOURCE" "$path" >/dev/null 2>&1; then
      state=$(dm_mount_state "$path")
      if [ "$state" = "owned" ]; then dm_add_record "$package" "$path"; else failed=1; fi
    else failed=1; fi
  done < "$MODDIR/extra-mask-paths.list"
  return "$failed"
}
dm_extra_status() {
  local package="$1" row_package logical apk expected extra path state seen=0 uncovered=0 unknown=0
  dm_allowed_package "$package" && dm_namespace_ok && [ -r "$MODDIR/extra-mask-paths.list" ] || { echo unknown; return; }
  while read -r row_package logical apk expected extra; do
    [ -n "$row_package" ] || continue
    if [ -n "$extra" ] || ! dm_extra_row_allowed "$row_package" "$logical" "$apk" "$expected"; then unknown=1; continue; fi
    [ "$row_package" = "$package" ] || continue
    path=$(dm_extra_actual "$logical") || { unknown=1; continue; }
    [ -e "$path" ] || [ -L "$path" ] || continue
    seen=1
    dm_extra_directory_ok "$path" || { unknown=1; continue; }
    state=$(dm_mount_state "$path")
    case "$state" in
      owned) ;;
      none) if dm_extra_hash_ok "$path" "$apk" "$expected"; then uncovered=1; else unknown=1; fi ;;
      *) unknown=1 ;;
    esac
  done < "$MODDIR/extra-mask-paths.list"
  if [ "$unknown" = "1" ]; then echo unknown
  elif [ "$seen" = "0" ] || [ "$uncovered" = "1" ]; then echo uncovered
  else echo covered; fi
}
dm_list_paths() {
  local package="$1" found path
  DM_PATHS=""
  dm_allowed_package "$package" && dm_root_ok || return 1
  found=$(find "$DM_APP_ROOT" -mindepth 1 -maxdepth 2 -name "$package-*" -print 2>&1) || return 1
  [ -n "$found" ] || return 0
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    dm_valid_path "$package" "$path" || return 1
    if [ -n "$DM_PATHS" ]; then DM_PATHS="$DM_PATHS
$path"; else DM_PATHS="$path"; fi
  done <<__DM_FOUND_PATHS__
$found
__DM_FOUND_PATHS__
}
dm_mount_state() {
  local path="$1" state
  [ -r "$DM_MOUNTINFO" ] || { echo unknown; return; }
  state=$(awk -v path="$path" -v source="$DM_SOURCE" '
    function opt(s,o) { return index("," s ",","," o ",")>0 }
    NF {
      lines++
      valid_separator=0
      for(i=7;i<=NF;i++) if($i=="-") { valid_separator=i; break }
      if($1 !~ /^[0-9]+$/ || $2 !~ /^[0-9]+$/ || $3 !~ /^[0-9]+:[0-9]+$/ ||
         !valid_separator || NF<valid_separator+3) bad=1
    }
    $5==path {
      matches++
      split_at=0
      for(i=7;i<=NF;i++) if($i=="-") { split_at=i; break }
      if(!split_at || NF<split_at+3) { bad=1; next }
      if($(split_at+1)!="tmpfs" || $(split_at+2)!=source || $4!="/") { foreign=1; next }
      owned++
      if(!opt($6,"nodev") || !opt($6,"nosuid") || !opt($6,"noexec") ||
         !(opt($(split_at+3),"mode=755") || opt($(split_at+3),"mode=0755"))) unsafe=1
    }
    END {
      if(!lines || bad) print "unknown"
      else if(foreign) print "foreign"
      else if(!matches) print "none"
      else if(owned && unsafe) print "owned-unsafe"
      else if(owned) print "owned"
      else print "unknown"
    }' "$DM_MOUNTINFO" 2>/dev/null) || state=unknown
  case "$state" in owned|owned-unsafe|foreign|none) echo "$state" ;; *) echo unknown ;; esac
}
dm_add_record() {
  local package="$1" path="$2"
  if [ -n "$DM_RECORDS" ]; then DM_RECORDS="$DM_RECORDS
$DM_THIS_BOOT $package $path"; else DM_RECORDS="$DM_THIS_BOOT $package $path"; fi
}
dm_write_records() {
  if [ -z "$DM_RECORDS" ]; then rm -f "$STATE_DIR/dm.boot"; return; fi
  rt_lines "$DM_RECORDS" > "$STATE_DIR/dm.boot.tmp.$$" &&
    chmod 0600 "$STATE_DIR/dm.boot.tmp.$$" && mv -f "$STATE_DIR/dm.boot.tmp.$$" "$STATE_DIR/dm.boot"
}
dm_get_boot() {
  DM_THIS_BOOT=$(cat "$DM_BOOTID" 2>/dev/null)
  case "$DM_THIS_BOOT" in ''|*[!A-Za-z0-9-]*) return 1 ;; esac
}
dm_apply() {
  local package path state failed=0
  dm_active || return 0
  dm_namespace_ok && dm_get_boot || return 1
  init_state || return 1
  DM_RECORDS=""
  while IFS= read -r package; do
    [ -n "$package" ] || continue
    dm_allowed_package "$package" || { failed=1; continue; }
    dm_list_paths "$package" || { failed=1; continue; }
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      state=$(dm_mount_state "$path")
      case "$state" in
        owned) dm_add_record "$package" "$path"; continue ;;
        none) ;;
        *) failed=1; continue ;;
      esac
      dm_active || { failed=1; break; }
      dm_valid_path "$package" "$path" || { failed=1; continue; }
      if mount -t tmpfs -o mode=0755,nodev,nosuid,noexec "$DM_SOURCE" "$path" >/dev/null 2>&1; then
        state=$(dm_mount_state "$path")
        if [ "$state" = "owned" ]; then dm_add_record "$package" "$path"; else failed=1; fi
      else failed=1; fi
    done <<__DM_APPLY_PATHS__
$DM_PATHS
__DM_APPLY_PATHS__
  done < "$MODDIR/masked-packages.list"
  dm_apply_extra || failed=1
  dm_write_records || failed=1
  return "$failed"
}
dm_package_status() {
  local package="$1" path state seen=0 uncovered=0 unknown=0
  if ! dm_namespace_ok || ! dm_list_paths "$package"; then echo unknown; return; fi
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    seen=1
    state=$(dm_mount_state "$path")
    case "$state" in owned) ;; none) uncovered=1 ;; *) unknown=1 ;; esac
  done <<__DM_STATUS_PATHS__
$DM_PATHS
__DM_STATUS_PATHS__
  if [ "$unknown" = "1" ]; then echo unknown
  elif [ "$seen" = "0" ] || [ "$uncovered" = "1" ]; then echo uncovered
  else echo covered; fi
}
dm_cleanup() {
  local paths path package state remaining failed=0 matched loops
  dm_namespace_ok && dm_get_boot || return 1
  [ -r "$DM_MOUNTINFO" ] || return 1
  init_state || return 1
  paths=$(dm_current_paths) || return 1
  DM_RECORDS=""
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    state=$(dm_mount_state "$path")
    [ "$state" != "none" ] || continue
    matched=0
    while IFS= read -r package; do
      [ -n "$package" ] || continue
      if dm_valid_owned_path "$package" "$path"; then matched=1; break; fi
    done < "$MODDIR/masked-packages.list"
    [ "$matched" = "1" ] || { failed=1; continue; }
    loops=0
    while :; do
      state=$(dm_mount_state "$path")
      case "$state" in
        none) break ;;
        owned|owned-unsafe)
          if ! umount "$path" >/dev/null 2>&1; then failed=1; dm_add_record "$package" "$path"; break; fi
          loops=$((loops+1))
          if [ "$loops" -ge 8 ]; then failed=1; dm_add_record "$package" "$path"; break; fi
          ;;
        *) failed=1; dm_add_record "$package" "$path"; break ;;
      esac
    done
  done <<__DM_CLEANUP_PATHS__
$paths
__DM_CLEANUP_PATHS__
  dm_write_records || failed=1
  return "$failed"
}
