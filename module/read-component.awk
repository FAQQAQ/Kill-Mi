# Parse only the installed package's own indented block.
# Other dumpsys sections also contain "User 0:" and must not affect this state.
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
function get_indent(s, t) { t = s; sub(/[^ \t].*$/, "", t); return length(t) }
function read_installed(s) {
    if (s ~ /(^|[ \t])installed=true([ \t]|$)/) {
        installed_seen = 1
        installed = 1
    } else if (s ~ /(^|[ \t])installed=false([ \t]|$)/) {
        installed_seen = 1
        installed = 0
    }
}
BEGIN {
    split(component, parts, "/")
    pkg = parts[1]
    cls = parts[2]
    short = component
    if (index(cls, pkg ".") == 1) short = pkg "/" substr(cls, length(pkg) + 1)
}
{
    raw = $0
    indent = get_indent(raw)
    line = trim(raw)
    if (line == "") next
    if (line == "Hidden system packages:") { active = 0; stopped = 1 }
    if (line ~ /^Package \[/) {
        active = 0
        in_user = 0
        listing = 0
        if (!seen_pkg && !stopped && index(line, "Package [" pkg "]") == 1) {
            active = 1
            seen_pkg = 1
            package_indent = indent
        }
        next
    }
    if (!active) next
    # Package details are strictly more indented than the Package [...] line.
    if (indent <= package_indent) {
        active = 0
        in_user = 0
        listing = 0
        next
    }
    if (listing && indent <= listing_indent) listing = 0
    if (in_user && indent <= user_indent) {
        in_user = 0
        section = ""
    }
    if (line ~ /^(activities|services|receivers|providers|instrumentations):$/) {
        inventory = 1
        listing = 1
        listing_indent = indent
        next
    }
    if (line ~ /^User [0-9]+:/ && indent == package_indent + 2) {
        listing = 0
        section = ""
        in_user = (line ~ ("^User " user_id ":"))
        user_indent = indent
        if (in_user) {
            seen_user = 1
            read_installed(line)
        }
        next
    }
    if (listing && (line == component || line == short)) found = 1
    if (!in_user) next
    read_installed(line)
    if (section != "" && indent <= section_indent) section = ""
    if (line == "enabledComponents:" || line == "disabledComponents:") {
        section = (line == "enabledComponents:" ? "enabled" : "disabled")
        section_indent = indent
        next
    }
    if ((line == cls || line == component || line == short) && section != "") {
        if (section == "enabled") enabled = 1
        if (section == "disabled") disabled = 1
    }
}
END {
    if (diagnose) {
        printf "package=%d user0=%d installed=%d inventory=%d component=%d\n", seen_pkg, seen_user, installed_seen, inventory, found
        exit
    }
    if (!seen_pkg || !seen_user || !installed_seen) print "unknown"
    else if (!installed) print "user-absent"
    else if (!inventory) print "unknown"
    else if (!found) print "absent"
    else if (enabled && disabled) print "unknown"
    else if (disabled) print "disabled"
    else if (enabled) print "enabled"
    else print "default"
}
