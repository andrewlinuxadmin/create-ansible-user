#!/usr/bin/env bash
#
# setup-ansible-user.sh — Cria/configura o usuário "ansible" com chave SSH
# Uso: curl -ksSL https://gitlab.example.com/.../setup-ansible-user.sh | bash
#
# ============================================================================
# TABELA DE CÓDIGOS DE ERRO (para referência da equipe SETIC)
# ============================================================================
#
#   CÓDIGO   | DESCRIÇÃO
#   ---------+---------------------------------------------------------------
#   SAU-101  | Comando 'sudo' não encontrado no servidor
#   SAU-102  | Usuário não possui permissão de sudo
#   SAU-201  | Arquivo /etc/os-release não encontrado
#   SAU-202  | Sistema operacional não suportado (conforme DISTRO_MODE)
#   SAU-203  | Versão do RHEL inferior a 7
#   SAU-301  | Falha ao gerar senha aleatória (urandom/python/openssl)
#   SAU-302  | Falha ao gerar hash SHA-512 da senha (openssl/python crypt)
#   SAU-401  | Chave pública SSH não configurada no script
#   SAU-501  | Configuração do sshd ficou inválida (sshd -t falhou)
#   SAU-601  | Arquivo sudoers gerado é inválido (visudo -cf falhou)
#
# ============================================================================
#
set -euo pipefail
IFS=$'\n\t'

# ============================================================================
# CONFIGURAÇÃO
# ============================================================================

ANSIBLE_USER="ansible"
ANSIBLE_HOME="/home/${ANSIBLE_USER}"
SSH_DIR="${ANSIBLE_HOME}/.ssh"
AUTHORIZED_KEYS="${SSH_DIR}/authorized_keys"
SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_DROP_IN_DIR="/etc/ssh/sshd_config.d"
SSHD_DROP_IN="${SSHD_DROP_IN_DIR}/99-ansible-user.conf"
PASSWORD_LENGTH=64

# "rhel_only" = apenas Red Hat Enterprise Linux
# "rhel_like" = RHEL e derivados (CentOS, Rocky, AlmaLinux, Oracle Linux)
DISTRO_MODE="rhel_only"

SSH_PUBLIC_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIApRB8kWM8+6nsKUvAuoW9v4ywfB54OrGH+oHjrm9Tev ansible-user-key"

# ============================================================================
# FUNÇÕES AUXILIARES
# ============================================================================

CONTATO_SETIC="Em caso de dúvida, entre em contato com a SETIC informando o código do erro."

log()  { printf '[INFO]  %s\n' "$*" >&2; }
warn() { printf '[WARN]  %s\n' "$*" >&2; }

# die CÓDIGO "mensagem principal" ["detalhe 1"] ["detalhe 2"] ...
die() {
    local code="$1"; shift
    printf '\n' >&2
    printf '[ERRO %s] %s\n' "$code" "$1" >&2
    shift
    for line in "$@"; do
        printf '           %s\n' "$line" >&2
    done
    printf '\n' >&2
    printf '  >>> %s\n' "${CONTATO_SETIC}" >&2
    printf '  >>> Código do erro: %s\n' "$code" >&2
    printf '  >>> Servidor: %s\n' "$(hostname -f 2>/dev/null || hostname)" >&2
    printf '  >>> Data/Hora: %s\n' "$(date '+%d/%m/%Y %H:%M:%S')" >&2
    printf '\n' >&2
    exit 1
}

SUDO=""
PYTHON=""

detect_python() {
    local candidate
    for candidate in python3 /usr/libexec/platform-python python2 python; do
        if command -v "$candidate" &>/dev/null; then
            PYTHON="$candidate"
            log "Interpretador Python encontrado: ${PYTHON} ($($PYTHON --version 2>&1))"
            return 0
        fi
    done
    PYTHON=""
    warn "Nenhum interpretador Python encontrado. Usando apenas /dev/urandom e openssl."
}

escalate_privileges() {
    local current_user
    current_user=$(whoami)

    if [[ $(id -u) -eq 0 ]]; then
        log "Executando como root."
        SUDO=""
        return 0
    fi

    warn "O usuário '${current_user}' não é root. Este script precisa de privilégios de root para funcionar."
    log "Tentando utilizar o sudo..."

    if ! command -v sudo &>/dev/null; then
        die "SAU-101" "O comando 'sudo' não foi encontrado neste servidor." \
            "" \
            "Para resolver, escolha uma das opções abaixo:" \
            "" \
            "  OPÇÃO A - Executar o script diretamente como root:" \
            "    su - root -c 'bash <(curl -ksSL URL_DO_SCRIPT)'" \
            "" \
            "  OPÇÃO B - Instalar o sudo e dar permissão ao seu usuário:" \
            "    1. Acesse o root:        su - root" \
            "    2. Instale o sudo:        yum install -y sudo" \
            "    3. Adicione ao wheel:     usermod -aG wheel ${current_user}" \
            "    4. Saia do root:          exit" \
            "    5. Faça logout e login novamente para o grupo ter efeito." \
            "    6. Execute o script novamente."
    fi

    log "Verificando se '${current_user}' tem permissão de sudo..."
    if ! sudo -n true 2>/dev/null && ! sudo -v 2>/dev/null; then
        die "SAU-102" "O usuário '${current_user}' não tem permissão de sudo." \
            "" \
            "Para resolver, escolha uma das opções abaixo:" \
            "" \
            "  OPÇÃO A - Executar o script diretamente como root:" \
            "    su - root -c 'bash <(curl -ksSL URL_DO_SCRIPT)'" \
            "" \
            "  OPÇÃO B - Dar permissão de sudo ao usuário '${current_user}':" \
            "    1. Acesse o root:        su - root" \
            "    2. Adicione ao wheel:     usermod -aG wheel ${current_user}" \
            "    3. Saia do root:          exit" \
            "    4. Faça logout e login novamente para o grupo ter efeito." \
            "    5. Execute o script novamente."
    fi

    log "Sudo confirmado para '${current_user}'. Prosseguindo com privilégios elevados."
    SUDO="sudo"
}

check_rhel_version() {
    local version_id

    [[ -f /etc/os-release ]] || die "SAU-201" "Não foi possível identificar o sistema operacional." \
        "O arquivo /etc/os-release não existe neste servidor." \
        "Este script suporta apenas Red Hat Enterprise Linux (RHEL) 7 ou superior."

    source /etc/os-release

    local rhel_like_ids="rhel centos rocky almalinux oracle"

    if [[ "${DISTRO_MODE}" == "rhel_only" ]]; then
        if [[ "${ID:-}" != "rhel" ]]; then
            die "SAU-202" "Sistema operacional não suportado: '${PRETTY_NAME:-${ID:-desconhecido}}'." \
                "Este script está configurado para funcionar APENAS em Red Hat Enterprise Linux (RHEL)." \
                "Distribuição detectada: ${ID:-desconhecida}" \
                "" \
                "Se deseja permitir distribuições derivadas (CentOS, Rocky, AlmaLinux, Oracle Linux)," \
                "altere a variável DISTRO_MODE para 'rhel_like' na seção CONFIGURAÇÃO do script."
        fi
    else
        local id_match=0
        for distro in ${rhel_like_ids}; do
            [[ "${ID:-}" == "$distro" ]] && id_match=1 && break
        done
        if [[ $id_match -eq 0 && "${ID_LIKE:-}" != *"rhel"* ]]; then
            die "SAU-202" "Sistema operacional não suportado: '${PRETTY_NAME:-${ID:-desconhecido}}'." \
                "Este script funciona em RHEL e derivados (CentOS, Rocky, AlmaLinux, Oracle Linux)." \
                "Distribuição detectada: ${ID:-desconhecida}"
        fi
    fi

    version_id="${VERSION_ID%%.*}"
    if (( version_id < 7 )); then
        die "SAU-203" "Versão do sistema não suportada: ${PRETTY_NAME:-RHEL ${VERSION_ID}}." \
            "Este script requer RHEL 7 ou superior (ou equivalente)." \
            "Versão detectada: ${VERSION_ID}"
    fi

    log "Sistema operacional compatível: ${PRETTY_NAME:-${NAME} ${VERSION_ID}} (modo: ${DISTRO_MODE})"
}

generate_password() {
    local pw=""

    pw=$(LC_ALL=C tr -dc 'A-Za-z0-9!@#$%^&*()_+-=[]{}|;:,.<>?' </dev/urandom | head -c "${PASSWORD_LENGTH}" 2>/dev/null) || true

    if [[ ${#pw} -lt ${PASSWORD_LENGTH} ]] && [[ -n "${PYTHON}" ]]; then
        pw=$($PYTHON -c "
import sys, os, string
length = ${PASSWORD_LENGTH}
chars = string.ascii_letters + string.digits + string.punctuation
try:
    from secrets import choice
except ImportError:
    import random
    rng = random.SystemRandom()
    choice = rng.choice
pw = ''.join(choice(chars) for _ in range(length))
if sys.version_info[0] >= 3:
    sys.stdout.write(pw)
else:
    sys.stdout.write(pw.encode('utf-8'))
" 2>/dev/null) || true
    fi

    if [[ ${#pw} -lt ${PASSWORD_LENGTH} ]]; then
        pw=$(openssl rand -base64 96 | tr -dc 'A-Za-z0-9!@#$%^&*()_+-=' | head -c "${PASSWORD_LENGTH}")
    fi

    [[ ${#pw} -ge ${PASSWORD_LENGTH} ]] || die "SAU-301" "Não foi possível gerar uma senha aleatória segura." \
        "Nenhum dos métodos disponíveis funcionou (/dev/urandom, python, openssl)." \
        "Verifique se ao menos o openssl está instalado: 'yum install -y openssl'"
    printf '%s' "$pw"
}

create_user() {
    local password password_hash

    if id "${ANSIBLE_USER}" &>/dev/null; then
        log "Usuário '${ANSIBLE_USER}' já existe. Pulando criação."
        return 0
    fi

    log "Criando usuário '${ANSIBLE_USER}'..."
    password=$(generate_password)
    password_hash=$(printf '%s' "$password" | openssl passwd -6 -stdin 2>/dev/null) || true

    if [[ -z "${password_hash}" ]] && [[ -n "${PYTHON}" ]]; then
        password_hash=$($PYTHON -c "
import sys, os, subprocess
pw = sys.stdin.read().strip()
try:
    import crypt
    h = crypt.crypt(pw, crypt.mksalt(crypt.METHOD_SHA512))
    sys.stdout.write(h)
except (ImportError, AttributeError):
    p = subprocess.Popen(
        ['openssl', 'passwd', '-6', '-stdin'],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE
    )
    out, _ = p.communicate(pw.encode('utf-8'))
    if p.returncode == 0:
        sys.stdout.write(out.decode('utf-8').strip())
    else:
        sys.exit(1)
" <<< "$password" 2>/dev/null) || true
    fi

    if [[ -z "${password_hash}" ]]; then
        die "SAU-302" "Não foi possível gerar o hash da senha do usuário." \
            "Nenhum dos métodos funcionou (openssl passwd, python crypt)." \
            "Verifique se o openssl está instalado e atualizado: 'yum install -y openssl'"
    fi

    ${SUDO} useradd \
        --create-home \
        --home-dir "${ANSIBLE_HOME}" \
        --shell /bin/bash \
        --password "${password_hash}" \
        --comment "Ansible Automation User" \
        "${ANSIBLE_USER}"

    ${SUDO} passwd -l "${ANSIBLE_USER}" >/dev/null 2>&1

    log "Usuário '${ANSIBLE_USER}' criado com senha aleatória de ${PASSWORD_LENGTH} caracteres."
    log "Login por senha DESABILITADO (conta bloqueada). Acesso somente via chave SSH."
}

setup_ssh_directory() {
    log "Configurando diretório SSH..."

    ${SUDO} install -d -m 0700 -o "${ANSIBLE_USER}" -g "${ANSIBLE_USER}" "${SSH_DIR}"

    if ! ${SUDO} test -f "${AUTHORIZED_KEYS}"; then
        ${SUDO} install -m 0600 -o "${ANSIBLE_USER}" -g "${ANSIBLE_USER}" /dev/null "${AUTHORIZED_KEYS}"
    fi
}

install_public_key() {
    log "Instalando chave pública SSH..."

    if [[ -z "${SSH_PUBLIC_KEY}" ]]; then
        die "SAU-401" "A chave pública SSH não foi configurada no script." \
            "Edite o script e preencha a variável SSH_PUBLIC_KEY na seção CONFIGURAÇÃO" \
            "com a chave pública que será usada para acessar o usuário '${ANSIBLE_USER}'."
    fi

    if ${SUDO} grep -qxF "${SSH_PUBLIC_KEY}" "${AUTHORIZED_KEYS}" 2>/dev/null; then
        log "Chave pública já presente em ${AUTHORIZED_KEYS}. Pulando."
    else
        printf '%s\n' "${SSH_PUBLIC_KEY}" | ${SUDO} tee -a "${AUTHORIZED_KEYS}" >/dev/null
        log "Chave pública adicionada a ${AUTHORIZED_KEYS}."
    fi
}

fix_ssh_permissions() {
    log "Ajustando permissões SSH..."

    ${SUDO} chown -R "${ANSIBLE_USER}:${ANSIBLE_USER}" "${SSH_DIR}"
    ${SUDO} chmod 0700 "${SSH_DIR}"
    ${SUDO} chmod 0600 "${AUTHORIZED_KEYS}"

    if command -v restorecon &>/dev/null; then
        ${SUDO} restorecon -Rv "${SSH_DIR}" >/dev/null 2>&1
        log "Contextos SELinux restaurados para ${SSH_DIR}."
    fi
}

configure_sshd() {
    log "Verificando configuração do sshd..."

    local sshd_changed=0

    ensure_sshd_option() {
        local key="$1" value="$2" file="$3"

        if grep -qE "^\s*${key}\s+" "$file" 2>/dev/null; then
            local current
            current=$(grep -E "^\s*${key}\s+" "$file" | tail -1 | awk '{print $2}')
            if [[ "${current,,}" != "${value,,}" ]]; then
                warn "${key} está '${current}' em ${file}. Necessário: '${value}'."
                return 1
            fi
        fi
        return 0
    }

    local required_options=(
        "PubkeyAuthentication yes"
        "AuthorizedKeysFile .ssh/authorized_keys"
    )

    local needs_dropin=0
    for opt in "${required_options[@]}"; do
        local key="${opt%% *}" value="${opt#* }"
        if ! ensure_sshd_option "$key" "$value" "$SSHD_CONFIG"; then
            needs_dropin=1
        fi
    done

    if [[ $needs_dropin -eq 1 ]] || ! ${SUDO} grep -qE '^\s*PubkeyAuthentication\s+yes' "$SSHD_CONFIG" 2>/dev/null; then
        if [[ -d "${SSHD_DROP_IN_DIR}" ]]; then
            if ${SUDO} test -f "${SSHD_DROP_IN}" && ${SUDO} grep -q "^Match User ${ANSIBLE_USER}" "${SSHD_DROP_IN}" 2>/dev/null; then
                log "Drop-in ${SSHD_DROP_IN} já existe com configuração correta. Pulando."
            else
                log "Criando drop-in de configuração em ${SSHD_DROP_IN}..."
                ${SUDO} tee "${SSHD_DROP_IN}" >/dev/null <<'SSHD_CONF'
# Configuração para o usuário ansible — gerado automaticamente
Match User ansible
    PubkeyAuthentication yes
    AuthorizedKeysFile .ssh/authorized_keys
    PasswordAuthentication no
    PermitEmptyPasswords no
    X11Forwarding no
    AllowAgentForwarding no
    PermitTunnel no
SSHD_CONF
                ${SUDO} chmod 0600 "${SSHD_DROP_IN}"
                sshd_changed=1
            fi
        else
            if ! ${SUDO} grep -q "^# BEGIN ansible-user-config" "$SSHD_CONFIG" 2>/dev/null; then
                log "Adicionando bloco Match ao ${SSHD_CONFIG}..."
                ${SUDO} cp -a "${SSHD_CONFIG}" "${SSHD_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
                ${SUDO} tee -a "${SSHD_CONFIG}" >/dev/null <<'SSHD_CONF'

# BEGIN ansible-user-config
Match User ansible
    PubkeyAuthentication yes
    AuthorizedKeysFile .ssh/authorized_keys
    PasswordAuthentication no
    PermitEmptyPasswords no
    X11Forwarding no
    AllowAgentForwarding no
    PermitTunnel no
# END ansible-user-config
SSHD_CONF
                sshd_changed=1
            else
                log "Bloco de configuração ansible já existe em ${SSHD_CONFIG}."
            fi
        fi
    else
        log "PubkeyAuthentication já habilitada."
    fi

    if ! ${SUDO} sshd -t 2>/dev/null; then
        die "SAU-501" "A configuração do SSH ficou inválida após as alterações." \
            "O sshd NÃO foi recarregado (conexões existentes não foram afetadas)." \
            "Verifique manualmente com: sshd -t" \
            "Arquivos modificados: ${SSHD_CONFIG} e/ou ${SSHD_DROP_IN}"
    fi
    log "Configuração do sshd validada com sucesso (sshd -t OK)."

    if [[ $sshd_changed -eq 1 ]]; then
        log "Recarregando sshd..."
        if ${SUDO} systemctl is-active sshd &>/dev/null; then
            ${SUDO} systemctl reload sshd
        elif ${SUDO} systemctl is-active ssh &>/dev/null; then
            ${SUDO} systemctl reload ssh
        else
            ${SUDO} service sshd reload 2>/dev/null || warn "Não foi possível recarregar o sshd. Reinicie manualmente: 'systemctl restart sshd'"
        fi
    fi
}

configure_sudoers() {
    local sudoers_file="/etc/sudoers.d/ansible"

    if ${SUDO} test -f "${sudoers_file}"; then
        log "Arquivo sudoers para '${ANSIBLE_USER}' já existe."
        return 0
    fi

    log "Configurando sudo para '${ANSIBLE_USER}'..."
    ${SUDO} tee "${sudoers_file}" >/dev/null <<EOF
# Ansible automation user — acesso sudo sem senha
${ANSIBLE_USER} ALL=(ALL) NOPASSWD: ALL
Defaults:${ANSIBLE_USER} !requiretty
EOF
    ${SUDO} chmod 0440 "${sudoers_file}"
    ${SUDO} chown root:root "${sudoers_file}"

    if ! ${SUDO} visudo -cf "${sudoers_file}" >/dev/null 2>&1; then
        ${SUDO} rm -f "${sudoers_file}"
        die "SAU-601" "O arquivo sudoers gerado é inválido e foi removido automaticamente por segurança." \
            "Arquivo removido: ${sudoers_file}" \
            "Isso não deveria acontecer. Verifique se o pacote sudo está íntegro: 'yum reinstall -y sudo'"
    fi
    log "Sudoers configurado: ${sudoers_file}"
}

unlock_authorized_keys() {
    if command -v chattr &>/dev/null; then
        ${SUDO} chattr -i "${AUTHORIZED_KEYS}" 2>/dev/null || true
    fi
}

lock_authorized_keys() {
    if command -v chattr &>/dev/null; then
        ${SUDO} chattr +i "${AUTHORIZED_KEYS}" 2>/dev/null && \
            log "Proteção extra: arquivo ${AUTHORIZED_KEYS} marcado como imutável (chattr +i)." || \
            warn "Não foi possível marcar ${AUTHORIZED_KEYS} como imutável. Isso é opcional e pode ocorrer em alguns filesystems (ex: NFS)."
    fi
}

harden_user() {
    log "Aplicando hardening adicional..."
    ${SUDO} chage -M 99999 -m 0 -W 7 -I -1 -E -1 "${ANSIBLE_USER}" 2>/dev/null || true
    lock_authorized_keys
}

# ============================================================================
# EXECUÇÃO PRINCIPAL
# ============================================================================

main() {
    log "=========================================="
    log " Setup do usuário Ansible"
    log "=========================================="

    escalate_privileges
    detect_python
    check_rhel_version
    create_user
    setup_ssh_directory
    unlock_authorized_keys
    install_public_key
    fix_ssh_permissions
    configure_sshd
    configure_sudoers
    harden_user

    log "=========================================="
    log " Configuração concluída com sucesso!"
    log "=========================================="
}

main "$@"
