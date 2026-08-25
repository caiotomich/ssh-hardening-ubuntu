# ssh-hardening.sh

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![tests](https://github.com/caiotomich/ssh-hardening-ubuntu/actions/workflows/tests.yml/badge.svg)](https://github.com/caiotomich/ssh-hardening-ubuntu/actions/workflows/tests.yml)

Disables SSH password authentication and configures fail2ban on Ubuntu/Debian servers, with the checks that keep you from locking yourself out of your own machine.

Written to clear the alerts typical VPS panel security scanners raise:

| Scanner item                               | Fixed by                                                        |
| ------------------------------------------ | --------------------------------------------------------------- |
| Password Authentication should be disabled | `PasswordAuthentication no` + `KbdInteractiveAuthentication no` |
| Default Incoming should be set to 'deny'   | `ufw default deny incoming` (with `--enable-ufw`)               |
| Fail2Ban should be installed               | installation via `apt`                                          |
| Fail2Ban service should be enabled         | `systemctl enable fail2ban`                                     |
| Fail2Ban service should be running         | `systemctl restart` + state verification                        |
| SSH protection should be enabled           | `[sshd]` jail with `enabled = true`                             |
| Aggressive mode recommended                | `mode = aggressive`                                             |

---

## Requirements

- Ubuntu 18.04+ or Debian 10+
- Root access (`sudo`)
- **An SSH public key already installed** — the script refuses to run without one

If you don't have one yet, run this on your local machine first:

```
ssh-copy-id user@server-ip
ssh user@server-ip    # must log in without asking for a password
```

---

## Installation

**Recommended** — download, inspect, then run:

```
# 1. download
curl -fsSL https://raw.githubusercontent.com/caiotomich/ssh-hardening-ubuntu/main/ssh-hardening.sh -o ssh-hardening.sh

# 2. read it (q quits the pager)
less ssh-hardening.sh

# 3. run it
sudo bash ssh-hardening.sh --safety-net 10
```

Three separate commands on purpose. Chaining them with `&&` would defeat the point: quitting the pager exits with status 0, so the script would run whether or not you liked what you read.

**One-liner**, if you prefer:

```
curl -fsSL https://raw.githubusercontent.com/caiotomich/ssh-hardening-ubuntu/main/ssh-hardening.sh \
  | sudo bash -s -- --force --safety-net 10
```

The `-s --` is required: without it bash treats `--force` as its own option rather than the script's.

**Or via git:**

```
git clone https://github.com/caiotomich/ssh-hardening-ubuntu.git
cd ssh-hardening-ubuntu
sudo ./ssh-hardening.sh --safety-net 10
```

### Why the two-step version is preferable

This isn't purism. With `curl | bash`, if the connection drops mid-download bash executes whatever arrived — a script truncated at the wrong line applies half the changes and never reaches the `sshd -t` validation. In a script that touches your SSH access, that matters.

`curl -o file && bash file` solves it because curl returns a non-zero exit code on an incomplete transfer, and `&&` stops execution.

The other two reasons are the usual ones: you're running code as root without having read it, and a server can serve different content to `curl` than to a browser.

### Verify integrity

```
sha256sum ssh-hardening.sh
```

Compare against the value published in [CHECKSUMS.txt](CHECKSUMS.txt).

---

## Usage

```
chmod +x ssh-hardening.sh

sudo ./ssh-hardening.sh --dry-run          # see what would happen
sudo ./ssh-hardening.sh --safety-net 10    # apply with a safety net
```

### Recommended first run

1. Run with `--dry-run` and read the output.
2. Run with `--safety-net 10`.
3. **Without closing your current session**, open another terminal and test key-based access.
4. Confirm passwords are blocked:

```
ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password user@ip
```

You should get `Permission denied (publickey)`.

5. All good? Cancel the automatic rollback:

```
sudo systemctl stop ssh-hardening-rollback.timer
```

If something goes wrong and you lose access, just wait out the 10 minutes — the server restores itself.

---

## Options

| Flag                    | Effect                                                       |
| ----------------------- | ------------------------------------------------------------ |
| `--dry-run`             | Shows every action without performing any                    |
| `--force`               | Skips the interactive confirmation                           |
| `--safety-net N`        | Schedules an automatic backup restore in N minutes           |
| `--rollback DIR`        | Restores a previous backup and reverts fail2ban              |
| `--skip-fail2ban`       | Touches sshd only                                            |
| `--only-fail2ban`       | Configures fail2ban only, leaves sshd alone                  |
| `--ssh-mode MODE`       | `normal`, `ddos`, `extra` or `aggressive` (default)          |
| `--allow-ip "IPs"`      | IPs or ranges fail2ban must never ban                        |
| `--disable-pam`         | Applies `UsePAM no` (read the risks below first)             |
| `--enable-ufw`          | Enables ufw with `default deny incoming`                     |
| `--allow-port N`        | Opens inbound TCP port N. Repeatable. Implies `--enable-ufw` |
| `--docker-group [USER]` | Adds USER to the docker group (default: `$SUDO_USER`)        |
| `-h`, `--help`          | Short help                                                   |

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

### Firewall (ufw)

Off by default — enable it explicitly:

```
# firewall with everything inbound denied except SSH
sudo ./ssh-hardening.sh --enable-ufw --safety-net 10

# web server: also open 80 and 443
sudo ./ssh-hardening.sh --enable-ufw --allow-port 80 --allow-port 443 --safety-net 10
```

`--allow-port` implies `--enable-ufw`, since opening a port in a firewall that isn't running means nothing.

Rules applied:

```
default deny incoming
default allow outgoing
allow <sshd's real port>/tcp
allow <each --allow-port>/tcp
```

Ports are opened for TCP only. For UDP or anything more specific, use `ufw allow` directly after the run.

### Docker group

```
sudo ./ssh-hardening.sh --docker-group          # adds the invoking user
sudo ./ssh-hardening.sh --docker-group deploy   # adds a specific user
```

Equivalent to `usermod -aG docker $USER`, with three differences that matter.

**It uses `$SUDO_USER`, not `$USER`.** Under sudo, `env_reset` sets `USER=root`, so the literal command adds *root* to the docker group — pointless, and it silently fails to add the user you meant.

**It checks before acting.** If the `docker` group doesn't exist, the user doesn't exist, or they're already a member, it says so and moves on instead of erroring out mid-run.

**It tells you what you just granted.** The docker group is root-equivalent: a member can mount the host filesystem inside a container and escape to root. That's a legitimate trade-off, but worth stating out loud in a script otherwise dedicated to reducing privilege.

Membership applies to new sessions only — log out and back in.

### fail2ban configuration applied

```
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

**SSH rule before the firewall goes up.** Turning on `default deny incoming` without an SSH rule in place is an instant lockout. The script reads the real port from `sshd -T`, adds the allow rule, verifies it registered with `ufw show added`, and only then runs `ufw --force enable`. If the rule doesn't register, ufw is left off rather than enabled blind.

**The safety net covers the firewall too.** If the script was the one that enabled ufw, it drops a marker in the backup directory. The scheduled rollback checks for that marker and disables ufw along with restoring the SSH config — otherwise restoring `sshd_config` would be useless while the firewall kept blocking. A ufw that was already running before the script ran is never touched.

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

```
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

### Docker bypasses ufw

If Docker is installed, the script prints a warning when enabling the firewall, because `deny incoming` does not do what it looks like it does.

Docker writes its own rules into the `nat` table's `PREROUTING` chain, which is evaluated *before* ufw's chains. A container published with `-p 8080:80` stays reachable from the internet with the firewall fully active. Worse for compliance purposes: the scanner reports "Default Incoming: deny" as passing while those ports are wide open.

Publish on loopback and put a reverse proxy in front:

```
docker run -p 127.0.0.1:8080:80 ...
```

```
ports:
  - "127.0.0.1:8080:80"
```

To check what is actually exposed, `ufw status` won't tell you — use `sudo iptables -t nat -L DOCKER -n`. Rules that need to apply to container traffic belong in the `DOCKER-USER` chain, the only one evaluated before Docker's.

### ufw runs before fail2ban

Order matters. The fail2ban section picks its `banaction` based on whether ufw is active: with a live firewall it uses `banaction = ufw`, so bans become ufw rules instead of a separate iptables chain. Configuring ufw afterwards would leave fail2ban writing to the wrong place.

The two are not redundant. ufw decides which ports are reachable at all; fail2ban decides who gets cut off after repeated failures on a port that is open.

### Port read from sshd, not assumed

The jail uses the real port from `sshd -T` instead of the default `port = ssh`. If you moved SSH elsewhere, the default would silently monitor port 22.

### About aggressive mode

It's the default because that's what scanners ask for, but calibrate your expectations.

`aggressive` mode adds the `ddos` and `extra` filters, also banning clients that open and close a connection without ever authenticating. With password auth already disabled, the real gain is **less log noise**, not blocking intrusion — no bot is brute-forcing an Ed25519 key.

The risk runs the other way. If a load balancer health check or monitoring probe touches the SSH port, aggressive mode will ban your own infrastructure. In that case:

```
sudo ./ssh-hardening.sh --ssh-mode normal
# or
sudo ./ssh-hardening.sh --allow-ip "10.0.0.0/8"
```

---

## Manual verification

```
# effective sshd values (not what's written in the files)
sudo sshd -T | grep -Ei "passwordauth|kbdinteractive|usepam|pubkeyauth|permitroot"

# hunt for conflicting directives
sudo grep -ri "passwordauthentication" /etc/ssh/

# fail2ban state
sudo fail2ban-client status
sudo fail2ban-client status sshd

# firewall state
sudo ufw status verbose
```

A healthy state: `passwordauthentication no`, `kbdinteractiveauthentication no`, `usepam yes`, `pubkeyauthentication yes`.

---

## Troubleshooting

**"No public key found"** — run `ssh-copy-id` from your local machine first. That's the protection doing its job.

**My own fail2ban banned me** — get in through your provider's web/VNC console and run `fail2ban-client set sshd unbanip YOUR.IP`. Then add your IP with `--allow-ip`.

**My SSH client gets banned on connect** — if your agent offers several keys, `MaxAuthTries` (default 6) is exceeded and each attempt counts as a failure. Force a single key:

```
ssh -o IdentitiesOnly=yes -i ~/.ssh/your_key user@ip
```

**fail2ban won't start** — check `journalctl -u fail2ban -n 50`. The most common cause is a missing `/var/log/auth.log`, which the script handles automatically.

**ufw locked me out** — if you used `--safety-net`, wait it out: the scheduled rollback disables ufw and restores the SSH config. Otherwise use your provider's console and run `sudo ufw disable`.

**`docker` command says permission denied after `--docker-group`** — group membership is resolved at login. Log out and back in, or run `newgrp docker` for the current shell.

**I lost access completely** — use your provider's web/VNC console (DigitalOcean, Hetzner, Contabo and others all offer one). It logs you in with a local password, independent of SSH, and you can run `sudo ./ssh-hardening.sh --rollback /root/ssh-backup-*`.

**A service stopped responding after enabling ufw** — expected. Everything inbound is denied except SSH and whatever you passed to `--allow-port`. Open what you need:

```
sudo ufw allow 3306/tcp
sudo ufw status verbose
```

**The panel scanner still flags an alert** — check the real state first:

```
sudo sshd -T | grep -Ei 'passwordauth|usepam|kbdinteractive'
sudo fail2ban-client status sshd
```

If those show the correct values, the server is fine and the problem is the panel. Two common causes: the report is cached and only refreshes on the next scan, or the panel manages `sshd_config` itself and rewrites external edits. In the second case, look for the equivalent toggle in its interface — changes made outside tend to be reverted on the next configuration deploy.

---

## Reverting

```
sudo ./ssh-hardening.sh --rollback /root/ssh-backup-YYYYMMDD-HHMMSS
```

Restores the SSH configuration, removes the jail it created, unbans every IP and restarts both services. If the script was the one that enabled ufw, the firewall is disabled too; a ufw that predates the run is left alone. Packages stay installed.

---

## Development

Run the test suite:

```
sudo bash tests/run.sh
```

Root is required because the script refuses to run as anyone else, and the end-to-end test executes it for real in `--dry-run` mode. External tools — `sshd`, `ufw`, `systemctl`, `fail2ban-*`, `apt-get` — are stubbed in `tests/stubs/` and intercepted through `PATH`, so nothing on the machine running the tests is touched.

The suite covers argument parsing, the post-parse validation, authorized-key detection, and a full `--dry-run` pass over the ufw and fail2ban sections. Two of its assertions are unusual and deliberate:

- One asserts that `(( x++ ))` returns a non-zero status when `x` is 0. That is not a bash lesson — it is the reason key counting uses `total_keys=$(( total_keys + 1 ))`. Under `set -e` the shorter form aborted the script mid-check, with no message, whenever the only key lived in a central `AuthorizedKeysFile`.

- One asserts the *wrong* behaviour on purpose: a key preceded by options (`from="..."`, `command="..."`, `restrict,...`) is currently not counted. The test documents the gap and will fail the day it is fixed, which is when it should be updated.

### `SSH_HARDENING_SOURCE_ONLY`

An environment variable, not a flag, and not something you need for normal use. The test suite sets it to load the script's functions without running anything.

It exists because the usual idiom for this — comparing `BASH_SOURCE` against `$0` — breaks the piped install: under `curl | bash` there is no `BASH_SOURCE`, and the comparison would make the script silently do nothing in exactly the mode documented above. Opting in through the environment keeps that path working.

If the variable ever leaks into a real run, the script exits without touching the system. That is the only thing it can do.

---

## Warnings

Keep your provider's web/VNC console reachable during the first run. It's the only emergency exit that doesn't depend on SSH.

This script changes critical access settings. Test on a non-production server first if you can, and read the `--dry-run` output.

---

## License

Distributed under the MIT License. See [LICENSE](LICENSE) for the full text.

MIT includes a warranty disclaimer — relevant here, since the script touches settings that can cut off your access to the server. That doesn't replace the precautions described above; it just makes clear that whoever runs it assumes the risk.
