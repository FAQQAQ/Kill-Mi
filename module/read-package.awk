# Output: user-id installed(true|false|unknown) enabled(0..4|unknown).
# Only the first matching installed-package block is read; resolver tables,
# queries, shared-user sections and hidden system copies are ignored.
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
function depth(s, t) { t=s; sub(/[^ \t].*$/, "", t); return length(t) }
function fields(s, n,a,i,v) {
    n=split(s,a,/[ \t]+/)
    for(i=1;i<=n;i++) {
        if(a[i] ~ /^installed=/) {
            v=a[i]; sub(/^installed=/,"",v)
            if(v!="true" && v!="false") invalid[current]=1
            else if(current in installs && installs[current]!=v) invalid[current]=1
            else installs[current]=v
        } else if(a[i] ~ /^enabled=/) {
            v=a[i]; sub(/^enabled=/,"",v)
            if(v !~ /^[0-4]$/) invalid[current]=1
            else if(current in states && states[current]!=v) invalid[current]=1
            else states[current]=v
        }
    }
}
{
    indent=depth($0)
    line=trim($0)
    if(line=="") next
    if(line=="Hidden system packages:") { active=0; stopped=1 }
    if(line ~ /^Package \[/) {
        active=0
        in_user=0
        if(!seen && !stopped && index(line,"Package [" package "]")==1) {
            seen=1
            active=1
            package_indent=indent
        }
        next
    }
    if(!active) next
    if(indent<=package_indent) { active=0; in_user=0; next }
    if(in_user && indent<=user_indent) in_user=0
    if(line ~ /^User / && indent==package_indent+2) {
        in_user=0
        if(line !~ /^User [0-9]+:/) { malformed=1; next }
        current=line
        sub(/^User /,"",current)
        sub(/:.*/,"",current)
        if(current !~ /^(0|[1-9][0-9]*)$/) { malformed=1; next }
        if(current in users) invalid[current]=1
        else { users[current]=1; order[++count]=current }
        in_user=1
        user_indent=indent
        fields(line)
        next
    }
    if(in_user) fields(line)
}
END {
    if(!seen || !count || malformed) exit 1
    for(i=1;i<=count;i++) {
        u=order[i]
        installed=(u in installs ? installs[u] : "unknown")
        enabled=(u in states ? states[u] : "unknown")
        if(invalid[u]) { installed="unknown"; enabled="unknown" }
        print u,installed,enabled
    }
}
