#!/system/bin/sh
# Manual, read-only inspection. Does not read APK contents or application data.
MODDIR=${0%/*}
. "$MODDIR/lib.sh"
. "$MODDIR/privacy-targets.sh"
[ "$(id -u)" = "0" ] || { echo "需要 root 权限"; exit 1; }
case "$#" in 0|1) ;; *) echo "参数错误"; exit 1 ;; esac
case "${1:-}" in
  "")
    rt_timeout 35 "$0" --worker
    result=$?
    if [ "$result" -ne 0 ]; then
      echo
      echo "检测失败（退出码 ${result}）"
    fi
    exit "$result"
    ;;
  --worker) ;;
  *) echo "参数错误"; exit 1 ;;
esac
echo "=== 杀死小米 · 相关组件检测 ==="
echo "时间：$(date '+%Y-%m-%d %H:%M:%S')"
echo
echo "--- 包管理器登记 ---"
packages=$(pm list packages -f --user 0 2>/dev/null)
pm_result=$?
if [ "$pm_result" -eq 0 ] && rt_lines "$packages" | grep -q '^package:'; then
  pm_ok=1
else
  pm_ok=0
  echo "UNKNOWN：包列表读取失败或返回为空。"
fi
for package in com.mobiletools.systemhelper com.miui.guardprovider com.xiaomi.trustservice com.miui.securitycenter com.miui.analytics com.xiaomi.registration; do
  echo "$package"
  if [ "$pm_ok" = "1" ]; then
    rows=$(rt_lines "$packages" | awk -v p="$package" '
      /^package:/ { line=$0; sub(/^package:/,"",line); n=split(line,a,"="); if(a[n]==p) print $0 }')
    if [ -n "$rows" ]; then
      echo "  主用户已登记："
      rt_lines "$rows" | sed 's/^/  /'
      paths=$(pm path --user 0 "$package" 2>/dev/null)
      if rt_lines "$paths" | grep -q '^package:'; then
        rt_lines "$paths" | sed 's/^/  APK /'
        if rt_lines "$paths" | grep -q '^package:/data/app/'; then
          echo "  更新副本：/data/app"
        fi
      else
        echo "  UNKNOWN：未能获取登记 APK 路径。"
      fi
    else
      echo "  未登记。"
    fi
  else
    echo "  UNKNOWN：包状态无法判断。"
  fi
done
echo
echo "--- 高通同名包（排除对象）---"
if [ "$pm_ok" = "1" ]; then
  rt_lines "$packages" | awk '
    /=com\.qualcomm\.qti\.services\.systemhelper$/ { print; found=1 }
    END { if(!found) print "主用户列表未返回该包。" }'
fi
echo "com.qualcomm.qti.services.systemhelper 不属于本模块处理目标。"
echo
echo "--- 五个目标组件 ---"
if load_dump; then
  while IFS= read -r target; do
    [ -n "$target" ] || continue
    current=$(component_state "$target")
    case "$current" in
      disabled) label="存在，已禁用" ;;
      default) label="存在，默认状态" ;;
      enabled) label="存在，显式启用" ;;
      absent) label="清单中未找到" ;;
      user-absent) label="主用户未安装" ;;
      *) label="UNKNOWN：无法可靠判断" ;;
    esac
    printf '%s : %s\n' "$label" "${target#*/}"
  done < "$MODDIR/components.list"
else
  echo "UNKNOWN：无法读取完整组件清单。"
fi
echo
sh "$MODDIR/mask-status.sh"
echo
pt_detail
echo
if [ -f "$MODDIR/mount-diagnose.sh" ]; then
  if sh "$MODDIR/mount-diagnose.sh"; then :; else
    diagnostic_result=$?
    echo "挂载诊断未完成（退出码 ${diagnostic_result}）"
  fi
else
  echo "挂载诊断脚本缺失。"
fi
echo
echo "--- 名称匹配 ---"
scan_root() {
  local root="$1" depth="$2" output code candidates count item metadata
  if [ -L "$root" ]; then
    echo "未遍历：扫描根 $root 是符号链接。"
    return 0
  fi
  metadata=$(LC_ALL=C ls -ld "$root" 2>&1)
  if [ "$?" -ne 0 ]; then
    case "$metadata" in
      *"No such file or directory"*) echo "当前不可见：$root" ;;
      *) echo "UNKNOWN：无法确认或访问扫描根 $root" ;;
    esac
    return 0
  fi
  [ -d "$root" ] || { echo "未遍历：$root 不是可确认的目录。"; return 0; }
  if [ ! -r "$root" ] || [ ! -x "$root" ]; then
    echo "UNKNOWN：无法读取 $root"
    return 0
  fi
  output=$(find "$root" -mindepth 1 -maxdepth "$depth" \
    \( -iname '*systemhelper*' -o -iname '*guardprovider*' -o -iname '*mitrustservice*' -o -iname '*com.xiaomi.trustservice*' \) -print 2>&1)
  code=$?
  [ "$code" -eq 0 ] || echo "UNKNOWN：$root 遍历不完整。"
  candidates=$(rt_lines "$output" | awk -v prefix="$root/" 'index($0,prefix)==1')
  if [ -z "$candidates" ]; then
    echo "未见名称线索：${root}（最多 $depth 层）"
    return 0
  fi
  count=$(rt_lines "$candidates" | wc -l | tr -d '[:space:]')
  rt_lines "$candidates" | head -40 | while IFS= read -r item; do
    case "$item" in
      *com.qualcomm.qti.services.systemhelper*) echo "排除：${item}（高通包名匹配）" ;;
      *)
        if [ -L "$item" ]; then
          echo "名称匹配（符号链接，未跟随）：$item"
        elif [ -d "$item" ]; then
          echo "名称匹配（目录）：$item"
        else
          echo "名称匹配（文件）：$item"
        fi
        ;;
    esac
  done
  [ "$count" -le 40 ] || echo "已截断：$root 共 $count 条，仅显示前 40 条。"
}
for partition in /system /product /system_ext /vendor /odm /mi_ext; do
  scan_root "$partition/app" 4
  scan_root "$partition/priv-app" 4
done
[ -d /product ] || { scan_root /system/product/app 4; scan_root /system/product/priv-app 4; }
[ -d /system_ext ] || { scan_root /system/system_ext/app 4; scan_root /system/system_ext/priv-app 4; }
for root in /data/app /data/app-private /data/preloads /data/preinstall /data/miui/app /product/pangu /cust/app; do
  scan_root "$root" 5
done
echo
echo "--- 数据目录 ---"
inspect_data_path() {
  local path="$1" metadata
  metadata=$(LC_ALL=C ls -ld "$path" 2>&1)
  if [ "$?" -ne 0 ]; then
    case "$metadata" in
      *"No such file or directory"*) echo "当前视图未见：$path" ;;
      *) echo "UNKNOWN：无法确认或访问 $path" ;;
    esac
  elif [ -d "$path" ]; then
    echo "目录存在：$path"
  else
    echo "UNKNOWN：$path 存在，但不是可确认的数据目录。"
  fi
}
for package in com.mobiletools.systemhelper com.miui.guardprovider com.xiaomi.trustservice; do
  for root in /data/user/0 /data/user_de/0; do
    inspect_data_path "$root/$package"
  done
  if [ -d /data/data ] && [ ! /data/data -ef /data/user/0 ]; then
    inspect_data_path "/data/data/$package"
  fi
done
echo
echo "检测完成。"
