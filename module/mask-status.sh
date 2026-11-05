#!/system/bin/sh
MODDIR=${0%/*}
. "$MODDIR/lib.sh"
. "$MODDIR/data-mask.sh"
echo "--- 目录遮蔽（当前进程视角）---"
while IFS= read -r relative; do
  [ -n "$relative" ] || continue
  case "$relative" in
    system/product/*)
      if [ -d /product ]; then target="/product/${relative#system/product/}"
      else target="/$relative"; fi
      ;;
    system/*) target="/$relative" ;;
    *) echo "UNKNOWN: 非预期目录条目"; continue ;;
  esac
  if [ ! -d "$target" ]; then
    echo "UNKNOWN: $target 未找到"
  else
    visible=$(find "$target" -type f -name '*.apk' -print 2>/dev/null)
    result=$?
    if [ "$result" -ne 0 ]; then
      echo "UNKNOWN: $target 读取失败"
    elif [ -n "$visible" ]; then
      echo "WARN: $target 仍有可见 APK"
      rt_lines "$visible"
    else
      echo "EMPTY: $target 目录为空"
    fi
  fi
done < "$MODDIR/masked-directories.list"
echo
echo "--- 三个关联包的系统登记路径 ---"
for package in com.mobiletools.systemhelper com.miui.guardprovider com.xiaomi.trustservice; do
  paths=$(pm path --user 0 "$package" 2>/dev/null)
  if rt_lines "$paths" | grep -q '^package:'; then
    echo "$package:"
    rt_lines "$paths"
    if rt_lines "$paths" | grep -q '^package:/data/app/'; then
      echo "WARN: 存在登记的 /data/app 更新副本，预装目录遮蔽不足以确认它已消失"
    else
      :
    fi
  else
    echo "$package: 未返回路径"
  fi
done
echo
echo "--- 更新及预置来源目录 ---"
current_paths=$(dm_current_paths 2>/dev/null)
if [ -n "$current_paths" ]; then
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    for package in com.mobiletools.systemhelper com.miui.guardprovider com.xiaomi.trustservice com.miui.analytics com.xiaomi.registration; do
      if dm_valid_owned_path "$package" "$path"; then
        echo "EMPTY: $path"
        break
      fi
    done
  done <<__CURRENT_MASK_PATHS__
$current_paths
__CURRENT_MASK_PATHS__
else
  echo "本次启动无额外目录挂载。"
fi
