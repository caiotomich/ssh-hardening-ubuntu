# ssh-hardening.sh

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Disables SSH password authentication and configures fail2ban on Ubuntu/Debian servers, with the checks that keep you from locking yourself out of your own machine.

Written to clear the alerts typical VPS panel security scanners raise:

| Scanner item | Fixed by |
|---|---|
| Password Authentication should be disabled | `PasswordAuthentication no` + `KbdInteractiveAuthentication no` |
| Fail2Ban should be installed | installation via `apt` |
| Fail2Ban service should be enabled | `systemctl enable fail2ban` |
| Fail2Ban service should be running | `systemctl restart` + state verification |
| SSH protection should be enabled | `[sshd]` jail with `enabled = true` |
| Aggressive mode recommended | `mode = aggressive` |

*Documentação em português: [README.pt-BR.md](README.pt-BR.md)*

---

## Requirements

- Ubuntu 18.04+ or Debian 10+
- Root access (`sudo`)
- **An SSH public key already installed** — the script refuses to run without one

If you don't have one yet, run this on your local machine first:

```bash
ssh-copy-id user@server-ip
ssh user@server-ip    # must log in without asking for a password
```

---

## Installation

**Recommended** — download, inspect, then run:

```bash
curl -fsSL https://raw.githubusercontent.com/caiotomich/ssh-hardening-ubuntu/main/ssh-hardening.sh -o ssh-hardening.sh \
  && less ssh-hardening.sh \
  && sudo bash ssh-hardening.sh --safety-net 10
```

**One-liner**, if you prefer:

```bash
curl -fsSL https://raw.githubusercontent.com/caiotomich/ssh-hardening-ubuntu/main/ssh-hardening.sh \
  | sudo bash -s -- --force --safety-net 10
```

The `-s --` is required: without it bash treats `--force` as its own option rather than the script's.

**Or via git:**

```bash
git clone https://github.com/caiotomich/ssh-hardening-ubuntu.git
cd ssh-hardening-ubuntu
sudo ./ssh-hardening.sh --safety-net 10
```

### Why the two-step version is preferable

This isn't purism. With `curl | bash`, if the connection drops mid-download bash executes whatever arrived — a script truncated at the wrong line applies half the changes and never reaches the `sshd -t` validation. In a script that touches your SSH access, that matters.

`curl -o file && bash file` solves it because curl returns a non-zero exit code on an incomplete transfer, and `&&` stops execution.

The other two reasons are the usual ones: you're running code as root without having read it, and a server can serve different content to `curl` than to a browser.

### Verify integrity

```bash
sha256sum ssh-hardening.sh
```

Compare against the value published in [CHECKSUMS.txt](CHECKSUMS.txt).

---

## Usage

```bash
chmod +x ssh-hardening.sh

sudo ./ssh-hardening.sh --dry-run          # see what would happen
sudo ./ssh-hardening.sh --safety-net 10    # apply with a safety net
```

### Recommended first run

1. Run with `--dry-run` and read the output.
2. Run with `--safety-net 10`.
3. **Without closing your current session**, open another terminal and test key-based access.
4. Confirm passwords are blocked:
   ```bash
   ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password user@ip
   ```
   You should get `Permission denied (publickey)`.
5. All good? Cancel the automatic rollback:
   ```bash
   sudo systemctl stop ssh-hardening-rollback.timer
   ```

If something goes wrong and you lose access, just wait out the 10 minutes — the server restores itself.

---

## Options

| Flag | Effect |
|---|---|
| `--dry-run` | Shows every action without performing any |
| `--force` | Skips the interactive confirmation |
| `--safety-net N` | Schedules an automatic backup restore in N minutes |
| `--rollback DIR` | Restores a previous backup and reverts fail2ban |
| `--skip-fail2ban` | Touches sshd only |
| `--only-fail2ban` | Configures fail2ban only, leaves sshd alone |
| `--ssh-mode MODE` | `normal`, `ddos`, `extra` or `aggressive` (default) |
| `--allow-ip "IPs"` | IPs or ranges fail2ban must never ban |
| `--disable-pam` | Applies `UsePAM no` (read the risks below first) |
| `-h`, `--help` | Short help |

---

## What gets changed

### Files created

```
/etc/ssh/sshd_config.d/00-hardening.conf   # sshd directives
/etc/fail2ban/jail.local                   # [sshd] jail and defaults
/etc/fail2ban/fail2ban.local               # allowipv6 and database retention
/root/ssh-backup-YYYYMMDD-HHMMSS/          # backup of the original config
```

The script **never edits** `jail.conf` or `fail2ban.conf` — those files are overwritten on every package upgrade.

### sshd configuration applied

```
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitRootLogin prohibit-password
AuthenticationMethods publickey
UsePAM yes
```

### fail2ban configuration applied

```ini
[DEFAULT]
bantime   = 1h
findtime  = 10m
maxretry  = 5
bantime.increment = true    # 1h → 2h → 4h ... up to one week
bantime.factor    = 2
bantime.maxtime   = 1w

[sshd]
enabled  = true
maxretry = 3
mode     = aggressive
```

---

## Lockout protections

The script is built around the assumption that the likeliest failure isn't an attacker — it's you locking yourself out.

**Key check before anything else.** It scans `/root` and `/home/*` for an `authorized_keys` holding at least one valid key, and honours a custom `AuthorizedKeysFile` too. With no key found, it aborts before touching a single file.

**Backup and validation.** The whole configuration is copied to `/root/ssh-backup-*` before any edit. If `sshd -t` rejects the syntax, the script restores it and exits without restarting the service.

**Timed safety net.** With `--safety-net N`, a `systemd-run` unit schedules a backup restore N minutes out. You cancel it manually once you've confirmed access works.

**Automatic fail2ban whitelist.** Your current session's IP goes into `ignoreip`. Since sudo clears `SSH_CLIENT` by default (`env_reset`), there are three chained fallbacks: `SSH_CONNECTION`, `who am i` and `last`. If none work, the script warns and suggests `--allow-ip`.

---

## Design decisions

Some choices here contradict the generic checklists floating around the internet. Worth understanding why.

### `UsePAM yes` is kept on purpose

Plenty of guides tell you to disable PAM when using key-based authentication. On Ubuntu that's counterproductive, and the CIS Benchmark itself recommends `UsePAM yes`. Disabling it costs you:

- **pam_systemd** — no `loginctl` session registration and no `XDG_RUNTIME_DIR`, which breaks `systemctl --user` and kills user services on disconnect
- **pam_limits** — `/etc/security/limits.conf` stops applying (`nofile`, `nproc`), which usually resurfaces later as "too many open files"
- **Account expiry and locking**, `/etc/nologin`, motd, faillock
- **SSSD, LDAP or Kerberos**, if you use any

And the main point: `UsePAM no` closes no door here. What allowed passwords was `KbdInteractiveAuthentication`, already disabled. PAM handles session setup and account validation, not the authentication method.

There is a real PAM risk, but it's a different one: `UsePAM yes` combined with `KbdInteractiveAuthentication yes` permits password auth via challenge-response even with `PasswordAuthentication no`. That's precisely why that directive is in the override.

**The `--disable-pam` flag exists anyway**, because some panel scanners treat `UsePAM yes` as a compliance failure and there's no middle ground — the directive is binary. If it's a requirement, use a safety net and test before closing your session:

```bash
sudo ./ssh-hardening.sh --disable-pam --safety-net 10

# in another terminal: a fresh key login must work
ssh user@ip

# on the server: the two things that break first
systemctl --user status      # must not print "Failed to connect to bus"
ulimit -n                    # must not have dropped to 1024
```

Without PAM, sshd validates accounts by reading `/etc/shadow` directly. Accounts with a locked password (`!`) — the default for the `ubuntu` user in cloud images — behave differently. The welcome banner and "Last login" also disappear, since PAM generates them.

fail2ban is unaffected: it reads sshd's logs and doesn't go through PAM.

### Configuration file precedence

In SSH, **the first value read wins**. Since `/etc/ssh/sshd_config` starts with `Include /etc/ssh/sshd_config.d/*.conf`, a `50-cloud-init.conf` left behind by your provider carrying `PasswordAuthentication yes` silently overrides whatever you edit in the main file.

That's why the override uses the `00-` prefix, and why the script also comments out conflicting `yes` directives in the remaining files.

### Mirroring into the main file

The override alone fixes sshd's real behaviour, but panel scanners typically read only `/etc/ssh/sshd_config` and look for the literal line. Without it they assume the OpenSSH default (`yes`) and flag the alert even though everything is correct. The script writes the same values in both places.

The insertion happens right after the `Include` line, never with `>>`. If the file ends with a `Match` block, an append would land inside it and the directive would apply only to that group — a silent and common mistake.

Existing `Match` blocks are preserved, since they may be intentional. But if one contains `PasswordAuthentication yes`, the script warns you: password auth is still open for that group.

### fail2ban read order

Configuration goes to `/etc/fail2ban/jail.local`, not `jail.d/`. The read order is `jail.conf` → `jail.d/*.conf` → `jail.local` → `jail.d/*.local`, so a file in `jail.d/` with a `.local` extension would silently override `jail.local`.

The jail carries both `mode = aggressive` and `filter = sshd[mode=aggressive]`, which say the same thing. `mode` is the canonical form and what scanners look for; the explicit `filter` avoids depending on `jail.conf` variable interpolation.

### Port read from sshd, not assumed

The jail uses the real port from `sshd -T` instead of the default `port = ssh`. If you moved SSH elsewhere, the default would silently monitor port 22.

### About aggressive mode

It's the default because that's what scanners ask for, but calibrate your expectations.

`aggressive` mode adds the `ddos` and `extra` filters, also banning clients that open and close a connection without ever authenticating. With password auth already disabled, the real gain is **less log noise**, not blocking intrusion — no bot is brute-forcing an Ed25519 key.

The risk runs the other way. If a load balancer health check or monitoring probe touches the SSH port, aggressive mode will ban your own infrastructure. In that case:

```bash
sudo ./ssh-hardening.sh --ssh-mode normal
# or
sudo ./ssh-hardening.sh --allow-ip "10.0.0.0/8"
```

---

## Manual verification

```bash
# effective sshd values (not what's written in the files)
sudo sshd -T | grep -Ei "passwordauth|kbdinteractive|usepam|pubkeyauth|permitroot"

# hunt for conflicting directives
sudo grep -ri "passwordauthentication" /etc/ssh/

# fail2ban state
sudo fail2ban-client status
sudo fail2ban-client status sshd
```

A healthy state: `passwordauthentication no`, `kbdinteractiveauthentication no`, `usepam yes`, `pubkeyauthentication yes`.

---

## Troubleshooting

**"No public key found"** — run `ssh-copy-id` from your local machine first. That's the protection doing its job.

**My own fail2ban banned me** — get in through your provider's web/VNC console and run `fail2ban-client set sshd unbanip YOUR.IP`. Then add your IP with `--allow-ip`.

**My SSH client gets banned on connect** — if your agent offers several keys, `MaxAuthTries` (default 6) is exceeded and each attempt counts as a failure. Force a single key:
```bash
ssh -o IdentitiesOnly=yes -i ~/.ssh/your_key user@ip
```

**fail2ban won't start** — check `journalctl -u fail2ban -n 50`. The most common cause is a missing `/var/log/auth.log`, which the script handles automatically.

**I lost access completely** — use your provider's web/VNC console (DigitalOcean, Hetzner, Contabo and others all offer one). It logs you in with a local password, independent of SSH, and you can run `sudo ./ssh-hardening.sh --rollback /root/ssh-backup-*`.

**The panel scanner still flags an alert** — check the real state first:

```bash
sudo sshd -T | grep -Ei 'passwordauth|usepam|kbdinteractive'
sudo fail2ban-client status sshd
```

If those show the correct values, the server is fine and the problem is the panel. Two common causes: the report is cached and only refreshes on the next scan, or the panel manages `sshd_config` itself and rewrites external edits. In the second case, look for the equivalent toggle in its interface — changes made outside tend to be reverted on the next configuration deploy.

---

## Reverting

```bash
sudo ./ssh-hardening.sh --rollback /root/ssh-backup-YYYYMMDD-HHMMSS
```

Restores the SSH configuration, removes the jail it created, unbans every IP and restarts both services. The fail2ban package stays installed.

---

## Warnings

Keep your provider's web/VNC console reachable during the first run. It's the only emergency exit that doesn't depend on SSH.

This script changes critical access settings. Test on a non-production server first if you can, and read the `--dry-run` output.

---

## License

Distributed under the MIT License. See [LICENSE](LICENSE) for the full text.

MIT includes a warranty disclaimer — relevant here, since the script touches settings that can cut off your access to the server. That doesn't replace the precautions described above; it just makes clear that whoever runs it assumes the risk.
