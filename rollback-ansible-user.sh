#!/usr/bin/env bash
#
# rollback-ansible-user.sh — Remove o usuário "ansible" e reverte todas as
#                             configurações aplicadas pelo setup-ansible-user.sh
#
# Uso:
#   sudo bash rollback-ansible-user.sh [--force]
#   curl -ksSL URL/rollback-ansible-user.sh | bash -s -- --force
#
#   --force   Executa sem pedir confirmação (obrigatório via curl | bash)
#
# ============================================================================
set -euo pipefail
IFS=$'\n\t'

# ============================================================================
# CONFIGURAÇÃO (deve coincidir com setup-ansible-user.sh)
# ============================================================================

ANSIBLE_USER="ansible"
ANSIBLE_HOME="/home/${ANSIBLE_USER}"
SSH_DIR="${ANSIBLE_HOME}/.ssh"
AUTHORIZED_KEYS="${SSH_DIR}/authorized_keys"
SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_DROP_IN_DIR="/etc/ssh/sshd_config.d"
SSHD_DROP_IN="${SSHD_DROP_IN_DIR}/99-ansible-user.conf"
SUDOERS_FILE="/etc/sudoers.d/ansible"

FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

# ============================================================================
# FUNÇÕES AUXILIARES
# ============================================================================

log()  { printf '[INFO]  %s\n' "$*" >&2; }
warn() { printf '[WARN]  %s\n' "$*" >&2; }
err()  { printf '[ERRO]  %s\n' "$*" >&2; }

SUDO=""

escalate_privileges() {
    if [[ $(id -u) -eq 0 ]]; then
        SUDO=""
        return 0
    fi
    if ! command -v sudo &>/dev/null; then
        err "Este script precisa ser executado como root ou com sudo."
        exit 1
    fi
    if ! sudo -n true 2>/dev/null && ! sudo -v 2>/dev/null; then
        err "Usuário '$(whoami)' não tem permissão de sudo."
        exit 1
    fi
    SUDO="sudo"
}

confirm() {
    if [[ $FORCE -eq 1 ]]; then
        return 0
    fi

    if [[ ! -t 0 ]]; then
        err "Execução via pipe detectada (curl | bash). Use --force para pular a confirmação:"
        err "  curl -ksSL URL/rollback-ansible-user.sh | bash -s -- --force"
        exit 1
    fi

    printf '\n'
    printf '  ╔══════════════════════════════════════════════════════════════╗\n'
    printf '  ║  ATENÇÃO: Este script irá REMOVER completamente:           ║\n'
    printf '  ║                                                            ║\n'
    printf '  ║   • O usuário "%s" e seu diretório home           ║\n' "${ANSIBLE_USER}"
    printf '  ║   • A configuração SSH dedicada (drop-in ou bloco Match)   ║\n'
    printf '  ║   • A regra de sudoers (/etc/sudoers.d/ansible)            ║\n'
    printf '  ║                                                            ║\n'
    printf '  ║  Servidor: %-48s║\n' "$(hostname -f 2>/dev/null || hostname)"
    printf '  ╚══════════════════════════════════════════════════════════════╝\n'
    printf '\n'

    read -rp "  Deseja continuar? (sim/não): " resposta
    case "${resposta,,}" in
        sim|s|yes|y) return 0 ;;
        *) log "Rollback cancelado pelo usuário."; exit 0 ;;
    esac
}

# ============================================================================
# FUNÇÕES DE ROLLBACK
# ============================================================================

rollback_chattr() {
    if command -v chattr &>/dev/null && [[ -f "${AUTHORIZED_KEYS}" ]]; then
        log "Removendo flag imutável de ${AUTHORIZED_KEYS}..."
        ${SUDO} chattr -i "${AUTHORIZED_KEYS}" 2>/dev/null || true
    fi
}

rollback_sudoers() {
    if ${SUDO} test -f "${SUDOERS_FILE}"; then
        log "Removendo arquivo sudoers: ${SUDOERS_FILE}"
        ${SUDO} rm -f "${SUDOERS_FILE}"
    else
        log "Arquivo sudoers não encontrado. Nada a fazer."
    fi
}

rollback_sshd() {
    local sshd_changed=0

    if ${SUDO} test -f "${SSHD_DROP_IN}"; then
        log "Removendo drop-in do sshd: ${SSHD_DROP_IN}"
        ${SUDO} rm -f "${SSHD_DROP_IN}"
        sshd_changed=1
    fi

    if ${SUDO} grep -q "^# BEGIN ansible-user-config" "${SSHD_CONFIG}" 2>/dev/null; then
        log "Removendo bloco Match de ${SSHD_CONFIG}..."
        ${SUDO} cp -a "${SSHD_CONFIG}" "${SSHD_CONFIG}.bak.rollback.$(date +%Y%m%d%H%M%S)"
        ${SUDO} sed -i '/^# BEGIN ansible-user-config$/,/^# END ansible-user-config$/d' "${SSHD_CONFIG}"
        sshd_changed=1
    fi

    if [[ $sshd_changed -eq 1 ]]; then
        if ${SUDO} sshd -t 2>/dev/null; then
            log "Configuração do sshd validada (sshd -t OK). Recarregando..."
            if ${SUDO} systemctl is-active sshd &>/dev/null; then
                ${SUDO} systemctl reload sshd
            elif ${SUDO} systemctl is-active ssh &>/dev/null; then
                ${SUDO} systemctl reload ssh
            else
                ${SUDO} service sshd reload 2>/dev/null || warn "Não foi possível recarregar o sshd. Reinicie manualmente: 'systemctl restart sshd'"
            fi
        else
            warn "Configuração do sshd inválida após remoção. Verifique manualmente com: sshd -t"
        fi
    else
        log "Nenhuma configuração de sshd específica do ansible encontrada."
    fi
}

rollback_user() {
    if ! id "${ANSIBLE_USER}" &>/dev/null; then
        log "Usuário '${ANSIBLE_USER}' não existe. Nada a fazer."
        return 0
    fi

    local processes
    processes=$(ps -u "${ANSIBLE_USER}" -o pid= 2>/dev/null || true)
    if [[ -n "${processes}" ]]; then
        warn "Encerrando processos do usuário '${ANSIBLE_USER}'..."
        ${SUDO} pkill -u "${ANSIBLE_USER}" 2>/dev/null || true
        sleep 2
        ${SUDO} pkill -9 -u "${ANSIBLE_USER}" 2>/dev/null || true
    fi

    log "Removendo usuário '${ANSIBLE_USER}' e diretório home..."
    ${SUDO} userdel -r "${ANSIBLE_USER}" 2>/dev/null || {
        warn "userdel -r falhou. Removendo manualmente..."
        ${SUDO} userdel "${ANSIBLE_USER}" 2>/dev/null || true
        if [[ -d "${ANSIBLE_HOME}" ]]; then
            ${SUDO} rm -rf "${ANSIBLE_HOME}"
        fi
    }
    log "Usuário '${ANSIBLE_USER}' removido."
}

restore_sshd_backup() {
    local latest_backup
    latest_backup=$(ls -t "${SSHD_CONFIG}".bak.* 2>/dev/null | head -1 || true)

    if [[ -n "${latest_backup}" ]]; then
        log "Backup do sshd_config encontrado: ${latest_backup}"
        log "  Para restaurar manualmente: cp '${latest_backup}' '${SSHD_CONFIG}'"
    fi
}

# ============================================================================
# EXECUÇÃO PRINCIPAL
# ============================================================================

main() {
    log "=========================================="
    log " Rollback do usuário Ansible"
    log "=========================================="

    escalate_privileges
    confirm

    rollback_chattr
    rollback_sudoers
    rollback_sshd
    rollback_user
    restore_sshd_backup

    log "=========================================="
    log " Rollback concluído com sucesso!"
    log "=========================================="
}

main "$@"
