#!/system/bin/sh
# Manual read-only diagnostics. No mounts, policy changes or log files.
MODDIR=${0%/*}
. "$MODDIR/lib.sh"

MD_MODULES=/data/adb/modules
MD_UPDATES=/data/adb/modules_update
MD_META_LINK=/data/adb/metamodule
MD_STATE=/data/adb/xsof_guard_local
MD_MOUNTS=/proc/self/mountinfo
MD_INIT_MOUNTS=/proc/1/mountinfo
MD_NS=/proc/self/ns/mnt
MD_INIT_NS=/proc/1/ns/mnt
MD_KERNEL_MODULES=/proc/modules
MD_ENFORCE=/sys/fs/selinux/enforce
MD_LOGCAT=/system/bin/logcat
MD_HYBRID_CONFIG=/data/adb/hybrid-mount/config.toml
MD_MAGIC_CONFIG=/data/adb/magic_mount/config.toml
MD_HYBRID_STATE=/data/adb/hybrid-mount/run/state.json
MD_HYBRID_BLACKLIST=/data/adb/hybrid-mount/module_blacklist.toml
MD_MAGIC_LUA=/data/adb/magic_mount/lua

md_prop() {
  awk -v key="$1" 'index($0,key "=")==1 { sub(/^[^=]*=/, ""); sub(/\r$/, ""); print substr($0,1,180); exit }' "$2" 2>/dev/null
}
md_enabled() {
  [ ! -f "$1/disable" ] && [ ! -f "$1/remove" ]
}
md_target() {
  case "$1" in
    system/product/app/MIUIGuardProvider|system/product/app/MiTrustService|system/product/app/AnalyticsCore|system/product/priv-app/AutoRegistration)
      if [ -d /product ]; then printf '/product/%s\n' "${1#system/product/}"
      else printf '/%s\n' "$1"; fi ;;
    system/priv-app/com.mobiletools.systemhelper) printf '/%s\n' "$1" ;;
    *) return 1 ;;
  esac
}
md_source() {
  if [ -d "$MODDIR/$1" ]; then printf '%s/%s\n' "$MODDIR" "$1"
  else
    case "$1" in
      system/product/*) printf '%s/product/%s\n' "$MODDIR" "${1#system/product/}" ;;
      *) printf '%s/%s\n' "$MODDIR" "$1" ;;
    esac
  fi
}
md_opaque_setup() {
  MD_ATTR=""
  if command -v getfattr >/dev/null 2>&1; then MD_ATTR=system
  elif [ -n "$RT_BB" ] && "$RT_BB" --list 2>/dev/null | grep -qx getfattr; then MD_ATTR=busybox; fi
}
md_opaque() {
  local output
  case "$MD_ATTR" in
    system) output=$(getfattr -h -n trusted.overlay.opaque "$1" 2>/dev/null) || { echo unknown; return; } ;;
    busybox) output=$("$RT_BB" getfattr -h -n trusted.overlay.opaque "$1" 2>/dev/null) || { echo unknown; return; } ;;
    *) echo unknown; return ;;
  esac
  if rt_lines "$output" | grep -q 'trusted.overlay.opaque="y"'; then echo y; else echo not-y; fi
}
md_parent_mounts() {
  local file="$1" target="$2" label="$3"
  [ -r "$file" ] || { echo "  ${label}：mountinfo 不可读"; return; }
  awk -v target="$target" -v label="$label" '
    function parent(p) { return p=="/" || p==target || index(target,p "/")==1 }
    NF {
      sep=0; for(i=7;i<=NF;i++) if($i=="-") {sep=i;break}
      if(!sep || NF<sep+3) {bad=1;next}
      p=$5
      if(parent(p)) {
        if(length(p)>longest) {longest=length(p);n=0}
        if(length(p)==longest) rows[++n]="挂载点=" p "；类型=" $(sep+1) "；来源=" $(sep+2) "；选项=" $6
      }
    }
    END {
      if(n) {
        start=n>3?n-2:1
        for(i=start;i<=n;i++) print "  " label "：" rows[i]
        if(n>3) print "  " label "：同路径另有 " n-3 " 条记录，已省略"
      }
      else print "  " label "：未取得最近父挂载记录"
      if(bad) print "  " label "：部分 mountinfo 行无法解析"
    }' "$file" 2>/dev/null
}
md_label() {
  local output
  if output=$(LC_ALL=C ls -ldZ "$1" 2>&1); then
    printf '  标签/权限：%s\n' "$output"
  else
    printf '  标签/权限不可读：%s\n' "$1"
    rt_lines "$output" | head -2 | sed 's/^/    /'
  fi
}
md_environment() {
  local current global enforce kernel loaded meta dir id name version flag count=0
  echo "--- 挂载环境 ---"
  kernel=$(uname -r 2>/dev/null)
  echo "内核：${kernel:-未知}"
  enforce=$(cat "$MD_ENFORCE" 2>/dev/null)
  case "$enforce" in 1) echo "SELinux：Enforcing" ;; 0) echo "SELinux：Permissive" ;; *) echo "SELinux：未读取到模式" ;; esac
  current=$(readlink "$MD_NS" 2>/dev/null)
  global=$(readlink "$MD_INIT_NS" 2>/dev/null)
  echo "挂载命名空间：当前=${current:-未知}；PID 1=${global:-未知}"
  if [ -z "$current" ] || [ -z "$global" ]; then
    echo "检测视角：无法核对命名空间"
  elif [ "$current" != "$global" ]; then
    echo "检测视角：当前进程与 PID 1 不同；下方同时列出 PID 1 挂载记录"
  else echo "检测视角：与 PID 1 相同"; fi
  for flag in disable remove skip_mount mount_error; do
    [ ! -f "$MODDIR/$flag" ] || echo "本模块标记：$flag"
  done
  [ ! -f "$MODDIR/skip_mount" ] || echo "已发现 skip_mount：挂载器会跳过本模块 system 目录"
  [ ! -d "$MD_UPDATES/xsof_guard_local" ] || echo "待重启更新：modules_update 中存在本模块"
  meta=$(cd "$MD_META_LINK" 2>/dev/null && pwd -P)
  if [ -n "$meta" ] && [ -r "$meta/module.prop" ]; then
    MD_ACTIVE_META="$meta"
    echo "KernelSU 元挂载入口：$meta"
  else
    MD_ACTIVE_META=""
    echo "KernelSU 元挂载入口：未确认"
  fi
  if command -v magisk >/dev/null 2>&1; then
    version=$(magisk -v 2>/dev/null)
    echo "Magisk 命令版本：${version:-未读取到}"
  fi
  for dir in "$MD_MODULES"/*; do
    [ -d "$dir" ] && [ -r "$dir/module.prop" ] || continue
    flag=$(md_prop metamodule "$dir/module.prop")
    case "$flag" in 1|true) ;; *) [ -f "$dir/metamount.sh" ] || continue ;; esac
    count=$((count+1))
    id=$(md_prop id "$dir/module.prop"); name=$(md_prop name "$dir/module.prop"); version=$(md_prop version "$dir/module.prop")
    if ! md_enabled "$dir"; then flag="已停用或待移除"
    elif [ -n "$MD_ACTIVE_META" ] && [ "$dir" -ef "$MD_ACTIVE_META" ]; then flag="框架选择入口"
    else flag="已启用；未确认实际接管"; fi
    echo "挂载器：${name:-${dir##*/}}；ID=${id:-${dir##*/}}；版本=${version:-未知}；$flag"
    [ "$count" -lt 16 ] || { echo "挂载器列表达到 16 项，后续省略"; break; }
  done
  [ "$count" -gt 0 ] || echo "元挂载候选：未发现；旧版内置挂载状态未知"
  loaded=$(awk 'tolower($1) ~ /susfs/ {print $1}' "$MD_KERNEL_MODULES" 2>/dev/null)
  [ -z "$loaded" ] || { echo "SUSFS LKM 名称记录："; rt_lines "$loaded" | head -6; }
  echo "分区别名："
  LC_ALL=C ls -ld /product /system/product 2>&1 | head -4 | sed 's/^/  /'
}
md_mounter_files() {
  local file fragment match hook count=0 referenced skipped
  echo "--- 挂载器保存的状态与跳过配置 ---"
  if [ -f "$MD_HYBRID_STATE" ]; then
    echo "Hybrid Mount 最近保存的状态：$MD_HYBRID_STATE"
    fragment=$(head -c 131072 "$MD_HYBRID_STATE" 2>/dev/null | awk '
      /^[ \t]*"(timestamp|storage_mode|failed_stage|failure_reason|rollback_status)"[ \t]*:/ {
        line=$0;gsub(/\?[^ \t]+/,"?[参数省略]",line);print substr(line,1,1600);n++
        if(n>=6)exit
      }')
    if [ -n "$fragment" ]; then rt_lines "$fragment" | sed 's/^/  /'
    else echo "  状态文件不可读或字段格式未解析"; fi
  fi
  for file in "$MD_HYBRID_BLACKLIST" "$MD_MODULES/hybrid_mount/module_blacklist.toml"; do
    [ -f "$file" ] || continue
    match=$(awk '
      {sub(/#.*/,"")}
      /^[ \t]*blacklist[ \t]*=/ {inlist=1}
      inlist {
        line=$0;gsub(/[\047\"]/ ,"",line);n=split(line,a,/[ ,\[\]=\t\r]+/)
        for(i=1;i<=n;i++)if(a[i]=="xsof_guard_local")found=1
        if(index($0,"]"))inlist=0
      }
      END {print found?"列有本模块":"未在已解析名单中找到本模块"}' "$file" 2>/dev/null)
    echo "Hybrid 黑名单：${file}；${match:-读取失败}"
  done
  for hook in "$MD_MAGIC_LUA"/*.lua; do
    [ -f "$hook" ] || continue
    count=$((count+1)); referenced=未见; skipped=未见
    grep -qF xsof_guard_local "$hook" 2>/dev/null && referenced=存在
    grep -qE '(^|[^[:alnum:]_])skip([^[:alnum:]_]|$)' "$hook" 2>/dev/null && skipped=存在
    echo "MMRS 自定义 hook：${hook##*/}；本模块引用=${referenced}；skip 关键词=$skipped"
    [ "$count" -lt 8 ] || { echo "仅列出前 8 个 hook"; break; }
  done
}
md_config() {
  local file="$1"
  [ -f "$file" ] || return 0
  echo "配置摘要：${file}（原配置片段，路径规则优先）"
  if [ ! -r "$file" ]; then echo "  配置不可读"; return; fi
  awk '
    /^[ \t]*#/ {next}
    /^[ \t]*\[/ { section=$0;gsub(/[ \t\r]/,"",section); own=(section ~ /^\[rules\."?xsof_guard_local"?(\.paths)?\]$/); next }
    /^[ \t]*$/ {next}
    {
      if((section=="" || own) && match($0,/^[ \t]*(default_mode|overlay_mode)[ \t]*=[ \t]*[\047"](overlay|magic|vfs|ignore|ext4|tmpfs)[\047"]/)) {
        print "  " section " " substr($0,RSTART,RLENGTH);found=1;lines++
      }
      else if(own && section ~ /\.paths\]$/ && match($0,/^[ \t]*[\047"][^\047"]+[\047"][ \t]*=[ \t]*[\047"](overlay|magic|vfs|ignore)[\047"]/)) {
        print "  " section " " substr($0,RSTART,RLENGTH);found=1;lines++
      }
      else if(own && !unparsed++) {print "  本模块含未解析配置项";found=1;lines++}
      else if($0 ~ /xsof_guard_local/) {print "  含本模块的非标准配置，未解析有效模式";found=1;lines++}
      if(lines>=20) exit
    }
    END {if(!found) print "  未解析到全局或本模块模式；以挂载器界面为准"}' "$file" 2>/dev/null
}
md_targets() {
  local relative target source visible code opaque marker total=0 found=0 unknown=0
  echo "--- 五个标准目录：输入与实际视图 ---"
  while IFS= read -r relative; do
    [ -n "$relative" ] || continue
    target=$(md_target "$relative") || { echo "未识别的目录清单条目"; continue; }
    total=$((total+1)); source=$(md_source "$relative")
    echo "$target"
    if [ -d "$source" ]; then
      marker=无; [ ! -f "$source/.replace" ] || marker=存在
      opaque=$(md_opaque "$source")
      echo "  模块输入：${source}；.replace=${marker}；opaque=$opaque"
      md_label "$source"
    else echo "  模块输入目录缺失：$source"; fi
    if [ ! -d "$target" ]; then
      echo "  当前视图：目标目录不存在或不可访问"; unknown=$((unknown+1))
    else
      visible=$(find "$target" -type f -name '*.apk' -print 2>/dev/null); code=$?
      if [ "$code" -ne 0 ]; then echo "  当前视图：APK 检查未完成"; unknown=$((unknown+1))
      elif [ -n "$visible" ]; then
        found=$((found+1)); echo "  当前视图：仍有 APK"
        rt_lines "$visible" | head -3 | sed 's/^/    /'
      else echo "  当前视图：未见 APK"; fi
    fi
    md_label "$target"
    md_parent_mounts "$MD_MOUNTS" "$target" "当前最近父挂载"
    md_parent_mounts "$MD_INIT_MOUNTS" "$target" "PID 1 最近父挂载"
  done < "$MODDIR/masked-directories.list"
  MD_VISIBLE="$found"; MD_UNKNOWN="$unknown"
  echo "标准目录结果：${total} 项；仍有 APK=${found}；未完成检查=${unknown}"
  echo "--- 相关父目录的当前可见标签 ---"
  for target in /product/app /product/priv-app /system/priv-app; do
    echo "$target"; md_label "$target"
  done
}
md_overlaps() {
  local dir name id relative source alternate parent overlap policy scripts script words checked count=0 listed=0
  echo "--- 其他模块的重叠路径与策略线索（待对照）---"
  for dir in "$MD_MODULES"/*; do
    [ -d "$dir" ] && [ "${dir##*/}" != xsof_guard_local ] && md_enabled "$dir" || continue
    count=$((count+1)); [ "$count" -le 120 ] || { echo "已检查 120 个启用模块，后续省略"; break; }
    overlap=""; policy=""; scripts=""; checked="|"
    if [ ! -f "$dir/skip_mount" ]; then
      while IFS= read -r relative; do
        [ -n "$relative" ] || continue
        md_target "$relative" >/dev/null || continue
        source="$dir/$relative"
        case "$relative" in system/product/*) alternate="$dir/product/${relative#system/product/}" ;; *) alternate="$source" ;; esac
        if [ -e "$source" ] || [ -L "$source" ] || [ -e "$alternate" ] || [ -L "$alternate" ]; then
          overlap="$overlap $relative"
        fi
        # Parent-level .replace can affect the target without a same-name child.
        parent=${relative%/*}
        while [ "$parent" != . ] && [ -n "$parent" ]; do
          source="$dir/$parent"
          case "$parent" in system/product|system/product/*) alternate="$dir/${parent#system/}" ;; *) alternate="$source" ;; esac
          case "$checked" in *"|$source|"*) ;;
            *)
              checked="$checked$source|"
              if [ -f "$source/.replace" ] || [ -f "$alternate/.replace" ]; then
                overlap="$overlap $parent/.replace"; break
              elif { [ -d "$source" ] && [ "$(md_opaque "$source")" = y ]; } ||
                   { [ "$alternate" != "$source" ] && [ -d "$alternate" ] && [ "$(md_opaque "$alternate")" = y ]; }; then
                overlap="$overlap $parent[opaque=y]"; break
              fi
              ;;
          esac
          case "$parent" in */*) parent=${parent%/*} ;; *) break ;; esac
        done
      done < "$MODDIR/masked-directories.list"
    fi
    [ ! -f "$dir/sepolicy.rule" ] || policy="含 sepolicy.rule"
    for script in post-fs-data.sh post-mount.sh service.sh boot-completed.sh; do
      [ -f "$dir/$script" ] || continue
      words=$(head -c 131072 "$dir/$script" 2>/dev/null | awk '
        /^[ \t]*#/ {next}
        /(^|[^[:alnum:]_])mount([^[:alnum:]_]|$)/ {m=1}
        /(^|[^[:alnum:]_])(chcon|restorecon)([^[:alnum:]_]|$)/ {c=1}
        /(^|[^[:alnum:]_])(magiskpolicy|supolicy)([^[:alnum:]_]|$)/ {p=1}
        /(^|[^[:alnum:]_])(insmod|modprobe)([^[:alnum:]_]|$)/ {k=1}
        END {if(m)printf "mount ";if(c)printf "标签 ";if(p)printf "策略 ";if(k)printf "LKM ";}')
      [ -z "$words" ] || scripts="$scripts $script[$words]"
    done
    [ -n "$overlap$policy$scripts" ] || continue
    listed=$((listed+1)); id=$(md_prop id "$dir/module.prop"); name=$(md_prop name "$dir/module.prop")
    echo "待对照：${name:-${dir##*/}}（${id:-${dir##*/}}）"
    [ -z "$overlap" ] || echo "  路径重叠：$overlap"
    [ -z "$policy" ] || echo "  策略线索：$policy"
    [ -z "$scripts" ] || echo "  脚本关键词：$scripts"
    [ ! -f "$dir/skip_mount" ] || echo "  skip_mount：system 输入跳过；脚本与策略单独列出"
    [ "$listed" -lt 24 ] || { echo "线索列表达到 24 项，后续省略"; break; }
  done
  [ "$listed" -gt 0 ] || echo "未发现上述范围内的重叠路径或脚本/策略线索"
}
md_logs() {
  local output filtered result line
  echo "--- 当前 logcat 缓冲区的挂载错误 ---"
  [ -x "$MD_LOGCAT" ] || { echo "挂载器日志不可读：logcat 不可执行"; return; }
  output=$("$MD_LOGCAT" -d -b main -b system -v brief -s HybridMount:V MagicMount:V '*:S' 2>&1); result=$?
  if [ "$result" -ne 0 ]; then
    echo "挂载器日志读取失败（退出码 ${result}）"
    rt_lines "$output" | head -3
    return
  fi
  filtered=$(rt_lines "$output" | awk '
    {
      lower=tolower($0)
      if($0 !~ /^[ \t]*[VDIWEF]\/(HybridMount|MagicMount)[ \t]*[(:]/) next
      if(lower !~ /selinux|context|setxattr|mount|overlay/) next
      if(lower !~ /fail|error|denied|invalid|skip.*context|keeping existing label/) next
      line=$0;gsub(/\?[^ \t]+/,"?[参数省略]",line)
      rows[++n]=substr(line,1,1400)
    }
    END {start=n>12?n-11:1;for(i=start;i<=n;i++)print rows[i]}')
  if [ -z "$filtered" ]; then
    echo "当前缓冲区未取得相关错误记录"
    return
  fi
  rt_lines "$filtered"
  if rt_lines "$filtered" | grep -Eq 'xsof_guard_local|MIUIGuardProvider|MiTrustService|AnalyticsCore|AutoRegistration|com\.mobiletools\.systemhelper'; then
    echo "日志关联：包含本模块 ID 或目标目录"
  else echo "日志关联：挂载器错误未明确指向本模块"; fi
  if rt_lines "$filtered" | grep -Eiq 'SELinux|setxattr|security\.selinux|context'; then
    if rt_lines "$filtered" | grep -Eq '^[[:space:]]*[EF]/(HybridMount|MagicMount)'; then
      echo "错误记录涉及 SELinux 标签处理；具体对象和错误见上方"
    else
      echo "标签处理警告：需结合当前目录结果判断挂载是否失败"
    fi
  fi
}
md_hosts() {
  local output result mode reason
  echo "--- hosts 来源与保存状态 ---"
  mode=$(cat "$MD_STATE/hosts.mode" 2>/dev/null); reason=$(cat "$MD_STATE/hosts.reason" 2>/dev/null)
  echo "保存的 hosts 开关：${mode:-未知}；原因：${reason:-未记录}"
  output=$(sh "$MODDIR/hosts-conflicts.sh" 2>&1); result=$?
  case "$result" in
    0|1) rt_lines "$output" ;;
    *) echo "hosts 来源检查失败（退出码 ${result}）"; rt_lines "$output" | head -3 ;;
  esac
  [ "$mode:$reason" != 0:auto-conflict ] || echo "本模块曾因检测到其他 hosts 来源而保存为关闭。"
}

[ "$(id -u)" = 0 ] || { echo "挂载诊断需要 root 权限"; exit 1; }
case "${1:-}" in
  "")
    echo "=== 元挂载诊断 v1.0.3 ==="
    rt_timeout 8 "$0" --worker
    code=$?
    [ "$code" -eq 0 ] || echo "挂载诊断未完成（退出码 ${code}），以上为已取得的信息。"
    exit "$code" ;;
  --worker) [ "$#" -eq 1 ] || exit 1 ;;
  *) echo "参数错误"; exit 1 ;;
esac
md_opaque_setup
md_environment
echo
md_config "$MD_HYBRID_CONFIG"
md_config "$MD_MAGIC_CONFIG"
md_mounter_files
echo
md_targets
echo
md_logs
echo
md_overlaps
echo
md_hosts
echo
echo "挂载诊断完成：标准目录仍有 APK=${MD_VISIBLE:-未知}；未完成检查=${MD_UNKNOWN:-未知}。"
