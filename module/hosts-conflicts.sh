#!/system/bin/sh
# Diagnostic only. It does not edit or disable another module.
found=0
for directory in /data/adb/modules/* /data/adb/modules_update/*; do
  [ -d "$directory" ] || continue
  [ "${directory##*/}" = "xsof_guard_local" ] && continue
  [ ! -f "$directory/disable" ] && [ ! -f "$directory/remove" ] || continue
  [ ! -f "$directory/skip_mount" ] || continue
  [ -f "$directory/system/etc/hosts" ] || continue
  found=$((found + 1))
  name=$(sed -n 's/^name=//p' "$directory/module.prop" 2>/dev/null | head -1)
  [ -n "$name" ] || name="${directory##*/}"
  echo "WARN: 启用模块 $name 提供标准 hosts 文件，存在潜在冲突"
done
if [ "$found" -gt 0 ]; then
  echo "发现其他 hosts 模块。"
else
  echo "未发现其他启用模块提供标准 hosts 文件。"
fi
[ "$found" -eq 0 ]
