#!/system/bin/sh
MODDIR=${0%/*}
. "$MODDIR/lib.sh"
. "$MODDIR/hosts-lib.sh"
. "$MODDIR/privacy-targets.sh"
echo "=== 杀死小米 v1.0.1 ==="
echo "范围：五个独立包优先遮蔽（含已核对来源及开机更新副本）；手机管家 5 组件冻结；21 个精确域名。"
echo
[ -f "$MODDIR/disable" ] && echo "模块已停用。"
[ -f "$MODDIR/remove" ] && echo "模块已标记移除，重启后执行恢复。"
sh "$MODDIR/mask-status.sh"
echo
echo "--- 组件当前状态 ---"
if load_dump; then
  count=0
  uncertain=0
  first_unknown=""
  while IFS= read -r target; do
    [ -n "$target" ] || continue
    current=$(component_state "$target")
    [ "$current" = "disabled" ] && count=$((count + 1))
    if [ "$current" = "unknown" ]; then
      uncertain=$((uncertain + 1))
      [ -n "$first_unknown" ] || first_unknown="$target"
    fi
    printf '%s : %s\n' "$current" "${target#*/}"
  done < "$MODDIR/components.list"
  if [ "$uncertain" = "5" ]; then
    echo "已禁用：未知"
  elif [ "$uncertain" -gt 0 ]; then
    printf '已确认禁用：%s；未知：%s\n' "$count" "$uncertain"
  else
    echo "已禁用：$count/5"
  fi
  if [ -n "$first_unknown" ]; then
    printf '解析：'
    component_diagnostic "$first_unknown"
    printf 'awk：%s\n' "$RT_AWK"
  fi
else
  echo "组件读取失败：$DUMP_ERROR"
fi
echo
pt_detail
echo
echo "--- hosts 开关 ---"
requested=$(hg_read_mode)
boot=$(hg_boot_mode)
echo "下次启动设置：${requested}；本次启动记录：${boot}（1=开，0=关，unknown=未知）"
echo "切换后重启生效。"
sh "$MODDIR/hosts-conflicts.sh"
echo
echo "--- 当前进程所见 hosts ---"
hosts_result=0
if [ "$requested" = "1" ]; then
  awk -f "$MODDIR/check-hosts.awk" "$MODDIR/domains.list" /system/etc/hosts
  hosts_result=$?
else
  echo "本模块 hosts 已设为关闭或状态未知，请使用自己的软件管理以下域名："
  cat "$MODDIR/domains.list"
fi
[ -f "$STATE_DIR/uninstall.pending" ] && echo "卸载恢复仍待完成。"
exit "$hosts_result"
