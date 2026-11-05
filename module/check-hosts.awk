FNR == NR {
    sub(/\r$/, "")
    if ($0 != "" && $0 !~ /^#/) {
        domain = tolower($0)
        if (domain in wanted) duplicate = 1
        wanted[domain] = 1
        total++
    }
    next
}
{
    sub(/#.*/, "")
    ip = tolower($1)
    for (i = 2; i <= NF; i++) {
        host = tolower($i)
        if (host in wanted) {
            if (ip == "0.0.0.0") v4[host] = 1
            else if (ip == "::1") v6[host] = 1
            else conflict[host] = 1
        }
    }
}
END {
    if (total != 21 || duplicate) {
        print "FAIL: 域名清单不是预期的 21 个不同域名"
        exit 1
    }
    failed = 0
    for (host in wanted) {
        if (v4[host] && v6[host] && !conflict[host]) print "OK: " host
        else {
            print "FAIL: " host " 映射缺失或存在冲突"
            failed++
        }
    }
    if (!failed) print "21/21 个域名的 hosts 映射符合预期。"
    exit (failed ? 1 : 0)
}
