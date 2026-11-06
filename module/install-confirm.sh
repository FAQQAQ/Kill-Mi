#!/system/bin/sh
# Sourced by customize.sh. The subshell keeps installer traps intact.
confirm_volume_install() (
  # Variables are private to this subshell and remain available to EXIT cleanup.
  directory=""
  listener=""
  answer=""
  polls=0
  size=0
  key_error=""
  key_rc=0
  [ -x /system/bin/getevent ] || {
    ki_issue "准备音量键监听" "test -x /system/bin/getevent" 1 "getevent 不存在或不可执行。"
    ui_print "无法读取音量键，已取消。"; exit 2;
  }
  [ -d "$TMPDIR" ] || {
    ki_issue "检查安装临时目录" "test -d $TMPDIR" 1 "TMPDIR 为空、目录不存在或不可访问。"
    ui_print "安装临时目录不可用，已取消。"; exit 2;
  }
  if directory=$(mktemp -d "$TMPDIR/ksxm-keys.XXXXXX" 2>&1); then :; else
    key_rc=$?
    ki_issue "创建音量键临时目录" "mktemp -d $TMPDIR/ksxm-keys.XXXXXX" "$key_rc" "$directory"
    directory=""
    exit 2
  fi
  cleanup_keys() {
    if [ -n "$listener" ]; then
      kill -TERM "$listener" 2>/dev/null
      sleep 0.05
      kill -KILL "$listener" 2>/dev/null
      wait "$listener" 2>/dev/null
    fi
    ki_run "清理音量键临时目录" rm -rf "$directory"
  }
  trap cleanup_keys EXIT
  ki_run "设置音量键临时目录权限" chmod 0700 "$directory" || exit 2
  trap 'exit 2' INT TERM HUP
  if key_error=$({ : > "$directory/events"; } 2>&1); then :; else
    key_rc=$?
    ki_issue "创建音量键事件文件" ": > $directory/events" "$key_rc" "$key_error"
    exit 2
  fi
  if key_error=$({ : > "$directory/errors"; } 2>&1); then :; else
    key_rc=$?
    ki_issue "创建音量键错误文件" ": > $directory/errors" "$key_rc" "$key_error"
    exit 2
  fi
  /system/bin/getevent -ql > "$directory/events" 2> "$directory/errors" &
  listener=$!
  while [ "$polls" -lt 600 ]; do
    if ! kill -0 "$listener" 2>/dev/null; then
      if wait "$listener"; then key_rc=0; else key_rc=$?; fi
      listener=""
      key_error=$(cat "$directory/errors" 2>&1)
      ki_issue "音量键监听进程退出" "/system/bin/getevent -ql" "$key_rc" "$key_error"
      ui_print "音量键监听失败，未确认安装。"
      exit 2
    fi
    size=$(wc -c < "$directory/events" 2>/dev/null | tr -d '[:space:]')
    case "$size" in ''|*[!0-9]*)
      ki_issue "读取音量键事件大小" "wc -c < $directory/events" 1 "未取得有效文件大小：$size"
      exit 2 ;;
    esac
    [ "$size" -le 1048576 ] || {
      ki_issue "检查音量键事件大小" "事件文件 <= 1048576 字节" 1 "实际大小：$size 字节"
      ui_print "输入事件异常，已取消。"; exit 2;
    }
    if answer=$(awk -f "$MODPATH/volume-keys.awk" "$directory/events" 2>&1); then :; else
      key_rc=$?
      ki_issue "解析音量键事件" "awk -f $MODPATH/volume-keys.awk $directory/events" "$key_rc" "$answer"
      exit 2
    fi
    case "$answer" in
      cancel) ui_print "收到音量减：取消安装。"; exit 1 ;;
      accept) ui_print "收到音量加：继续安装。"; exit 0 ;;
    esac
    sleep 0.1
    polls=$((polls + 1))
  done
  key_error=$(cat "$directory/errors" 2>&1)
  [ -z "$key_error" ] || ki_issue "音量键等待超时（监听器有错误输出）" "/system/bin/getevent -ql" 2 "$key_error"
  ui_print "约 60 秒内未完成音量加确认，已取消。"
  exit 2
)
