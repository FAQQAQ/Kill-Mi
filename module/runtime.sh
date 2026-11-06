#!/system/bin/sh
# Shared by module entry points and the saved recovery copy.
# Feed potentially large text through stdin. Android's external printf has a
# per-argument size limit; shell function arguments do not cross execve.
# Installation diagnostics are opt-in and never create a runtime log.
rt_install_exec() {
  local label="$1"
  shift
  if [ "${KI_INSTALL_ACTIVE:-0}" = "1" ]; then ki_run "$label" "$@"
  else "$@"; fi
}
rt_install_write() {
  if [ "${KI_INSTALL_ACTIVE:-0}" = "1" ]; then ki_write "$@"
  else printf '%s\n' "$3" > "$2"; fi
}
rt_install_error() {
  if [ "${KI_INSTALL_ACTIVE:-0}" = "1" ]; then ki_issue "$@"; fi
  return 0
}
# BusyBox mkdir -p walks absolute paths starting at "/". Some SUSFS create
# hooks incorrectly return EINVAL for that existing component. Create only
# missing fixed levels, without -p and without changing the working directory.
rt_ensure_dir() {
  local directory="$1" error rc
  [ -d "$directory" ] && return 0
  if error=$(mkdir "$directory" 2>&1); then
    return 0
  else
    rc=$?
    # Another module operation may have created the same directory meanwhile.
    [ -d "$directory" ] && return 0
    [ -z "$error" ] || printf '%s\n' "$error" >&2
    return "$rc"
  fi
}
rt_lines() {
  cat <<__XSOF_RT_LINES__
$1
__XSOF_RT_LINES__
}
rt_setup() {
  RT_BB=""
  RT_AWK=""
  RT_SHELL=/system/bin/sh
  if [ -x "$RT_SHELL" ]; then
    PATH=/system/bin:/system/xbin:/vendor/bin:$PATH
    export PATH
  else
    RT_SHELL=/bin/sh
  fi
  local location candidate
  location=""
  if command -v magisk >/dev/null 2>&1; then
    location=$(command magisk --path 2>/dev/null)
  fi
  for candidate in /data/adb/ksu/bin/busybox /data/adb/magisk/busybox \
      "$location/.magisk/busybox/busybox" "$location/.magisk/busybox"; do
    [ -n "$candidate" ] && [ -f "$candidate" ] && [ -x "$candidate" ] || continue
    "$candidate" true >/dev/null 2>&1 || continue
    if printf '%s\n' probe | "$candidate" awk '{print $0}' 2>/dev/null | grep -q '^probe$'; then
      RT_BB="$candidate"
      RT_AWK="$candidate awk"
      break
    fi
  done
  if [ -z "$RT_AWK" ]; then
    for candidate in /system/bin/awk /system/xbin/awk /usr/bin/awk /bin/awk; do
      [ -f "$candidate" ] && [ -x "$candidate" ] || continue
      if printf '%s\n' probe | "$candidate" '{print $0}' 2>/dev/null | grep -q '^probe$'; then
        RT_AWK="$candidate"
        break
      fi
    done
  fi
}
awk() {
  if [ -n "$RT_BB" ]; then "$RT_BB" awk "$@"
  elif [ -n "$RT_AWK" ]; then "$RT_AWK" "$@"
  else echo "awk 不可用" >&2; return 127; fi
}
pm() {
  if [ -x /system/bin/pm ]; then /system/bin/pm "$@"; else command pm "$@"; fi
}
dumpsys() {
  if [ -x /system/bin/dumpsys ]; then /system/bin/dumpsys "$@"; else command dumpsys "$@"; fi
}
rt_timeout() {
  local seconds="$1" script="$2"
  shift 2
  if [ -x /system/bin/toybox ] &&
      /system/bin/toybox timeout -k 2 -s TERM 1 "$RT_SHELL" -c ':' >/dev/null 2>&1; then
    /system/bin/toybox timeout -k 2 -s TERM "$seconds" "$RT_SHELL" "$script" "$@"
  elif [ -n "$RT_BB" ] &&
      "$RT_BB" timeout -k 2 -s TERM 1 "$RT_BB" sh -c ':' >/dev/null 2>&1; then
    ASH_STANDALONE=1 "$RT_BB" timeout -k 2 -s TERM "$seconds" "$RT_BB" sh "$script" "$@"
  else
    echo "未找到可用的 timeout。"
    return 127
  fi
}
rt_spawn_recovery() {
  local script="$1" output="$2"
  [ -f "$script" ] || return 1
  : > "$output" || return 1
  if [ -n "$RT_BB" ] &&
      "$RT_BB" nohup "$RT_BB" true >/dev/null 2>&1 < /dev/null; then
    ASH_STANDALONE=1 "$RT_BB" nohup "$RT_BB" sh "$script" \
      > "$output" 2>&1 < /dev/null &
  elif [ -x /system/bin/toybox ] &&
      /system/bin/toybox nohup "$RT_SHELL" -c ':' >/dev/null 2>&1 < /dev/null; then
    /system/bin/toybox nohup "$RT_SHELL" "$script" \
      > "$output" 2>&1 < /dev/null &
  elif [ -x /system/bin/nohup ]; then
    /system/bin/nohup "$RT_SHELL" "$script" > "$output" 2>&1 < /dev/null &
  else
    return 1
  fi
  return 0
}
