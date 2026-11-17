#!/bin/bash
#=====================================================================
# sos_error_scan.sh
#
# Scan /var/log of a customer sosreport for ERROR messages only.
# Has extra awareness of Red Hat Satellite 6 logs (Foreman, Katello,
# Candlepin, Pulp, Smart Proxy, httpd, Tomcat, PostgreSQL, Qpid, etc.)
#
# Expected layout (default base dir: /home/test/mohitk):
#   /home/test/mohitk/<case_number>/ ... /sosreport-xxxx/var/log/...
#   (already extracted dirs OR sosreport-*.tar.xz archives)
#
# Usage:
#   ./sos_error_scan.sh                 # fully interactive
#   ./sos_error_scan.sh -c 48573475     # skip the case prompt
#   ./sos_error_scan.sh -b /other/base  # change base directory
#   ./sos_error_scan.sh -a              # also scan audit.log (noisy)
#
# Optional override of the generic error regex:
#   ERROR_PATTERN='error|fatal|traceback' ./sos_error_scan.sh
#=====================================================================

BASE_DIR="/home/test/mohitk"
CASE_ID=""
INCLUDE_AUDIT=0

usage() {
    sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
}

while getopts ":b:c:ah" opt; do
    case $opt in
        b) BASE_DIR=$OPTARG ;;
        c) CASE_ID=$OPTARG ;;
        a) INCLUDE_AUDIT=1 ;;
        h) usage; exit 0 ;;
        *) usage; exit 1 ;;
    esac
done

# ---------- colours (only when writing to a terminal) ----------
if [ -t 1 ]; then
    RED=$'\e[1;31m'; GRN=$'\e[1;32m'; YEL=$'\e[1;33m'; CYN=$'\e[1;36m'; RST=$'\e[0m'
else
    RED=""; GRN=""; YEL=""; CYN=""; RST=""
fi
info() { echo "${CYN}[*]${RST} $*"; }
warn() { echo "${YEL}[!]${RST} $*" >&2; }
die()  { echo "${RED}[x]${RST} $*" >&2; exit 1; }

# ---------- patterns ----------
# Generic: anything that looks like an error in a syslog / app log
GENERIC_PAT="${ERROR_PATTERN:-\b(error|fatal|critical|crit|fail(ed|ure|ing)?|exception|traceback|panic|segfault|oom-killer|out of memory|denied|unable to|cannot|could not|time(d)?[ -]?out)\b}"

# Foreman/Satellite production.log: "2024-05-01T10:00:00 [E|app|abcd1234] msg"
# Levels: D I W E F  -> only E (error) and F (fatal) + Foreman ERFxx-xxxx codes
SAT_PAT='\[[EF][|]|ERF[0-9]+-[0-9]+'

# Lines that contain the word "error" but are not errors
EXCL_PAT='(\b0 errors?\b|\bno errors?\b|errors?[=:] ?0\b|\bfailed[=:] ?0\b|\b0 failed\b|without errors?|ErrorDocument|ErrorLog|error_log|errorlog|LogLevel|ignore.?errors?|--no-error|error_page)'

# ---------- helpers ----------
stream_file() {
    case "$1" in
        *.gz)  zcat    -- "$1" ;;
        *.xz)  xzcat   -- "$1" ;;
        *.bz2) bzcat   -- "$1" ;;
        *.zst) zstdcat -- "$1" ;;
        *)     cat     -- "$1" ;;
    esac
}

# skip binary / irrelevant files
skip_file() {
    case "$1" in
        */wtmp*|*/btmp*|*/lastlog|*/faillog|*/tallylog|*/sa/*|*/journal/*|*.journal|*.journal~|*.rpm|*.png|*.tar|*.zip)
            return 0 ;;
        */audit/audit.log*|*/candlepin/audit.log*)
            [ "$INCLUDE_AUDIT" -eq 0 ] && return 0 ;;
    esac
    return 1
}

# Map a log path (relative to sosreport root) to a component label
component() {
    case "$1" in
        var/log/foreman-proxy/*)                   echo "Satellite: Smart Proxy" ;;
        var/log/foreman-installer/*|var/log/foreman-maintain/*|var/log/satellite-installer*|var/log/capsule*)
                                                   echo "Satellite: Installer/Maintain" ;;
        var/log/foreman/*)                         echo "Satellite: Foreman/Katello/Dynflow" ;;
        var/log/candlepin/*)                       echo "Satellite: Candlepin" ;;
        var/log/tomcat*/*)                         echo "Satellite: Tomcat" ;;
        var/log/pulp*|var/log/pulp*/*)             echo "Satellite: Pulp" ;;
        var/log/httpd/*)                           echo "Satellite: Apache httpd" ;;
        var/log/qpid*|var/log/qdrouterd/*|var/log/qpidd/*)
                                                   echo "Satellite: Qpid/Qdrouterd" ;;
        var/log/postgresql/*|var/log/rh-postgresql*/*)
                                                   echo "Satellite: PostgreSQL" ;;
        var/log/mongodb/*)                         echo "Satellite: MongoDB" ;;
        var/log/redis/*)                           echo "Satellite: Redis" ;;
        var/log/puppet*|var/log/puppetlabs/*)      echo "Satellite: Puppet" ;;
        var/log/squid/*|var/log/tftpboot/*|var/log/dhcp*|var/log/named/*)
                                                   echo "Satellite: Provisioning svc" ;;
        var/log/rhsm/*)                            echo "Subscription Manager" ;;
        var/log/messages*|var/log/secure*|var/log/cron*|var/log/maillog*|var/log/dmesg*|var/log/boot.log*|var/log/yum.log*|var/log/dnf*)
                                                   echo "System" ;;
        sos_commands/logs/*)                       echo "Journal (sos_commands)" ;;
        *)                                         echo "Other" ;;
    esac
}

# Foreman production.log needs level-based matching, others use generic regex
scan_file() {
    local f=$1 rel=$2 icase pat
    case "$rel" in
        var/log/foreman/production.log*) pat=$SAT_PAT;     icase="" ;;
        *)                               pat=$GENERIC_PAT; icase="-i" ;;
    esac
    stream_file "$f" 2>/dev/null \
      | grep -an $icase -E -e "$pat" 2>/dev/null \
      | grep -avi -E -e "$EXCL_PAT" \
      | cut -c1-1000
}

normalize() {
    sed -E '
        s/^[0-9]+://
        s/[0-9]{4}-[0-9]{2}-[0-9]{2}([T ][0-9:.,+Z-]+)?//g
        s/\[([EF])[|]([A-Za-z_]+)[|][^]]*\]/[\1|\2|id]/g
        s/^[A-Z][a-z]{2} +[0-9]+ +[0-9:]{8}//
        s/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/<uuid>/g
        s/0x[0-9a-fA-F]+/<hex>/g
        s/[0-9]+/N/g
        s/  +/ /g' | cut -c1-220
}

extract_archive() {
    local a=$1 dest top
    dest=$(dirname "$a")
    top=$(tar -tf "$a" 2>/dev/null | head -n1 | cut -d/ -f1)
    [ -z "$top" ] && return 1
    info "Extracting $(basename "$a") into $dest (this may take a while)..." >&2
    tar -xf "$a" -C "$dest" 2>/dev/null
    [ -d "$dest/$top/var/log" ] && echo "$dest/$top"
}

#=====================================================================
# analyze one sosreport
#=====================================================================
analyze_sos() {
    local sos=$1 name ts rep summary idx norm
    name=$(basename "$sos")
    ts=$(date +%Y%m%d_%H%M%S)
    rep="$CASE_DIR/error_analysis/${name}_${ts}"
    mkdir -p "$rep/files" || { warn "Cannot create $rep"; return 1; }
    summary="$rep/summary.txt"; idx="$rep/.index"; norm="$rep/.norm"
    : > "$idx"; : > "$norm"

    [ -d "$sos/var/log" ] || { warn "No var/log in $sos"; return 1; }

    local scan_journal="n"
    read -rp "Also scan journalctl output in sos_commands/logs (useful for newer Satellite 6.x)? [y/N]: " scan_journal

    # ---- build file list ----
    local -a FILES=()
    while IFS= read -r -d '' f; do FILES+=("$f"); done \
        < <(find "$sos/var/log" -type f -print0 2>/dev/null | sort -z)
    if [[ "$scan_journal" =~ ^[Yy] ]] && [ -d "$sos/sos_commands/logs" ]; then
        while IFS= read -r -d '' f; do FILES+=("$f"); done \
            < <(find "$sos/sos_commands/logs" -type f -name 'journalctl*' -print0 2>/dev/null | sort -z)
    fi

    local total=${#FILES[@]} n=0 scanned=0 f rel comp out cnt
    info "Scanning $total files in $name ..."

    for f in "${FILES[@]}"; do
        n=$((n+1))
        rel=${f#$sos/}
        skip_file "$rel" && continue
        case "$f" in
            *.gz|*.xz|*.bz2|*.zst) ;;
            *) grep -Iq . "$f" 2>/dev/null || continue ;;   # skip binary / empty
        esac
        [ -t 1 ] && printf '\r\033[K  [%d/%d] %s' "$n" "$total" "${rel:0:90}"

        comp=$(component "$rel")
        out="$rep/files/$(echo "$rel" | tr '/' '_').txt"
        scan_file "$f" "$rel" > "$out"
        cnt=$(wc -l < "$out")
        scanned=$((scanned+1))
        if [ "$cnt" -gt 0 ]; then
            printf '%s|%s|%s\n' "$comp" "$cnt" "$rel" >> "$idx"
            normalize < "$out" >> "$norm"
        else
            rm -f "$out"
        fi
    done
    [ -t 1 ] && printf '\r\033[K'

    # ---- gather facts ----
    local host osrel satver="n/a (Satellite not detected)" files_with total_err
    host=$(cat "$sos/hostname" 2>/dev/null | head -n1)
    osrel=$(cat "$sos/etc/redhat-release" 2>/dev/null | head -n1)
    if [ -d "$sos/var/log/foreman" ] || [ -d "$sos/var/log/candlepin" ]; then
        satver=$(grep -hiE '^satellite-[0-9]' "$sos/installed-rpms" "$sos/sos_commands/rpm/package-data" 2>/dev/null | awk '{print $1}' | head -n1)
        [ -z "$satver" ] && satver="Satellite logs present (version not found in rpm list)"
    fi
    files_with=$(wc -l < "$idx")
    total_err=$(awk -F'|' '{s+=$2} END{print s+0}' "$idx")

    # ---- write summary ----
    {
        echo "=============================================================="
        echo " SOSREPORT ERROR ANALYSIS"
        echo "=============================================================="
        echo " Case          : $CASE_ID"
        echo " Sosreport     : $sos"
        echo " Hostname      : ${host:-unknown}"
        echo " OS            : ${osrel:-unknown}"
        echo " Satellite pkg : $satver"
        echo " Report date   : $(date)"
        echo " Files scanned : $scanned"
        echo " Files w/errors: $files_with"
        echo " Error lines   : $total_err"
        echo
        echo "---- Errors by component ----"
        awk -F'|' '{c[$1]+=$2} END{for(k in c) printf "%9d  %s\n", c[k], k}' "$idx" | sort -rn
        echo
        echo "---- Files with errors (most errors first) ----"
        sort -t'|' -k2,2 -nr "$idx" | awk -F'|' '{printf "%9d  [%s]  %s\n", $2, $1, $3}'
        echo
        echo "---- Top 25 recurring error messages (numbers/timestamps/UUIDs normalised) ----"
        sort "$norm" | uniq -c | sort -rn | head -n 25
        echo
        echo "---- Last 5 error lines of each CURRENT Satellite log ----"
        while IFS='|' read -r comp cnt rel; do
            case "$comp" in Satellite*) ;; *) continue ;; esac
            echo "$rel" | grep -qE '\.(gz|xz|bz2|zst)$|-[0-9]{8}$|\.[0-9]+$' && continue
            echo
            echo ">> $rel   ($cnt error lines)"
            tail -n 5 "$rep/files/$(echo "$rel" | tr '/' '_').txt" | cut -c1-300
        done < "$idx"
        echo
        echo "Detailed per-file results (with original line numbers): $rep/files/"
    } > "$summary"

    rm -f "$norm"
    cat "$summary"
    echo
    echo "${GRN}[+] Report saved in:${RST} $rep"
    echo "    Tip: less -R $rep/files/<file>.txt   |   grep -il 'candlepin' $rep/files/*"
    echo
}

#=====================================================================
# MAIN
#=====================================================================
[ -d "$BASE_DIR" ] || die "Base directory $BASE_DIR does not exist."

if [ -z "$CASE_ID" ]; then
    info "Cases found in $BASE_DIR:"
    ls -1 "$BASE_DIR" 2>/dev/null | column -c "${COLUMNS:-100}"
    echo
    read -rp "Enter case number: " CASE_ID
fi
[[ "$CASE_ID" =~ ^[A-Za-z0-9_.-]+$ ]] || die "Invalid case number."
CASE_DIR="$BASE_DIR/$CASE_ID"
[ -d "$CASE_DIR" ] || die "Case directory $CASE_DIR not found."

# ---- discover sosreports (extracted directories) ----
ITEM_TYPE=(); ITEM_PATH=()
while IFS= read -r d; do
    sos=${d%/var/log}
    [ -d "$sos/etc" ] || [ -d "$sos/sos_commands" ] || continue
    ITEM_TYPE+=("dir"); ITEM_PATH+=("$sos")
done < <(find "$CASE_DIR" -type d -path '*/var/log' -not -path '*/error_analysis/*' 2>/dev/null | sort -u)

# ---- discover un-extracted sosreport archives ----
while IFS= read -r a; do
    base=$(basename "$a"); stem=${base%.tar.*}; stem=${stem%.tgz}
    found=0
    for p in "${ITEM_PATH[@]}"; do
        [ "$(basename "$p")" = "$stem" ] && { found=1; break; }
    done
    [ "$found" -eq 0 ] && { ITEM_TYPE+=("arc"); ITEM_PATH+=("$a"); }
done < <(find "$CASE_DIR" -type f \( -name 'sosreport-*.tar.*' -o -name 'sosreport-*.tgz' \) \
            ! -name '*.md5' ! -name '*.sha256' ! -name '*.sha1' 2>/dev/null | sort)

[ "${#ITEM_PATH[@]}" -gt 0 ] || die "No sosreports found under $CASE_DIR."

echo
info "Sosreports found in case $CASE_ID:"
for i in "${!ITEM_PATH[@]}"; do
    p=${ITEM_PATH[$i]}
    if [ "${ITEM_TYPE[$i]}" = "dir" ]; then
        h=$(head -n1 "$p/hostname" 2>/dev/null)
        printf '  %2d) %s   (host: %s)\n' "$((i+1))" "${p#$CASE_DIR/}" "${h:-?}"
    else
        printf '  %2d) %s   [archive - not extracted yet]\n' "$((i+1))" "${p#$CASE_DIR/}"
    fi
done
echo
read -rp "Select sosreport number(s) (space separated) or 'all': " SEL

if [ "$SEL" = "all" ] || [ "$SEL" = "ALL" ]; then
    SEL=$(seq 1 "${#ITEM_PATH[@]}" | tr '\n' ' ')
fi

for s in $SEL; do
    [[ "$s" =~ ^[0-9]+$ ]] && [ "$s" -ge 1 ] && [ "$s" -le "${#ITEM_PATH[@]}" ] || { warn "Invalid selection: $s"; continue; }
    idx=$((s-1))
    target=${ITEM_PATH[$idx]}
    if [ "${ITEM_TYPE[$idx]}" = "arc" ]; then
        read -rp "Archive is not extracted. Extract $(basename "$target") now? [Y/n]: " yn
        [[ "$yn" =~ ^[Nn] ]] && continue
        target=$(extract_archive "$target") || { warn "Extraction failed for ${ITEM_PATH[$idx]}"; continue; }
    fi
    echo
    analyze_sos "$target"
done
