#!/system/bin/sh
# Loaded only by customize.sh. No persistent or boot-time log is created.
KI_INSTALL_ACTIVE=1
KI_INSTALL_STAGE="安装初始化"

ki_stage() {
  KI_INSTALL_STAGE="$1"
  ui_print "[安装步骤] $1"
}

ki_issue() {
  local ki_label="$1" ki_command="$2" ki_rc="$3" ki_detail="$4" ki_line
  ui_print "[安装错误] $ki_label"
  ui_print "  所在阶段：$KI_INSTALL_STAGE"
  ui_print "  命令/检查：$ki_command"
  ui_print "  退出码：$ki_rc"
  if [ -n "$ki_detail" ]; then
    ui_print "  原始错误/原因："
    while IFS= read -r ki_line || [ -n "$ki_line" ]; do
      ui_print "    $ki_line"
    done <<__KI_ERROR__
$ki_detail
__KI_ERROR__
  else
    ui_print "  原始错误：命令未返回错误文本。"
  fi
}

ki_run() {
  local ki_label="$1" ki_output ki_rc
  shift
  # Only leaf commands are captured. Stateful module functions stay in the
  # caller's shell, so LOCKED and HG_EFFECTIVE are not lost in a subshell.
  if ki_output=$("$@" 2>&1); then
    [ -z "$ki_output" ] || printf '%s\n' "$ki_output"
    return 0
  else
    ki_rc=$?
    ki_issue "$ki_label" "$*" "$ki_rc" "$ki_output"
    return "$ki_rc"
  fi
}

ki_write() {
  local ki_label="$1" ki_path="$2" ki_value="$3" ki_output ki_rc
  if ki_output=$({ printf '%s\n' "$ki_value" > "$ki_path"; } 2>&1); then
    return 0
  else
    ki_rc=$?
    ki_issue "$ki_label" "printf > $ki_path" "$ki_rc" "$ki_output"
    return "$ki_rc"
  fi
}

ki_source() {
  local ki_file="$1" ki_rc
  if [ ! -r "$ki_file" ]; then
    ki_issue "读取安装脚本" ". $ki_file" 1 "文件不存在或当前安装进程不可读。"
    return 1
  fi
  # Source in this shell, preserving variables and the framework's traps.
  if . "$ki_file"; then return 0; else
    ki_rc=$?
    ki_issue "加载安装脚本" ". $ki_file" "$ki_rc" "脚本加载失败，请同时查看上方的 shell 错误。"
    return "$ki_rc"
  fi
}
