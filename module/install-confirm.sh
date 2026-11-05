#!/system/bin/sh
# Sourced by customize.sh. The subshell keeps installer traps intact.
confirm_volume_install() (
  # Variables are private to this subshell and remain available to EXIT cleanup.
  directory=""
  listener=""
  answer=""
  polls=0
  size=0
  [ -x /system/bin/getevent ] || { ui_print "无法读取音量键，已取消。"; exit 2; }
  [ -d "$TMPDIR" ] || { ui_print "安装临时目录不可用，已取消。"; exit 2; }
  directory=$(mktemp -d "$TMPDIR/ksxm-keys.XXXXXX") || exit 2
  cleanup_keys() {
    if [ -n "$listener" ]; then
      kill -TERM "$listener" 2>/dev/null
      sleep 0.05
      kill -KILL "$listener" 2>/dev/null
      wait "$listener" 2>/dev/null
    fi
    rm -rf "$directory"
  }
  trap cleanup_keys EXIT
  chmod 0700 "$directory" || exit 2
  trap 'exit 2' INT TERM HUP
  : > "$directory/events" || exit 2
  : > "$directory/errors" || exit 2
  /system/bin/getevent -ql > "$directory/events" 2> "$directory/errors" &
  listener=$!
  while [ "$polls" -lt 600 ]; do
    if ! kill -0 "$listener" 2>/dev/null; then
      ui_print "音量键监听失败，未确认安装。"
      exit 2
    fi
    size=$(wc -c < "$directory/events" 2>/dev/null | tr -d '[:space:]')
    case "$size" in ''|*[!0-9]*) exit 2 ;; esac
    [ "$size" -le 1048576 ] || { ui_print "输入事件异常，已取消。"; exit 2; }
    answer=$(awk -f "$MODPATH/volume-keys.awk" "$directory/events") || exit 2
    case "$answer" in
      cancel) ui_print "收到音量减：取消安装。"; exit 1 ;;
      accept) ui_print "收到音量加：继续安装。"; exit 0 ;;
    esac
    sleep 0.1
    polls=$((polls + 1))
  done
  ui_print "约 60 秒内未完成音量加确认，已取消。"
  exit 2
)
