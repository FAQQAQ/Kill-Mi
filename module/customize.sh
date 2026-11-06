#!/system/bin/sh
[ "$BOOTMODE" = "true" ] || abort "请在已启动的安卓系统中，通过 Magisk 或 KernelSU 安装。"
if [ "${KSU:-}" = "true" ]; then
  ROOT_FRAMEWORK=KernelSU
elif [ -n "${MAGISK_VER_CODE:-}" ]; then
  ROOT_FRAMEWORK=Magisk
else
  abort "需要 Magisk 或 KernelSU。"
fi
# Diagnostics only use the installer's output; no log directory is required.
# Keep unwrapped shell/parser errors in the installer's normal output stream.
exec 2>&1
if [ -r "$MODPATH/install-diagnostics.sh" ]; then
  . "$MODPATH/install-diagnostics.sh"
else
  KI_INSTALL_ACTIVE=0
  ki_stage() { ui_print "[安装步骤] $1"; }
  ki_issue() { ui_print "[安装错误] $1；命令/检查：$2；退出码：$3；原因：$4"; }
  ki_run() { shift; "$@"; }
  ki_source() { . "$1"; }
  ui_print "安装诊断脚本缺失，使用系统原始输出继续。"
fi
ui_print "========================================"
ui_print "       Kill Mi  v1.0.3"
ui_print "========================================"
ui_print "运行环境：$ROOT_FRAMEWORK"
ui_print "安装进程身份：$(id 2>&1)"
ui_print "模块解压目录：$MODPATH"
ui_print "本模块将执行："
ui_print "1. 遮蔽安全组件、SystemHelper、MiTrustService、GuardProvider、统计分析和运营商服务。"
ui_print "2. 禁用手机管家内五个指定 XSOF / 反诈组件。"
ui_print "   统计分析与运营商服务遮蔽未成功时，使用冻结措施。"
ui_print "   开机遮蔽目标包的 /data/app 更新副本及已核对的 mi_ext、pangu 其他APK来源。"
ui_print "3. SystemHelper、GuardProvider 重新出现且 UID 独占时，自动拦截其 IPv4/IPv6 出站。"
ui_print "4. hosts 开启时屏蔽 21 个精确域名。"
ui_print "----------------------------------------"
ui_print "【重要影响说明】"
ui_print "这些域名由多种组件共用，屏蔽可能导致："
ui_print "地震预警、地震监测志愿者、报警快速定位等功能可能不可用；"
ui_print "ADB 安装验证、运营商设备注册、云查杀及部分云端规则更新可能受影响。"
ui_print "WebUI 可以单独关闭 hosts，切换后需要重启。"
ui_print "关闭 hosts 不会撤销 UID 后备拦截、目录遮蔽和组件禁用。"
ui_print "----------------------------------------"
ui_print "60 秒内短按音量加继续安装。"
ui_print "按音量减或无操作取消安装。"
ki_stage "等待音量键确认"
ki_source "$MODPATH/install-confirm.sh" || abort "无法加载音量键确认脚本。"
confirm_volume_install || abort "未获得音量加确认，安装已取消；"
ui_print "----------------------------------------"
ki_stage "设置模块文件权限"
# Keep framework helpers in this shell, including any abort/exit they perform.
set_perm_recursive "$MODPATH" 0 0 0755 0644
ki_perm_rc=$?
[ "$ki_perm_rc" -eq 0 ] || ki_issue "设置模块目录与文件权限" "set_perm_recursive $MODPATH 0 0 0755 0644" "$ki_perm_rc" "框架权限函数失败，系统原始输出见上方。"
for script in firewall.sh post-fs-data.sh service.sh action.sh status.sh uninstall.sh recover.sh mask-status.sh mount-diagnose.sh hosts-conflicts.sh webui.sh scan.sh privacy-targets.sh data-mask.sh package-state.sh; do
  set_perm "$MODPATH/$script" 0 0 0755
  ki_perm_rc=$?
  [ "$ki_perm_rc" -eq 0 ] || ki_issue "设置可执行脚本权限" "set_perm $MODPATH/$script 0 0 0755" "$ki_perm_rc" "框架权限函数失败，系统原始输出见上方。"
done
MODDIR="$MODPATH"
ki_stage "加载安装依赖"
if [ ! -r "$MODPATH/runtime.sh" ]; then
  ki_issue "读取运行依赖" ". $MODPATH/runtime.sh" 1 "文件不存在或当前安装进程不可读。"
  abort "无法加载运行依赖。"
fi
ki_source "$MODPATH/lib.sh" || abort "无法加载模块公共函数。"
ki_source "$MODPATH/hosts-lib.sh" || abort "无法加载 hosts 函数。"
ki_source "$MODPATH/package-state.sh" || abort "无法加载包状态函数。"
ui_print "Shell：${RT_SHELL}；awk：${RT_AWK:-不可用}；BusyBox：${RT_BB:-使用系统工具}"
ki_stage "初始化原状态与偏好保存目录"
init_state || abort "原状态与偏好目录初始化失败，具体步骤见上方。"
ki_stage "获取模块操作锁"
acquire_lock || abort "无法获取模块操作锁，具体原因见上方。"
ki_stage "读取并保存目标包原状态"
ps_save_baselines || ui_print "部分包原状态未能读取；其余安装步骤继续。"
resume_uninstall=0
[ ! -f "$STATE_DIR/uninstall.pending" ] || resume_uninstall=1
ki_stage "检查 hosts 开关、冲突与文件准备"
if ! hg_prepare_from_mode; then
  release_lock
  abort "hosts 文件准备失败，已停止安装。"
fi
if [ "$resume_uninstall" = "1" ]; then
  if ! rt_install_write "保存重新安装的 hosts 设置" "$MODPATH/reinstall.hosts-mode" "$HG_EFFECTIVE"; then
    release_lock
    abort "无法保存 hosts 设置。"
  fi
  ui_print "重新安装已准备，重启后生效；无需先恢复组件。"
fi
ki_stage "释放模块操作锁"
release_lock
if [ "$HG_EFFECTIVE" = "0" ]; then
  ui_print "本模块 hosts 当前设置为关闭，目录遮蔽和组件禁用仍保留。"
  [ "$(cat "$STATE_DIR/hosts.reason" 2>/dev/null)" != "auto-conflict" ] ||
    ui_print "原因：检测到其他 hosts 模块，已自动关闭并保存。"
else
  ui_print "本模块 hosts 当前设置为开启。"
fi
if [ -d /data/adb/modules/miui_three_apps_mask ] &&
   [ ! -f /data/adb/modules/miui_three_apps_mask/remove ]; then
  ui_print "提醒：检测到旧的三目录遮蔽模块，请勿重复启用。"
fi
ui_print "撤销本模块的遮蔽和冻结，请在管理器中移除后重启。"
ui_print "安装完成，请重启手机。"
ui_print "========================================"
