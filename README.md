# ssh-hardening.sh

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Desativa autenticação por senha no SSH e configura o fail2ban em servidores Ubuntu/Debian, com verificações que evitam o cenário clássico de perder o acesso ao próprio servidor.

Escrito para resolver os alertas típicos de scanners de segurança de painéis de VPS:

| Item do relatório | Resolvido por |
|---|---|
| Password Authentication should be disabled | `PasswordAuthentication no` + `KbdInteractiveAuthentication no` |
| Fail2Ban should be installed | instalação via `apt` |
| Fail2Ban service should be enabled | `systemctl enable fail2ban` |
| Fail2Ban service should be running | `systemctl restart` + verificação de estado |
| SSH protection should be enabled | jail `[sshd]` com `enabled = true` |
| Aggressive mode recommended | `filter = sshd[mode=aggressive]` |

---

## Requisitos

- Ubuntu 18.04+ ou Debian 10+
- Acesso root (`sudo`)
- **Uma chave pública SSH já instalada** — o script recusa rodar sem isso

Se ainda não tiver, execute na sua máquina local antes de qualquer coisa:

```bash
ssh-copy-id usuario@ip-do-servidor
ssh usuario@ip-do-servidor    # precisa entrar sem pedir senha
```

---

## Uso

```bash
chmod +x ssh-hardening.sh

sudo ./ssh-hardening.sh --dry-run          # ver o que aconteceria
sudo ./ssh-hardening.sh --safety-net 10    # aplicar com rede de proteção
```

### Fluxo recomendado na primeira execução

1. Rode com `--dry-run` e leia a saída.
2. Rode com `--safety-net 10`.
3. **Sem fechar a sessão atual**, abra outro terminal e teste o acesso por chave.
4. Confirme que a senha foi bloqueada:
   ```bash
   ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password usuario@ip
   ```
   O esperado é `Permission denied (publickey)`.
5. Deu tudo certo? Cancele o rollback automático:
   ```bash
   sudo systemctl stop ssh-hardening-rollback.timer
   ```

Se algo der errado e você perder o acesso, é só esperar os 10 minutos: o servidor se restaura sozinho.

---

## Opções

| Flag | Efeito |
|---|---|
| `--dry-run` | Mostra todas as ações sem executar nenhuma |
| `--force` | Não pede confirmação interativa |
| `--safety-net N` | Agenda restauração automática do backup em N minutos |
| `--rollback DIR` | Restaura um backup anterior e reverte o fail2ban |
| `--skip-fail2ban` | Só mexe no sshd |
| `--only-fail2ban` | Só configura o fail2ban, não altera o sshd |
| `--ssh-mode MODO` | `normal`, `ddos`, `extra` ou `aggressive` (padrão) |
| `--allow-ip "IPs"` | IPs ou faixas que o fail2ban nunca deve banir |
| `-h`, `--help` | Ajuda resumida |

---

## O que é alterado

### Arquivos criados

```
/etc/ssh/sshd_config.d/00-hardening.conf   # diretivas do sshd
/etc/fail2ban/jail.d/00-hardening.local    # jail [sshd] e defaults
/etc/fail2ban/fail2ban.local               # allowipv6 e retenção do banco
/root/ssh-backup-AAAAMMDD-HHMMSS/          # backup da config original
```

O script **nunca edita** `jail.conf` nem `fail2ban.conf` — esses arquivos são sobrescritos a cada atualização do pacote.

### Configuração aplicada ao sshd

```
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitRootLogin prohibit-password
AuthenticationMethods publickey
UsePAM yes
```

### Configuração aplicada ao fail2ban

```ini
[DEFAULT]
bantime   = 1h
findtime  = 10m
maxretry  = 5
bantime.increment = true    # 1h → 2h → 4h ... até 1 semana
bantime.factor    = 2
bantime.maxtime   = 1w

[sshd]
enabled  = true
maxretry = 3
filter   = sshd[mode=aggressive]
```

---

## Proteções contra lockout

O script foi construído em torno da premissa de que a falha mais provável não é um invasor — é você mesmo se trancando para fora.

**Verificação de chaves antes de tudo.** Ele varre `/root` e `/home/*` procurando `authorized_keys` com pelo menos uma chave válida, e também respeita `AuthorizedKeysFile` customizado. Sem nenhuma chave, aborta antes de tocar em qualquer arquivo.

**Backup e validação.** Toda a configuração vai para `/root/ssh-backup-*` antes de qualquer edição. Se o `sshd -t` reprovar a sintaxe, o script restaura sozinho e sai sem reiniciar o serviço.

**Rede de proteção temporizada.** Com `--safety-net N`, um `systemd-run` agenda a restauração do backup para daqui a N minutos. Você cancela manualmente depois de confirmar que o acesso funciona.

**Whitelist automática no fail2ban.** O IP da sua sessão atual entra no `ignoreip`. Como o `sudo` limpa `SSH_CLIENT` por padrão (`env_reset`), há três fallbacks encadeados: `SSH_CONNECTION`, `who am i` e `last`. Se nenhum funcionar, o script avisa e sugere `--allow-ip`.

---

## Decisões técnicas

Algumas escolhas do script contrariam checklists genéricos que circulam pela internet. Vale entender o porquê.

### `UsePAM yes` é mantido de propósito

Muitos guias mandam desativar o PAM quando se usa autenticação por chave. No Ubuntu isso é contraproducente, e o próprio CIS Benchmark recomenda `UsePAM yes`. Ao desativar, você perde:

- **pam_systemd** — sem registro no `loginctl` e sem `XDG_RUNTIME_DIR`, o que quebra `systemctl --user` e derruba serviços de usuário na desconexão
- **pam_limits** — `/etc/security/limits.conf` deixa de valer (`nofile`, `nproc`), o que costuma reaparecer depois como "too many open files"
- **Expiração e bloqueio de contas**, `/etc/nologin`, motd, faillock
- **SSSD, LDAP ou Kerberos**, se você usar

E o principal: `UsePAM no` não fecha nenhuma porta aqui. Quem permitia senha era o `KbdInteractiveAuthentication`, já desativado. O PAM cuida de sessão e validação de conta, não do método de autenticação.

O risco real com PAM existe, mas é outro: `UsePAM yes` combinado com `KbdInteractiveAuthentication yes` permite senha via challenge-response mesmo com `PasswordAuthentication no`. É exatamente por isso que aquela diretiva está no override.

### Precedência dos arquivos de configuração

No SSH, **o primeiro valor lido vence**. Como `/etc/ssh/sshd_config` começa com `Include /etc/ssh/sshd_config.d/*.conf`, um `50-cloud-init.conf` deixado pelo provedor com `PasswordAuthentication yes` sobrescreve silenciosamente o que você editar no arquivo principal.

Por isso o override usa o prefixo `00-`, e o script ainda comenta as diretivas `yes` conflitantes nos demais arquivos — o que também faz scanners que leem arquivos (em vez do valor efetivo) pararem de acusar o alerta.

### Backend de log no Ubuntu 24.04

As imagens minimais do Ubuntu 24.04 não trazem mais o rsyslog, então `/var/log/auth.log` não existe. O jail `sshd` do fail2ban falha com *"Have not found any log file"* — o serviço sobe, o scanner marca como "Installed e Active", mas nada está sendo protegido.

O script detecta a ausência do arquivo, instala `python3-systemd` e configura `backend = systemd` para ler direto do journal.

### Porta lida do sshd, não presumida

O jail usa a porta real obtida de `sshd -T`, em vez do `port = ssh` padrão. Se você moveu o SSH para outra porta, o padrão monitoraria a porta 22 sem avisar.

### Sobre o modo aggressive

É o padrão porque é o que os scanners pedem, mas vale calibrar a expectativa.

O modo `aggressive` soma os filtros `ddos` e `extra`, banindo também quem abre e fecha conexão sem chegar a autenticar. Com a senha já desativada, o ganho real é **reduzir ruído de log**, não impedir invasão — nenhum bot vai adivinhar uma chave Ed25519 por força bruta.

O risco está do outro lado. Se houver health-check de load balancer ou monitoramento tocando na porta SSH, o modo aggressive vai banir sua própria infraestrutura. Nesses casos:

```bash
sudo ./ssh-hardening.sh --ssh-mode normal
# ou
sudo ./ssh-hardening.sh --allow-ip "10.0.0.0/8"
```

---

## Verificação manual

```bash
# valores efetivos do sshd (não o que está escrito nos arquivos)
sudo sshd -T | grep -Ei "passwordauth|kbdinteractive|usepam|pubkeyauth|permitroot"

# procurar diretivas conflitantes espalhadas
sudo grep -ri "passwordauthentication" /etc/ssh/

# estado do fail2ban
sudo fail2ban-client status
sudo fail2ban-client status sshd
```

Estado saudável: `passwordauthentication no`, `kbdinteractiveauthentication no`, `usepam yes`, `pubkeyauthentication yes`.

---

## Problemas comuns

**"Nenhuma chave publica encontrada"** — rode `ssh-copy-id` na máquina local antes. É a proteção funcionando.

**Fui banido pelo meu próprio fail2ban** — entre pelo console web/VNC do provedor e execute `fail2ban-client set sshd unbanip SEU.IP`. Depois adicione seu IP com `--allow-ip`.

**Meu cliente SSH leva ban ao conectar** — se o agente oferece várias chaves, o `MaxAuthTries` (padrão 6) estoura e conta como tentativas falhas. Force uma chave só:
```bash
ssh -o IdentitiesOnly=yes -i ~/.ssh/sua_chave usuario@ip
```

**fail2ban não sobe** — veja `journalctl -u fail2ban -n 50`. A causa mais comum é o `/var/log/auth.log` ausente, tratada automaticamente pelo script.

**Perdi o acesso completamente** — use o console web/VNC do painel do provedor (DigitalOcean, Hetzner, Contabo, etc. todos oferecem). Lá você entra com senha local, independente do SSH, e roda `sudo ./ssh-hardening.sh --rollback /root/ssh-backup-*`.

---

## Reverter

```bash
sudo ./ssh-hardening.sh --rollback /root/ssh-backup-AAAAMMDD-HHMMSS
```

Restaura a configuração do SSH, remove o jail criado, desbane todos os IPs e reinicia os dois serviços. O pacote fail2ban permanece instalado.

---

## Avisos

Mantenha o console web/VNC do seu provedor acessível durante a primeira execução. É a única saída de emergência que não depende do SSH.

O script altera configurações críticas de acesso. Teste em um servidor não-produtivo antes, se possível, e leia a saída do `--dry-run`.

---

## Licença

Distribuído sob a licença MIT. Veja [LICENSE](LICENSE) para o texto completo.

A MIT inclui isenção de garantia — relevante aqui, já que o script mexe em configurações que podem cortar seu acesso ao servidor. Isso não substitui os cuidados descritos acima; apenas deixa claro que quem executa assume o risco.
