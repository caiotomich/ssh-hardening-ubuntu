#!/usr/bin/env bash
#
# ssh-hardening.sh - Desativa senha no SSH + configura fail2ban (Ubuntu/Debian)
#
# Copyright (c) 2026 SEU NOME
# Licenciado sob a MIT License. Veja o arquivo LICENSE.
#
# Uso:
#   sudo ./ssh-hardening.sh                    # aplica com confirmacao
#   sudo ./ssh-hardening.sh --dry-run          # apenas mostra o que faria
#   sudo ./ssh-hardening.sh --force            # sem perguntar
#   sudo ./ssh-hardening.sh --safety-net 10    # reverte sozinho em 10 min
#   sudo ./ssh-hardening.sh --rollback DIR     # restaura um backup
#
#   --skip-fail2ban            nao mexe no fail2ban
#   --only-fail2ban            so configura o fail2ban, nao toca no sshd
#   --ssh-mode normal|aggressive   modo do filtro sshd (padrao: aggressive)
#   --allow-ip "1.2.3.4 5.6.7.0/24"  IPs que o fail2ban nunca bane
#
# O safety-net e a rede de protecao: agenda a restauracao automatica do
# backup. Se voce testar o acesso e estiver tudo certo, cancele o timer
# com o comando que o script informa no final.

set -euo pipefail

readonly SSHD_CONFIG="/etc/ssh/sshd_config"
readonly SSHD_CONFIG_D="/etc/ssh/sshd_config.d"
readonly OVERRIDE="${SSHD_CONFIG_D}/00-hardening.conf"
readonly BACKUP_DIR="/root/ssh-backup-$(date +%Y%m%d-%H%M%S)"
readonly TIMER_UNIT="ssh-hardening-rollback"

readonly F2B_JAIL="/etc/fail2ban/jail.d/00-hardening.local"
readonly F2B_LOCAL="/etc/fail2ban/fail2ban.local"

DRY_RUN=0
FORCE=0
SAFETY_NET=0
SKIP_F2B=0
ONLY_F2B=0
SSH_MODE="aggressive"
ALLOW_IP=""

# ---------- saida ----------
c_red=$'\033[0;31m'; c_grn=$'\033[0;32m'; c_yel=$'\033[0;33m'
c_blu=$'\033[0;34m'; c_off=$'\033[0m'

info() { printf '%s[INFO]%s %s\n'  "$c_blu" "$c_off" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n'  "$c_grn" "$c_off" "$*"; }
warn() { printf '%s[AVISO]%s %s\n' "$c_yel" "$c_off" "$*"; }
die()  { printf '%s[ERRO]%s %s\n'  "$c_red" "$c_off" "$*" >&2; exit 1; }

run() {
    if (( DRY_RUN )); then
        printf '  %s(dry-run)%s %s\n' "$c_yel" "$c_off" "$*"
    else
        "$@"
    fi
}

# ---------- argumentos ----------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)    DRY_RUN=1; shift ;;
        --force)      FORCE=1; shift ;;
        --safety-net) SAFETY_NET="${2:?informe os minutos}"; shift 2 ;;
        --rollback)   ROLLBACK_DIR="${2:?informe o diretorio de backup}"; shift 2 ;;
        --skip-fail2ban) SKIP_F2B=1; shift ;;
        --only-fail2ban) ONLY_F2B=1; shift ;;
        --ssh-mode)   SSH_MODE="${2:?normal ou aggressive}"; shift 2 ;;
        --allow-ip)   ALLOW_IP="${2:?informe um ou mais IPs}"; shift 2 ;;
        -h|--help)    sed -n '3,22p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *)            die "opcao desconhecida: $1" ;;
    esac
done

[[ $EUID -eq 0 ]] || die "execute como root (sudo $0)"
[[ "$SSH_MODE" =~ ^(normal|ddos|extra|aggressive)$ ]] || die "--ssh-mode invalido: $SSH_MODE"

# Descobre o IP de onde voce esta conectado, para nunca se auto-banir.
# Atencao: o sudo limpa SSH_CLIENT por padrao (env_reset), entao ha fallbacks.
detect_client_ip() {
    local ip=""
    [[ -n "${SSH_CLIENT:-}" ]]     && ip=$(awk '{print $1}' <<<"$SSH_CLIENT")
    [[ -z "$ip" && -n "${SSH_CONNECTION:-}" ]] && ip=$(awk '{print $1}' <<<"$SSH_CONNECTION")
    [[ -z "$ip" ]] && ip=$(who am i 2>/dev/null | sed -nE 's/.*\(([0-9a-fA-F.:]+)\)[[:space:]]*$/\1/p')
    [[ -z "$ip" ]] && ip=$(last -w -i -n1 "${SUDO_USER:-root}" 2>/dev/null | awk 'NR==1{print $3}')
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$|^[0-9a-fA-F:]+:[0-9a-fA-F:]+$ ]] && printf '%s' "$ip"
}

# ---------- rollback manual ----------
if [[ -n "${ROLLBACK_DIR:-}" ]]; then
    [[ -d "$ROLLBACK_DIR" ]] || die "backup nao encontrado: $ROLLBACK_DIR"
    info "Restaurando de $ROLLBACK_DIR"
    cp -a "$ROLLBACK_DIR/sshd_config" "$SSHD_CONFIG"
    rm -rf "$SSHD_CONFIG_D"
    [[ -d "$ROLLBACK_DIR/sshd_config.d" ]] && cp -a "$ROLLBACK_DIR/sshd_config.d" "$SSHD_CONFIG_D"
    sshd -t || die "config restaurada esta invalida - intervencao manual necessaria"
    systemctl restart ssh
    ok "Configuracao SSH restaurada e servico reiniciado."

    if [[ -f "$F2B_JAIL" ]]; then
        info "Removendo jail do fail2ban e desbanindo todos os IPs"
        rm -f "$F2B_JAIL"
        fail2ban-client unban --all >/dev/null 2>&1 || true
        systemctl restart fail2ban 2>/dev/null || true
        ok "fail2ban revertido (pacote mantido instalado)."
    fi
    exit 0
fi

if (( ONLY_F2B )); then
    info "Modo --only-fail2ban: o sshd nao sera alterado."
else

# ---------- 1. verificar chaves instaladas ----------
info "Procurando chaves publicas autorizadas..."

declare -a users_with_keys=()
total_keys=0

while IFS= read -r home; do
    ak="$home/.ssh/authorized_keys"
    [[ -s "$ak" ]] || continue
    n=$(grep -cE '^[[:space:]]*(ssh-|ecdsa-|sk-)' "$ak" || true)
    (( n > 0 )) || continue
    user=$(basename "$home"); [[ "$home" == "/root" ]] && user="root"
    users_with_keys+=("$user ($n chave(s))")
    (( total_keys += n ))
done < <(printf '%s\n' /root /home/*)

# tambem cobre AuthorizedKeysFile customizado em local central
if akf=$(sshd -T 2>/dev/null | awk '/^authorizedkeysfile /{$1=""; print}'); then
    for pat in $akf; do
        [[ "$pat" == *%u* || "$pat" == .ssh/* ]] && continue
        [[ -s "$pat" ]] && { users_with_keys+=("$pat (arquivo central)"); (( total_keys++ )); }
    done
fi

if (( total_keys == 0 )); then
    die "Nenhuma chave publica encontrada. Rode 'ssh-copy-id usuario@servidor'
       na sua maquina local ANTES de continuar, ou voce ficara sem acesso."
fi

ok "Chaves encontradas:"
printf '       - %s\n' "${users_with_keys[@]}"

if [[ ! " ${users_with_keys[*]} " =~ [^a-z]root[^a-z] ]] && (( ${#users_with_keys[@]} == 1 )); then
    warn "Apenas um usuario tem chave. Se perder essa chave, sobra so o console do provedor."
fi

# ---------- 2. mostrar estado atual ----------
info "Estado atual:"
sshd -T 2>/dev/null | grep -Ei '^(passwordauthentication|kbdinteractiveauthentication|usepam|pubkeyauthentication|permitrootlogin) ' \
    | sed 's/^/       /' || warn "nao foi possivel ler a config efetiva"

# ---------- 3. confirmar ----------
if (( ! FORCE && ! DRY_RUN )); then
    printf '\n%sDesativar autenticacao por senha agora? [s/N]%s ' "$c_yel" "$c_off"
    read -r resp
    [[ "$resp" =~ ^[sSyY]$ ]] || { info "Cancelado."; exit 0; }
fi

# ---------- 4. backup ----------
info "Backup em $BACKUP_DIR"
run mkdir -p "$BACKUP_DIR"
run cp -a "$SSHD_CONFIG" "$BACKUP_DIR/"
[[ -d "$SSHD_CONFIG_D" ]] && run cp -a "$SSHD_CONFIG_D" "$BACKUP_DIR/"

# ---------- 5. neutralizar diretivas conflitantes ----------
# No SSH o PRIMEIRO valor lido vence. Comentamos os "yes" espalhados
# (ex: 50-cloud-init.conf) para evitar surpresa e para satisfazer
# scanners que leem os arquivos em vez do valor efetivo.
info "Neutralizando diretivas conflitantes..."
shopt -s nullglob
for f in "$SSHD_CONFIG" "$SSHD_CONFIG_D"/*.conf; do
    [[ "$f" == "$OVERRIDE" ]] && continue
    if grep -qiE '^[[:space:]]*(PasswordAuthentication|KbdInteractiveAuthentication|ChallengeResponseAuthentication)[[:space:]]+yes' "$f"; then
        info "  ajustando $f"
        run sed -i -E 's/^([[:space:]]*(PasswordAuthentication|KbdInteractiveAuthentication|ChallengeResponseAuthentication)[[:space:]]+yes)/#\1  # desativado por ssh-hardening.sh/I' "$f"
    fi
done
shopt -u nullglob

# ---------- 6. escrever override ----------
if grep -qiE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' "$SSHD_CONFIG"; then
    info "Escrevendo $OVERRIDE"
    run mkdir -p "$SSHD_CONFIG_D"
    if (( DRY_RUN )); then
        printf '  %s(dry-run)%s conteudo do override\n' "$c_yel" "$c_off"
    else
        cat > "$OVERRIDE" <<'EOF'
# Gerado por ssh-hardening.sh
# Prefixo 00- garante precedencia sobre 50-cloud-init.conf e afins.

PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitRootLogin prohibit-password
AuthenticationMethods publickey

# UsePAM fica ATIVO de proposito: e o recomendado no Ubuntu (CIS Benchmark).
# Ele nao abre caminho de senha aqui - quem faz isso e o KbdInteractive,
# ja desativado acima. Desligar o PAM quebra pam_systemd (systemctl --user),
# pam_limits (nofile/nproc), expiracao de contas e /etc/nologin.
UsePAM yes
EOF
        chmod 600 "$OVERRIDE"
    fi
else
    # Ubuntu 18.04/20.04 antigos: sem Include, escreve no arquivo principal
    warn "Sem diretiva Include - aplicando direto em $SSHD_CONFIG"
    if (( ! DRY_RUN )); then
        printf '\n# ssh-hardening.sh\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nPubkeyAuthentication yes\nPermitRootLogin prohibit-password\nUsePAM yes\n' >> "$SSHD_CONFIG"
    fi
fi

# ---------- 7. validar ----------
info "Validando sintaxe..."
if (( ! DRY_RUN )); then
    if ! sshd -t 2>/tmp/sshd-test.err; then
        warn "Sintaxe invalida. Revertendo automaticamente."
        cp -a "$BACKUP_DIR/sshd_config" "$SSHD_CONFIG"
        rm -rf "$SSHD_CONFIG_D"
        [[ -d "$BACKUP_DIR/sshd_config.d" ]] && cp -a "$BACKUP_DIR/sshd_config.d" "$SSHD_CONFIG_D"
        cat /tmp/sshd-test.err >&2
        die "nada foi alterado"
    fi
fi
ok "Sintaxe valida."

# ---------- 8. rede de protecao ----------
if (( SAFETY_NET > 0 && ! DRY_RUN )); then
    systemd-run --unit="$TIMER_UNIT" --on-active="${SAFETY_NET}m" \
        /bin/bash -c "cp -a '$BACKUP_DIR/sshd_config' '$SSHD_CONFIG'; \
                      rm -rf '$SSHD_CONFIG_D'; \
                      [ -d '$BACKUP_DIR/sshd_config.d' ] && cp -a '$BACKUP_DIR/sshd_config.d' '$SSHD_CONFIG_D'; \
                      systemctl restart ssh" >/dev/null 2>&1
    warn "Rollback automatico agendado para daqui a ${SAFETY_NET} minuto(s)."
fi

# ---------- 9. reiniciar ----------
info "Reiniciando SSH (conexoes ativas nao caem)..."
if systemctl is-active --quiet ssh.socket 2>/dev/null; then
    run systemctl restart ssh.socket   # Ubuntu 24.04+ (socket-activated)
    run systemctl restart ssh || true
else
    run systemctl restart ssh
fi
ok "SSH reiniciado."

# ---------- 10. verificar resultado ----------
if (( ! DRY_RUN )); then
    printf '\n'
    info "Configuracao efetiva agora:"
    eff=$(sshd -T | grep -Ei '^(passwordauthentication|kbdinteractiveauthentication|usepam|pubkeyauthentication|permitrootlogin) ')
    printf '%s\n' "$eff" | sed 's/^/       /'

    if grep -qi '^passwordauthentication no' <<<"$eff" \
    && grep -qi '^kbdinteractiveauthentication no' <<<"$eff"; then
        ok "Autenticacao por senha DESATIVADA."
    else
        warn "Algo ainda permite senha. Revise: grep -ri passwordauth /etc/ssh/"
    fi
fi

fi   # <-- fim do bloco sshd (--only-fail2ban pula tudo acima)

# ---------- 11. fail2ban ----------
setup_fail2ban() {
    local ver backend_line banaction ignore ip ports nregex

    # 11.1 instalacao
    if command -v fail2ban-server >/dev/null 2>&1; then
        ver=$(fail2ban-server --version 2>/dev/null | head -1)
        ok "  ja instalado: ${ver:-versao desconhecida}"
    else
        info "  instalando pacote fail2ban..."
        run env DEBIAN_FRONTEND=noninteractive apt-get update -qq
        run env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq fail2ban
    fi

    # 11.2 fonte dos logs
    # Imagens minimas do Ubuntu 24.04 nao trazem rsyslog: /var/log/auth.log
    # nao existe e o jail sshd morre com "Have not found any log file".
    if [[ -f /var/log/auth.log ]]; then
        backend_line="backend  = auto"
    else
        warn "  /var/log/auth.log ausente - lendo direto do journal"
        run env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3-systemd
        backend_line="backend  = systemd"
    fi

    # 11.3 como banir
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^status: active'; then
        banaction="ufw"
        info "  ufw ativo - banimentos entram como regra ufw"
    else
        banaction="iptables-multiport"
    fi

    # 11.4 porta real do sshd (nao assume 22)
    ports=$(sshd -T 2>/dev/null | awk '/^port /{print $2}' | paste -sd, -)
    [[ -z "$ports" ]] && ports="ssh"
    info "  porta(s) monitorada(s): $ports"

    # 11.5 whitelist - o equivalente a "nao se trancar do lado de fora"
    ignore="127.0.0.1/8 ::1"
    ip=$(detect_client_ip || true)
    if [[ -n "$ip" ]]; then
        ignore="$ignore $ip"
        ok "  seu IP atual ($ip) entrou na whitelist"
    else
        warn "  nao identifiquei seu IP - rode com --allow-ip \"SEU.IP\" se tiver IP fixo"
    fi
    [[ -n "$ALLOW_IP" ]] && ignore="$ignore $ALLOW_IP"

    # 11.6 arquivos de configuracao
    # Nunca editar jail.conf/fail2ban.conf: sao sobrescritos em cada upgrade.
    if (( DRY_RUN )); then
        printf '  %s(dry-run)%s escreveria %s e %s\n' "$c_yel" "$c_off" "$F2B_LOCAL" "$F2B_JAIL"
    else
        cat > "$F2B_LOCAL" <<EOF
# Gerado por ssh-hardening.sh
[Definition]
allowipv6  = auto
# Retencao maior no banco: necessaria para o bantime incremental funcionar.
dbpurgeage = 30d
EOF

        mkdir -p /etc/fail2ban/jail.d
        cat > "$F2B_JAIL" <<EOF
# Gerado por ssh-hardening.sh
[DEFAULT]
ignoreip  = $ignore
bantime   = 1h
findtime  = 10m
maxretry  = 5
banaction = $banaction

# Reincidente apanha mais: 1h -> 2h -> 4h ... ate 1 semana.
bantime.increment = true
bantime.factor    = 2
bantime.maxtime   = 1w

[sshd]
enabled  = true
port     = $ports
maxretry = 3
$backend_line
# mode=$SSH_MODE  (normal | ddos | extra | aggressive)
# aggressive = normal + ddos + extra: tambem bane quem so abre e fecha
# conexao sem autenticar. Cuidado se houver health-check de LB na porta SSH.
filter   = sshd[mode=$SSH_MODE]
EOF
        chmod 644 "$F2B_JAIL" "$F2B_LOCAL"
    fi

    # 11.7 validar antes de subir
    if (( ! DRY_RUN )); then
        if ! fail2ban-client -t >/tmp/f2b-test.log 2>&1; then
            warn "  configuracao do fail2ban invalida - removendo o jail criado"
            rm -f "$F2B_JAIL"
            tail -20 /tmp/f2b-test.log >&2
            return 1
        fi
        ok "  configuracao valida"
    fi

    # 11.8 habilitar e iniciar
    run systemctl enable --quiet fail2ban 2>/dev/null || run systemctl enable fail2ban
    run systemctl restart fail2ban

    if (( DRY_RUN )); then return 0; fi

    sleep 2
    if ! systemctl is-active --quiet fail2ban; then
        warn "  fail2ban nao subiu. Ultimas linhas do log:"
        journalctl -u fail2ban -n 20 --no-pager | sed 's/^/       /' >&2
        return 1
    fi
    ok "  servico ativo e habilitado no boot"

    # 11.9 conferir o jail
    if fail2ban-client status sshd >/tmp/f2b-status.log 2>&1; then
        sed 's/^/       /' /tmp/f2b-status.log
        nregex=$(fail2ban-client get sshd failregex 2>/dev/null | grep -cE '^[|`]' || true)
        info "  filtro sshd carregado com ${nregex:-0} expressoes (modo $SSH_MODE)"
    else
        warn "  jail sshd nao esta ativo:"
        sed 's/^/       /' /tmp/f2b-status.log >&2
        return 1
    fi
}

F2B_OK=0
if (( SKIP_F2B )); then
    info "fail2ban ignorado (--skip-fail2ban)"
else
    printf '\n'
    info "Configurando fail2ban..."
    if setup_fail2ban; then
        F2B_OK=1
        (( DRY_RUN )) || ok "fail2ban configurado e protegendo o SSH."
    else
        warn "fail2ban NAO ficou operante. O SSH continua protegido por chave,"
        warn "mas resolva isso: journalctl -u fail2ban -n 50"
    fi
fi

# ---------- 12. instrucoes finais ----------
cat <<EOF

${c_yel}NAO FECHE ESTA SESSAO AINDA.${c_off}

1) Em OUTRO terminal, teste que a chave funciona:
     ssh $(id -un 2>/dev/null || echo usuario)@<ip>

2) Confirme que a senha foi bloqueada (deve dar "Permission denied"):
     ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password usuario@<ip>

EOF

if (( SAFETY_NET > 0 && ! DRY_RUN )); then
    cat <<EOF
3) Deu tudo certo? Cancele o rollback automatico:
     sudo systemctl stop ${TIMER_UNIT}.timer

EOF
fi

if (( F2B_OK )); then
    cat <<EOF
Comandos uteis do fail2ban:
  sudo fail2ban-client status sshd          # quantos IPs banidos
  sudo fail2ban-client set sshd unbanip IP  # tirar um IP do ban
  sudo fail2ban-client unban --all          # limpar tudo (emergencia)
  sudo tail -f /var/log/fail2ban.log        # acompanhar em tempo real

Dica: se o seu cliente oferece varias chaves ao conectar, ele pode estourar
o MaxAuthTries e voce mesmo levar um ban. Evite com:
  ssh -o IdentitiesOnly=yes -i ~/.ssh/sua_chave usuario@<ip>

EOF
fi

(( ONLY_F2B )) && exit 0

cat <<EOF
Backup salvo em: $BACKUP_DIR
Reverter manualmente:
  sudo $0 --rollback $BACKUP_DIR
EOF
