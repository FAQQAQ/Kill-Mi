#!/system/bin/sh
# Source after lib.sh. Only this module's tagged chain is ever modified.
FW_CHAIN=XSOF_GUARD_UID
FW_TAG=xsof_guard_local
FW_PACKAGES="com.mobiletools.systemhelper com.miui.guardprovider"

fw_setup() {
  FW4=""
  FW6=""
  local candidate
  for candidate in /system/bin/iptables /system/xbin/iptables; do
    [ -x "$candidate" ] && { FW4="$candidate"; break; }
  done
  [ -n "$FW4" ] || FW4=$(command -v iptables 2>/dev/null)
  for candidate in /system/bin/ip6tables /system/xbin/ip6tables; do
    [ -x "$candidate" ] && { FW6="$candidate"; break; }
  done
  [ -n "$FW6" ] || FW6=$(command -v ip6tables 2>/dev/null)
}
fw_run() {
  local family="$1" program
  shift
  case "$family" in 4) program="$FW4" ;; 6) program="$FW6" ;; *) return 1 ;; esac
  [ -n "$program" ] && [ -x "$program" ] || return 127
  "$program" -w 5 "$@"
}
fw_note() {
  :
}
fw_collect() {
  FW_MAP=""
  FW_UIDS=""
  FW_SYSTEMHELPER=unknown
  FW_GUARDPROVIDER=unknown
  FW_SYSTEMHELPER_UID=unknown
  FW_GUARDPROVIDER_UID=unknown
  local raw rc parsed package uid reason extra
  raw=$(pm list packages -U --user 0 2>&1)
  rc=$?
  [ "$rc" = "0" ] || return 1
  # Reject empty, partial/error responses and contradictory mappings.
  parsed=$(rt_lines "$raw" | awk '
    NF {
      if (NF!=2 || $1 !~ /^package:[A-Za-z0-9_.]+$/ || $2 !~ /^uid:[0-9]+$/) { bad=1; next }
      p=$1; sub(/^package:/,"",p); u=$2; sub(/^uid:/,"",u)
      if (p in ids) { bad=1; next }
      ids[p]=u
    }
    END {
      if (bad || !("android" in ids) || ids["android"]!=1000) exit 1
      for (p in ids) print p, ids[p]
    }') || return 1
  [ -n "$parsed" ] || return 1
  FW_MAP="$parsed"
  for package in $FW_PACKAGES; do
    uid=$(rt_lines "$FW_MAP" | awk -v p="$package" '$1==p {print $2}')
    reason=missing
    if [ -n "$uid" ]; then
      reason=unsafe
      case "$uid" in ''|*[!0-9]*) uid=unknown ;;
        *)
          if [ "$uid" -ge 10000 ] && [ "$uid" -lt 20000 ] &&
             [ "$(rt_lines "$FW_MAP" | awk -v u="$uid" '$2==u {n++} END {print n+0}')" = "1" ]; then
            reason=ready
            FW_UIDS="$FW_UIDS $uid"
          fi ;;
      esac
    else uid=unknown; fi
    case "$package" in
      com.mobiletools.systemhelper) FW_SYSTEMHELPER="$reason"; FW_SYSTEMHELPER_UID="$uid" ;;
      com.miui.guardprovider) FW_GUARDPROVIDER="$reason"; FW_GUARDPROVIDER_UID="$uid" ;;
    esac
  done
  FW_UIDS=$(printf '%s\n' "$FW_UIDS" | awk '{for(i=1;i<=NF;i++) print $i}' | sort -n | uniq | tr '\n' ' ')
  FW_UIDS=$(printf '%s\n' "$FW_UIDS" | awk '{$1=$1; print}')
  return 0
}
fw_owned() {
  # An existing, untagged name collision is never flushed or adopted.
  rt_lines "$1" | awk -v c="$FW_CHAIN" -v tag="$FW_TAG" '
    {gsub(/"/,"")}
    $1=="-N" && $2==c && NF==2 {next}
    $1=="-A" && $2==c {
      marked=0
      for(i=3;i<NF;i++) if($i=="--comment" && $(i+1)==tag) marked=1
      if(!marked) bad=1
      else owned++
      next
    }
    NF {bad=1}
    END {exit (bad || !owned)}'
}
fw_claim() {
  local family="$1" boot_id
  boot_id=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
  [ -n "$boot_id" ] || boot_id=unknown
  printf '%s\n' "$boot_id" > "$STATE_DIR/firewall.claim$family.tmp.$$" &&
    mv -f "$STATE_DIR/firewall.claim$family.tmp.$$" "$STATE_DIR/firewall.claim$family"
}
fw_is_ours() {
  local family="$1" rules="$2" saved current
  fw_owned "$rules" && return 0
  rt_lines "$rules" | awk -v c="$FW_CHAIN" '
    $1=="-N" && $2==c && NF==2 {next}
    NF {bad=1}
    END {exit bad}' || return 1
  saved=$(cat "$STATE_DIR/firewall.claim$family" 2>/dev/null)
  [ -n "$saved" ] || return 1
  current=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
  [ -n "$current" ] || current=unknown
  [ "$saved" = "$current" ]
}
fw_chain_ok() {
  rt_lines "$1" | awk -v c="$FW_CHAIN" -v tag="$FW_TAG" -v expected="$FW_UIDS" '
    BEGIN {n=split(expected,e," "); for(i=1;i<=n;i++) if(e[i]!="") wanted[e[i]]=1}
    {gsub(/"/,"")}
    $1=="-N" && $2==c && NF==2 {next}
    $1=="-A" && $2==c {
      if (ended) bad=1
      if (NF==12 && $3=="-m" && $4=="owner" && $5=="--uid-owner" &&
          $6~/^[0-9]+$/ && $7=="-m" && $8=="comment" &&
          $9=="--comment" && $10==tag && $11=="-j" && $12=="DROP") {
        if(!($6 in wanted) || seen[$6]++) bad=1
      } else if(NF==8 && $3=="-m" && $4=="comment" && $5=="--comment" &&
                $6==tag && $7=="-j" && $8=="RETURN") ended++
      else bad=1
      next
    }
    NF {bad=1}
    END {
      for(u in wanted) if(seen[u]!=1) bad=1
      exit (bad || ended!=1)
    }'
}
fw_output_ok() {
  rt_lines "$1" | awk -v c="$FW_CHAIN" -v tag="$FW_TAG" '
    {gsub(/"/,"")}
    $1=="-A" && $2=="OUTPUT" {
      position++
      for(i=3;i<NF;i++) if($i=="-j" && $(i+1)==c) {
        hits++
        if(position!=1 || NF!=8 || $3!="-m" || $4!="comment" || $5!="--comment" ||
           $6!=tag || $7!="-j" || $8!=c) bad=1
      }
    }
    END {exit (bad || hits!=1)}'
}
fw_remove_jump() {
  local family="$1" loops=0 output count
  while :; do
    output=$(fw_run "$family" -S OUTPUT 2>/dev/null) || return 1
    count=$(rt_lines "$output" | awk -v c="$FW_CHAIN" -v tag="$FW_TAG" '
      {gsub(/"/,"")}
      $1=="-A" && $2=="OUTPUT" && NF==8 && $3=="-m" && $4=="comment" &&
      $5=="--comment" && $6==tag && $7=="-j" && $8==c {n++}
      END {print n+0}') || return 1
    [ "$count" != "0" ] || return 0
    fw_run "$family" -D OUTPUT -m comment --comment "$FW_TAG" -j "$FW_CHAIN" >/dev/null 2>&1 || return 1
    loops=$((loops+1))
    [ "$loops" -lt 64 ] || return 1
  done
}
fw_clear_family() {
  local family="$1" force="${2:-0}" rules snapshot remaining recorded_boot current_boot
  snapshot=$(fw_run "$family" -S 2>/dev/null) || {
    recorded_boot=$(cat "$STATE_DIR/firewall.boot" 2>/dev/null)
    current_boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
    [ -n "$recorded_boot" ] || return 0
    if [ -n "$current_boot" ] && [ "$recorded_boot" != "unknown" ] &&
       [ "$recorded_boot" != "$current_boot" ]; then return 0; fi
    return 1
  }
  fw_remove_jump "$family" || return 1
  # A successful whole-table read proves absence; a failed -S chain does not.
  snapshot=$(fw_run "$family" -S 2>/dev/null) || return 1
  rules=$(rt_lines "$snapshot" | awk -v c="$FW_CHAIN" '
    ($1=="-N" || $1=="-A") && $2==c {print}') || return 1
  if [ -n "$rules" ]; then
    if [ "$force" != "1" ]; then fw_is_ours "$family" "$rules" || return 1; fi
    fw_run "$family" -F "$FW_CHAIN" >/dev/null 2>&1 || return 1
    if ! fw_run "$family" -X "$FW_CHAIN" >/dev/null 2>&1; then
      fw_run "$family" -A "$FW_CHAIN" -m comment --comment "$FW_TAG" -j RETURN >/dev/null 2>&1
      return 1
    fi
  fi
  snapshot=$(fw_run "$family" -S 2>/dev/null) || return 1
  if rt_lines "$snapshot" | awk -v c="$FW_CHAIN" '
    ($1=="-N" || $1=="-A") && $2==c {found=1}
    {for(i=1;i<NF;i++) if($i=="-j" && $(i+1)==c) found=1}
    END {exit !found}'; then return 1; fi
  rm -f "$STATE_DIR/firewall.claim$family"
  return 0
}
fw_check_family() {
  local family="$1" rules output
  rules=$(fw_run "$family" -S "$FW_CHAIN" 2>/dev/null) || return 1
  fw_chain_ok "$rules" || return 1
  output=$(fw_run "$family" -S OUTPUT 2>/dev/null) || return 1
  fw_output_ok "$output"
}
fw_apply_family() {
  local family="$1" rules output uid
  fw_run "$family" -S OUTPUT >/dev/null 2>&1 || return 1
  if [ -z "$FW_UIDS" ]; then fw_clear_family "$family"; return; fi
  if fw_check_family "$family"; then return 0; fi
  if rules=$(fw_run "$family" -S "$FW_CHAIN" 2>/dev/null); then
    fw_is_ours "$family" "$rules" || return 1
    fw_claim "$family" || return 1
    fw_remove_jump "$family" || return 1
    fw_run "$family" -F "$FW_CHAIN" >/dev/null 2>&1 || return 1
  else
    fw_run "$family" -N "$FW_CHAIN" >/dev/null 2>&1 || return 1
    fw_claim "$family" || { fw_run "$family" -X "$FW_CHAIN" >/dev/null 2>&1; return 1; }
  fi
  # Ownership was established above. Failure cleanup can remove our partial build.
  if ! fw_run "$family" -A "$FW_CHAIN" -m comment --comment "$FW_TAG" -j RETURN >/dev/null 2>&1; then
    fw_clear_family "$family" 1
    return 1
  fi
  for uid in $FW_UIDS; do
    if ! fw_run "$family" -I "$FW_CHAIN" 1 -m owner --uid-owner "$uid" -m comment --comment "$FW_TAG" -j DROP >/dev/null 2>&1; then
      fw_clear_family "$family" 1
      return 1
    fi
  done
  if ! fw_run "$family" -I OUTPUT 1 -m comment --comment "$FW_TAG" -j "$FW_CHAIN" >/dev/null 2>&1; then
    fw_clear_family "$family" 1
    return 1
  fi
  fw_check_family "$family" || { fw_clear_family "$family" 1; return 1; }
}
fw_apply() {
  local result=0 a=0 b=0
  init_state || return 1
  acquire_lock || return 1
  trap release_lock EXIT
  trap 'release_lock; exit 1' INT TERM
  fw_setup
  ensure_recovery || { fw_note "恢复文件保存失败；不建立新规则"; release_lock; return 1; }
  if [ -f "$MODULE_DIR/disable" ] || [ -f "$MODULE_DIR/remove" ] ||
     [ -f "$STATE_DIR/uninstall.pending" ]; then
    fw_clear_family 4
    fw_clear_family 6
    release_lock
    return 0
  fi
  if ! fw_collect; then
    # Never retain a potentially reassigned UID after losing package attribution.
    fw_clear_family 4
    fw_clear_family 6
    fw_note "包 UID 查询失败；已尝试撤销旧规则"
    release_lock
    return 1
  fi
  if [ -n "$FW_UIDS" ]; then
    local boot_id
    boot_id=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
    [ -n "$boot_id" ] || boot_id=unknown
    printf '%s\n' "$boot_id" > "$STATE_DIR/firewall.boot.tmp.$$" &&
      mv -f "$STATE_DIR/firewall.boot.tmp.$$" "$STATE_DIR/firewall.boot" || {
        release_lock; return 1;
      }
  fi
  fw_apply_family 4 || a=1
  fw_apply_family 6 || b=1
  [ "$a$b" = "00" ] || result=1
  fw_note "SystemHelper=$FW_SYSTEMHELPER:$FW_SYSTEMHELPER_UID GuardProvider=$FW_GUARDPROVIDER:$FW_GUARDPROVIDER_UID IPv4=$((1-a)) IPv6=$((1-b))"
  release_lock
  return "$result"
}
fw_clear() {
  local result=0
  init_state || return 1
  acquire_lock || return 1
  trap release_lock EXIT
  trap 'release_lock; exit 1' INT TERM
  fw_setup
  fw_clear_family 4 || result=1
  fw_clear_family 6 || result=1
  release_lock
  return "$result"
}
