#!/usr/bin/env bash
#
# ssh-hardening.sh - Disable SSH password auth + configure fail2ban (Ubuntu/Debian)
#
# Copyright (c) 2026 Caio Tomich
# Licensed under the MIT License. See the LICENSE file.
#
# Usage:
#   sudo ./ssh-hardening.sh                    # apply, with confirmation
#   sudo ./ssh-hardening.sh --dry-run          # show what would happen
#   sudo ./ssh-hardening.sh --force            # skip the confirmation prompt
#   sudo ./ssh-hardening.sh --safety-net 10    # auto-revert after 10 minutes
#   sudo ./ssh-hardening.sh --rollback DIR     # restore a backup
#
#   --skip-fail2ban            leave fail2ban alone
#   --only-fail2ban            configure fail2ban only, don't touch sshd
#   --ssh-mode normal|aggressive   sshd filter mode (default: aggressive)
#   --allow-ip "1.2.3.4 5.6.7.0/24"  IPs fail2ban must never ban
#   --disable-pam              set UsePAM no (see the risks in the README)
#
# The safety net schedules an automatic restore of the backup. Test your
# access, then cancel the timer with the command printed at the end.

set -euo pipefail

readonly SSHD_CONFIG="/etc/ssh/sshd_config"
readonly SSHD_CONFIG_D="/etc/ssh/sshd_config.d"
readonly OVERRIDE="${SSHD_CONFIG_D}/00-hardening.conf"
readonly BACKUP_DIR="/root/ssh-backup-$(date +%Y%m%d-%H%M%S)"
readonly TIMER_UNIT="ssh-hardening-rollback"

readonly F2B_JAIL="/etc/fail2ban/jail.local"
readonly F2B_JAIL_OLD="/etc/fail2ban/jail.d/00-hardening.local"
readonly F2B_LOCAL="/etc/fail2ban/fail2ban.local"

readonly RAW_URL="https://raw.githubusercontent.com/caiotomich/ssh-hardening-ubuntu/main/ssh-hardening.sh"

DRY_RUN=0
FORCE=0
SAFETY_NET=0
SKIP_F2B=0
ONLY_F2B=0
SSH_MODE="aggressive"
ALLOW_IP=""
PAM_VALUE="yes"

# ---------- output ----------
c_red=$'\033[0;31m'; c_grn=$'\033[0;32m'; c_yel=$'\033[0;33m'
c_blu=$'\033[0;34m'; c_off=$'\033[0m'

info() { printf '%s[INFO]%s %s\n'  "$c_blu" "$c_off" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n'  "$c_grn" "$c_off" "$*"; }
warn() { printf '%s[WARN]%s %s\n'  "$c_yel" "$c_off" "$*"; }
die()  { printf '%s[FAIL]%s %s\n'  "$c_red" "$c_off" "$*" >&2; exit 1; }

run() {
    if (( DRY_RUN )); then
        printf '  %s(dry-run)%s %s\n' "$c_yel" "$c_off" "$*"
    else
        "$@"
    fi
}

# Under 'curl | bash', $0 is "bash" and no file exists on disk.
# Keep a usable name for messages.
SELF="${BASH_SOURCE[0]:-$0}"
if [[ -f "$SELF" ]]; then
    readonly SELF_LABEL="$SELF"
    readonly PIPED=0
else
    readonly SELF_LABEL="./ssh-hardening.sh"
    readonly PIPED=1
fi

# ---------- arguments ----------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)    DRY_RUN=1; shift ;;
        --force)      FORCE=1; shift ;;
        --safety-net) SAFETY_NET="${2:?minutes required}"; shift 2 ;;
        --rollback)   ROLLBACK_DIR="${2:?backup directory required}"; shift 2 ;;
        --skip-fail2ban) SKIP_F2B=1; shift ;;
        --only-fail2ban) ONLY_F2B=1; shift ;;
        --ssh-mode)   SSH_MODE="${2:?normal or aggressive}"; shift 2 ;;
        --allow-ip)   ALLOW_IP="${2:?one or more IPs required}"; shift 2 ;;
        --disable-pam) PAM_VALUE="no"; shift ;;
        -h|--help)
            if (( PIPED )); then
                printf 'Download the script to read the full help:\n  curl -fsSL %s -o ssh-hardening.sh && bash ssh-hardening.sh --help\n' "$RAW_URL"
            else
                sed -n '3,22p' "$SELF" | sed 's/^# \?//'
            fi
            exit 0 ;;
        *)            die "unknown option: $1" ;;
    esac
done

[[ $EUID -eq 0 ]] || die "must run as root (sudo $SELF_LABEL)"
[[ "$SSH_MODE" =~ ^(normal|ddos|extra|aggressive)$ ]] || die "invalid --ssh-mode: $SSH_MODE"

# Find the IP you are connected from, so you never ban yourself.
# Note: sudo clears SSH_CLIENT by default (env_reset), hence the fallbacks.
detect_client_ip() {
    local ip=""
    [[ -n "${SSH_CLIENT:-}" ]]     && ip=$(awk '{print $1}' <<<"$SSH_CLIENT")
    [[ -z "$ip" && -n "${SSH_CONNECTION:-}" ]] && ip=$(awk '{print $1}' <<<"$SSH_CONNECTION")
    [[ -z "$ip" ]] && ip=$(who am i 2>/dev/null | sed -nE 's/.*\(([0-9a-fA-F.:]+)\)[[:space:]]*$/\1/p')
    [[ -z "$ip" ]] && ip=$(last -w -i -n1 "${SUDO_USER:-root}" 2>/dev/null | awk 'NR==1{print $3}')
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$|^[0-9a-fA-F:]+:[0-9a-fA-F:]+$ ]] && printf '%s' "$ip"
}

# ---------- manual rollback ----------
if [[ -n "${ROLLBACK_DIR:-}" ]]; then
    [[ -d "$ROLLBACK_DIR" ]] || die "backup not found: $ROLLBACK_DIR"
    info "Restoring from $ROLLBACK_DIR"
    cp -a "$ROLLBACK_DIR/sshd_config" "$SSHD_CONFIG"
    rm -rf "$SSHD_CONFIG_D"
    [[ -d "$ROLLBACK_DIR/sshd_config.d" ]] && cp -a "$ROLLBACK_DIR/sshd_config.d" "$SSHD_CONFIG_D"
    sshd -t || die "restored config is invalid - manual intervention required"
    systemctl restart ssh
    ok "SSH configuration restored and service restarted."

    if [[ -f "$F2B_JAIL" || -f "$F2B_JAIL_OLD" ]]; then
        info "Removing the fail2ban jail and unbanning every IP"
        rm -f "$F2B_JAIL" "$F2B_JAIL_OLD"
        fail2ban-client unban --all >/dev/null 2>&1 || true
        systemctl restart fail2ban 2>/dev/null || true
        ok "fail2ban reverted (package left installed)."
    fi
    exit 0
fi

if (( ONLY_F2B )); then
    info "Mode --only-fail2ban: sshd will not be modified."
else

# ---------- 1. check for installed keys ----------
info "Looking for authorized public keys..."

declare -a users_with_keys=()
total_keys=0

while IFS= read -r home; do
    ak="$home/.ssh/authorized_keys"
    [[ -s "$ak" ]] || continue
    n=$(grep -cE '^[[:space:]]*(ssh-|ecdsa-|sk-)' "$ak" || true)
    (( n > 0 )) || continue
    user=$(basename "$home"); [[ "$home" == "/root" ]] && user="root"
    users_with_keys+=("$user ($n key(s))")
    (( total_keys += n ))
done < <(printf '%s\n' /root /home/*)

# also covers a custom AuthorizedKeysFile in a central location
if akf=$(sshd -T 2>/dev/null | awk '/^authorizedkeysfile /{$1=""; print}'); then
    for pat in $akf; do
        [[ "$pat" == *%u* || "$pat" == .ssh/* ]] && continue
        [[ -s "$pat" ]] && { users_with_keys+=("$pat (central file)"); (( total_keys++ )); }
    done
fi

if (( total_keys == 0 )); then
    die "No public key found. Run 'ssh-copy-id user@server' from your local
       machine BEFORE continuing, or you will lock yourself out."
fi

ok "Keys found:"
printf '       - %s\n' "${users_with_keys[@]}"

if [[ ! " ${users_with_keys[*]} " =~ [^a-z]root[^a-z] ]] && (( ${#users_with_keys[@]} == 1 )); then
    warn "Only one user has a key. Lose it and your provider's console is all that's left."
fi

# ---------- 2. show current state ----------
info "Current state:"
sshd -T 2>/dev/null | grep -Ei '^(passwordauthentication|kbdinteractiveauthentication|usepam|pubkeyauthentication|permitrootlogin) ' \
    | sed 's/^/       /' || warn "could not read the effective config"

# ---------- 3. confirm ----------
if (( ! FORCE && ! DRY_RUN )); then
    # Under 'curl | bash', stdin IS the script itself: a plain 'read'
    # would consume lines of code as if they were your answer.
    if [[ -r /dev/tty ]]; then
        printf '\n%sDisable password authentication now? [y/N]%s ' "$c_yel" "$c_off" > /dev/tty
        read -r resp < /dev/tty
    elif (( PIPED )); then
        die "No terminal to confirm on. Use --force, or download the script first:
       curl -fsSL $RAW_URL -o ssh-hardening.sh && sudo bash ssh-hardening.sh"
    else
        printf '\n%sDisable password authentication now? [y/N]%s ' "$c_yel" "$c_off"
        read -r resp
    fi
    [[ "$resp" =~ ^[yYsS]$ ]] || { info "Cancelled."; exit 0; }
fi

# ---------- 4. backup ----------
info "Backing up to $BACKUP_DIR"
run mkdir -p "$BACKUP_DIR"
run cp -a "$SSHD_CONFIG" "$BACKUP_DIR/"
[[ -d "$SSHD_CONFIG_D" ]] && run cp -a "$SSHD_CONFIG_D" "$BACKUP_DIR/"

# ---------- 5. neutralize conflicting directives ----------
# In SSH the FIRST value read wins. Comment out stray "yes" directives
# (e.g. 50-cloud-init.conf) to avoid surprises, and to satisfy scanners
# that read files instead of the effective value.
info "Neutralizing conflicting directives..."
shopt -s nullglob
for f in "$SSHD_CONFIG_D"/*.conf; do
    [[ "$f" == "$OVERRIDE" ]] && continue
    if grep -qiE '^[[:space:]]*(PasswordAuthentication|KbdInteractiveAuthentication|ChallengeResponseAuthentication)[[:space:]]+yes' "$f"; then
        info "  adjusting $f"
        run sed -i -E 's/^([[:space:]]*(PasswordAuthentication|KbdInteractiveAuthentication|ChallengeResponseAuthentication)[[:space:]]+yes)/#\1  # disabled by ssh-hardening.sh/I' "$f"
    fi
done
shopt -u nullglob

# ---------- 6. write the override ----------
HAS_INCLUDE=0
grep -qiE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' "$SSHD_CONFIG" && HAS_INCLUDE=1

if (( HAS_INCLUDE )); then
    info "Writing $OVERRIDE"
    run mkdir -p "$SSHD_CONFIG_D"
    if (( DRY_RUN )); then
        printf '  %s(dry-run)%s override contents\n' "$c_yel" "$c_off"
    else
        cat > "$OVERRIDE" <<EOF
# Generated by ssh-hardening.sh
# The 00- prefix guarantees precedence over 50-cloud-init.conf and friends.

PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitRootLogin prohibit-password
AuthenticationMethods publickey
UsePAM $PAM_VALUE
EOF
        chmod 600 "$OVERRIDE"
    fi
fi

# 6b. Mirror the values INSIDE the main sshd_config.
#
# Why: the override above already fixes the sshd's real behaviour, but panel
# scanners typically read only /etc/ssh/sshd_config and look for the literal
# line. Without it they assume the OpenSSH default (yes) and keep flagging
# the alert even though everything is correct.
#
# Important: do NOT append with >>. If the file ends with a "Match" block,
# the append lands inside it and the directive applies only to that group.
# So we insert right after the Include and strip old occurrences that appear
# before the first Match.
info "Mirroring directives into $SSHD_CONFIG (for file-reading scanners)"

if (( ! DRY_RUN )); then
    blk="# ssh-hardening.sh - explicit values
# (the override in sshd_config.d/ takes precedence; these are identical)
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
PermitRootLogin prohibit-password
UsePAM $PAM_VALUE"

    tmp=$(mktemp)
    awk -v blk="$blk" -v has_inc="$HAS_INCLUDE" '
        BEGIN { ins = 0; inmatch = 0 }
        NR == 1 && !has_inc { print blk; print ""; ins = 1 }
        /^[[:space:]]*[Mm]atch[[:space:]]+/ { inmatch = 1 }
        {
            if (!inmatch) {
                k = tolower($1); sub(/^#+/, "", k)
                if (k == "passwordauthentication" || k == "kbdinteractiveauthentication" ||
                    k == "challengeresponseauthentication" || k == "usepam" ||
                    k == "pubkeyauthentication" || k == "permitrootlogin") next
            }
            print
            if (!ins && $0 ~ /^[[:space:]]*[Ii]nclude[[:space:]]+\/etc\/ssh\/sshd_config\.d\//) {
                print ""; print blk; ins = 1
            }
        }
    ' "$SSHD_CONFIG" > "$tmp"

    if [[ -s "$tmp" ]] && grep -q '^PasswordAuthentication no' "$tmp"; then
        cat "$tmp" > "$SSHD_CONFIG"
        ok "  directives written to the main file"
    else
        warn "  rewrite failed - keeping the original"
    fi
    rm -f "$tmp"
fi

# Match blocks are preserved on purpose (they may be intentional), but a
# Match with PasswordAuthentication yes re-opens password auth for that group.
if (( ! DRY_RUN )) && awk '/^[[:space:]]*[Mm]atch[[:space:]]+/{m=1} m && tolower($1)=="passwordauthentication" && tolower($2)=="yes"{found=1} END{exit !found}' "$SSHD_CONFIG"; then
    warn "There is a Match block with PasswordAuthentication yes in $SSHD_CONFIG."
    warn "Password auth is still allowed for that group. Review it manually."
fi

if [[ "$PAM_VALUE" == "no" ]]; then
    warn "UsePAM=no applied. TEST these before closing your session:"
    warn "  systemctl --user status   and   ulimit -n"
fi

# ---------- 7. validate ----------
info "Validating syntax..."
if (( ! DRY_RUN )); then
    if ! sshd -t 2>/tmp/sshd-test.err; then
        warn "Invalid syntax. Reverting automatically."
        cp -a "$BACKUP_DIR/sshd_config" "$SSHD_CONFIG"
        rm -rf "$SSHD_CONFIG_D"
        [[ -d "$BACKUP_DIR/sshd_config.d" ]] && cp -a "$BACKUP_DIR/sshd_config.d" "$SSHD_CONFIG_D"
        cat /tmp/sshd-test.err >&2
        die "nothing was changed"
    fi
fi
ok "Syntax is valid."

# ---------- 8. safety net ----------
if (( SAFETY_NET > 0 && ! DRY_RUN )); then
    systemd-run --unit="$TIMER_UNIT" --on-active="${SAFETY_NET}m" \
        /bin/bash -c "cp -a '$BACKUP_DIR/sshd_config' '$SSHD_CONFIG'; \
                      rm -rf '$SSHD_CONFIG_D'; \
                      [ -d '$BACKUP_DIR/sshd_config.d' ] && cp -a '$BACKUP_DIR/sshd_config.d' '$SSHD_CONFIG_D'; \
                      systemctl restart ssh" >/dev/null 2>&1
    warn "Automatic rollback scheduled in ${SAFETY_NET} minute(s)."
fi

# ---------- 9. restart ----------
info "Restarting SSH (active connections stay up)..."
if systemctl is-active --quiet ssh.socket 2>/dev/null; then
    run systemctl restart ssh.socket   # Ubuntu 24.04+ (socket-activated)
    run systemctl restart ssh || true
else
    run systemctl restart ssh
fi
ok "SSH restarted."

# ---------- 10. verify the result ----------
if (( ! DRY_RUN )); then
    printf '\n'
    info "Effective configuration now:"
    eff=$(sshd -T | grep -Ei '^(passwordauthentication|kbdinteractiveauthentication|usepam|pubkeyauthentication|permitrootlogin) ')
    printf '%s\n' "$eff" | sed 's/^/       /'

    if grep -qi '^passwordauthentication no' <<<"$eff" \
    && grep -qi '^kbdinteractiveauthentication no' <<<"$eff"; then
        ok "Password authentication is DISABLED."
    else
        warn "Something still allows passwords. Check: grep -ri passwordauth /etc/ssh/"
    fi
fi

fi   # <-- end of the sshd block (--only-fail2ban skips everything above)

# ---------- 11. fail2ban ----------
setup_fail2ban() {
    local ver backend_line banaction ignore ip ports nregex

    # 11.1 installation
    if command -v fail2ban-server >/dev/null 2>&1; then
        ver=$(fail2ban-server --version 2>/dev/null | head -1)
        ok "  already installed: ${ver:-unknown version}"
    else
        info "  installing the fail2ban package..."
        run env DEBIAN_FRONTEND=noninteractive apt-get update -qq
        run env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq fail2ban
    fi

    # 11.2 log source
    # Minimal Ubuntu 24.04 images ship without rsyslog: /var/log/auth.log
    # does not exist and the sshd jail dies with "Have not found any log file".
    if [[ -f /var/log/auth.log ]]; then
        backend_line="backend  = auto"
    else
        warn "  /var/log/auth.log missing - reading from the journal instead"
        run env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3-systemd
        backend_line="backend  = systemd"
    fi

    # 11.3 how to ban
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^status: active'; then
        banaction="ufw"
        info "  ufw is active - bans will be inserted as ufw rules"
    else
        banaction="iptables-multiport"
    fi

    # 11.4 the sshd's real port (never assume 22)
    ports=$(sshd -T 2>/dev/null | awk '/^port /{print $2}' | paste -sd, -)
    [[ -z "$ports" ]] && ports="ssh"
    info "  monitored port(s): $ports"

    # 11.5 whitelist - the "don't lock yourself out" equivalent
    ignore="127.0.0.1/8 ::1"
    ip=$(detect_client_ip || true)
    if [[ -n "$ip" ]]; then
        ignore="$ignore $ip"
        ok "  your current IP ($ip) was whitelisted"
    else
        warn "  could not detect your IP - use --allow-ip \"YOUR.IP\" if you have a static one"
    fi
    [[ -n "$ALLOW_IP" ]] && ignore="$ignore $ALLOW_IP"

    # 11.6 configuration files
    # Never edit jail.conf/fail2ban.conf: they are overwritten on every upgrade.
    if (( DRY_RUN )); then
        printf '  %s(dry-run)%s would write %s and %s\n' "$c_yel" "$c_off" "$F2B_LOCAL" "$F2B_JAIL"
    else
        cat > "$F2B_LOCAL" <<EOF
# Generated by ssh-hardening.sh
[Definition]
allowipv6  = auto
# Longer database retention: required for incremental bantime to work.
dbpurgeage = 30d
EOF

        mkdir -p /etc/fail2ban/jail.d
        # Remove the old location (jail.d) so there is only one source.
        # fail2ban read order: jail.conf -> jail.d/*.conf -> jail.local ->
        # jail.d/*.local. A file in jail.d/*.local would silently override
        # jail.local.
        rm -f "$F2B_JAIL_OLD"

        cat > "$F2B_JAIL" <<EOF
# Generated by ssh-hardening.sh
[DEFAULT]
ignoreip  = $ignore
bantime   = 1h
findtime  = 10m
maxretry  = 5
banaction = $banaction

# Repeat offenders get hit harder: 1h -> 2h -> 4h ... up to one week.
bantime.increment = true
bantime.factor    = 2
bantime.maxtime   = 1w

[sshd]
enabled  = true
port     = $ports
maxretry = 3
$backend_line

# The two lines below say the same thing for different reasons:
# 'mode' is the canonical form (and what panel scanners look for);
# 'filter' makes it explicit without relying on jail.conf interpolation.
# normal | ddos | extra | aggressive
mode     = $SSH_MODE
filter   = sshd[mode=$SSH_MODE]
EOF
        chmod 644 "$F2B_JAIL" "$F2B_LOCAL"
    fi

    # 11.7 validate before starting
    if (( ! DRY_RUN )); then
        if ! fail2ban-client -t >/tmp/f2b-test.log 2>&1; then
            warn "  invalid fail2ban configuration - removing the jail we created"
            rm -f "$F2B_JAIL"
            tail -20 /tmp/f2b-test.log >&2
            return 1
        fi
        ok "  configuration is valid"
    fi

    # 11.8 enable and start
    run systemctl enable --quiet fail2ban 2>/dev/null || run systemctl enable fail2ban
    run systemctl restart fail2ban

    if (( DRY_RUN )); then return 0; fi

    sleep 2
    if ! systemctl is-active --quiet fail2ban; then
        warn "  fail2ban did not start. Last log lines:"
        journalctl -u fail2ban -n 20 --no-pager | sed 's/^/       /' >&2
        return 1
    fi
    ok "  service is active and enabled at boot"

    # 11.9 check the jail
    if fail2ban-client status sshd >/tmp/f2b-status.log 2>&1; then
        sed 's/^/       /' /tmp/f2b-status.log
        nregex=$(fail2ban-client get sshd failregex 2>/dev/null | grep -cE '^[|`]' || true)
        info "  sshd filter loaded with ${nregex:-0} expressions ($SSH_MODE mode)"
    else
        warn "  the sshd jail is not active:"
        sed 's/^/       /' /tmp/f2b-status.log >&2
        return 1
    fi
}

F2B_OK=0
if (( SKIP_F2B )); then
    info "fail2ban skipped (--skip-fail2ban)"
else
    printf '\n'
    info "Configuring fail2ban..."
    if setup_fail2ban; then
        F2B_OK=1
        (( DRY_RUN )) || ok "fail2ban configured and protecting SSH."
    else
        warn "fail2ban is NOT operational. SSH is still key-protected,"
        warn "but look into it: journalctl -u fail2ban -n 50"
    fi
fi

# ---------- 12. final instructions ----------
cat <<EOF

${c_yel}DO NOT CLOSE THIS SESSION YET.${c_off}

1) In ANOTHER terminal, confirm your key works:
     ssh $(id -un 2>/dev/null || echo user)@<ip>

2) Confirm passwords are blocked (should print "Permission denied"):
     ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password user@<ip>

EOF

if (( SAFETY_NET > 0 && ! DRY_RUN )); then
    cat <<EOF
3) All good? Cancel the automatic rollback:
     sudo systemctl stop ${TIMER_UNIT}.timer

EOF
fi

if (( F2B_OK )); then
    cat <<EOF
Useful fail2ban commands:
  sudo fail2ban-client status sshd          # how many IPs are banned
  sudo fail2ban-client set sshd unbanip IP  # unban a single IP
  sudo fail2ban-client unban --all          # clear everything (emergency)
  sudo tail -f /var/log/fail2ban.log        # follow in real time

Tip: if your client offers several keys on connect, it can exceed MaxAuthTries
and get you banned. Avoid that with:
  ssh -o IdentitiesOnly=yes -i ~/.ssh/your_key user@<ip>

EOF
fi

(( ONLY_F2B )) && exit 0

cat <<EOF
Backup saved at: $BACKUP_DIR
Revert manually:
  sudo $SELF_LABEL --rollback $BACKUP_DIR
EOF
