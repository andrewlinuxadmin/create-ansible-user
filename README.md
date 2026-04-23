# setup-ansible-user.sh

Script Bash para provisionamento automatizado do usuário `ansible` em servidores
Red Hat Enterprise Linux (RHEL) para preparar o servidor para ser gerenciado via Ansible,
configurando autenticação por chave SSH, sudo e hardening de segurança.

## Como executar

```bash
curl -ksSL https://gitlab.exemplo.com.br/setic/setup-ansible-user.sh | bash
```

## Visão geral

```
┌──────────────────────────────────────────────────────────────────┐
│                    Servidor Ansible (SETIC)                      │
│                                                                  │
│  ssh -i chave_privada ansible@servidor-alvo                      │
└──────────────────┬───────────────────────────────────────────────┘
                   │
                   │  Conexão SSH (chave pública)
                   ▼
┌──────────────────────────────────────────────────────────────────┐
│                    Servidor Alvo (RHEL 7+)                       │
│                                                                  │
│  Usuário: ansible                                                │
│  Auth:    chave SSH (senha bloqueada)                            │
│  Sudo:    NOPASSWD: ALL                                          │
│  sshd:    Match User ansible (PubkeyAuth, sem senha, sem X11)    │
└──────────────────────────────────────────────────────────────────┘
```

## Requisitos

| Requisito | Detalhes |
|---|---|
| Sistema operacional | **Red Hat Enterprise Linux (RHEL) 7, 8, 9 ou 10** |
| Privilégios | `root` ou usuário com `sudo` |
| Pacotes | `openssl` (presente por padrão no RHEL) |
| Rede | Acesso ao GitLab para download do script |

> Por padrão, o script aceita **apenas RHEL**. Para permitir distribuições derivadas
> (CentOS, Rocky, AlmaLinux, Oracle Linux), altere `DISTRO_MODE="rhel_like"` no script.

## Configuração

Antes de publicar o script no GitLab, edite as variáveis na seção `CONFIGURAÇÃO` do script:

```bash
# Chave pública SSH do servidor Ansible (obrigatório)
SSH_PUBLIC_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... ansible@automation"

# Modo de distribuição (opcional)
# "rhel_only" = apenas Red Hat Enterprise Linux (padrão)
# "rhel_like" = RHEL e derivados (CentOS, Rocky, AlmaLinux, Oracle Linux)
DISTRO_MODE="rhel_only"
```

| Variável | Obrigatória | Descrição |
|---|---|---|
| `SSH_PUBLIC_KEY` | Sim | Conteúdo de `~/.ssh/id_ed25519.pub` do servidor Ansible |
| `DISTRO_MODE` | Não | `rhel_only` (padrão) ou `rhel_like` |
| `ANSIBLE_USER` | Não | Nome do usuário (padrão: `ansible`) |
| `PASSWORD_LENGTH` | Não | Tamanho da senha aleatória (padrão: `64`) |
| `ANSIBLE_UID_MIN` | Não | Início da faixa de UID (padrão: `900`) |
| `ANSIBLE_UID_MAX` | Não | Fim da faixa de UID (padrão: `910`) |

## O que o script faz

O script executa as etapas abaixo, nesta ordem:

| # | Etapa | Detalhes |
|---|---|---|
| 1 | **Escalação de privilégios** | Detecta se é `root`. Se não for, verifica se tem `sudo` e o utiliza automaticamente. |
| 2 | **Detecção de Python** | Localiza `python3`, `/usr/libexec/platform-python`, `python2` ou `python` (usado como fallback para geração de senha). |
| 3 | **Verificação do SO** | Confirma que é RHEL 7+ via `/etc/os-release`. |
| 4 | **Criação do usuário** | Cria o usuário `ansible` como conta de sistema com UID na faixa 900-910 (primeiro livre), senha aleatória de 64 caracteres. **Bloqueia login por senha** (`passwd -l`). |
| 5 | **Configuração SSH** | Cria `~ansible/.ssh/` (0700) e `authorized_keys` (0600). Instala a chave pública. Restaura contextos SELinux. |
| 6 | **Configuração sshd** | Adiciona bloco `Match User ansible` via drop-in (RHEL 8+) ou diretamente no `sshd_config` (RHEL 7, com backup). Valida com `sshd -t` e recarrega o serviço. |
| 7 | **Configuração sudo** | Cria `/etc/sudoers.d/ansible` com `NOPASSWD: ALL` e `!requiretty`. Valida com `visudo -cf`. |
| 8 | **Hardening** | Marca `authorized_keys` como imutável (`chattr +i`). |

### Comportamento idempotente

O script pode ser executado múltiplas vezes no mesmo servidor:

- Se o usuário `ansible` já existir, pula a criação (não altera a senha).
- Se a chave pública já estiver no `authorized_keys`, não duplica.
- Se as configurações do `sshd` e `sudoers` já existirem, não recria.

## Geração de senha — compatibilidade

A senha de 64 caracteres é gerada usando três métodos em cascata (fallback automático):

| Prioridade | Método | Disponível em |
|---|---|---|
| 1 | `/dev/urandom` + `tr` | Todos os RHEL |
| 2 | Python (`secrets` ou `random.SystemRandom`) | RHEL 7 (Python 2.7), RHEL 8+ (Python 3.6+) |
| 3 | `openssl rand` | Todos os RHEL |

O hash SHA-512 da senha também usa fallback:

| Prioridade | Método | Disponível em |
|---|---|---|
| 1 | `openssl passwd -6` | RHEL 8+ (OpenSSL 1.1.1+) |
| 2 | Python `crypt.crypt()` | RHEL 7 (Python 2.7) até RHEL 10 (Python 3.12) |
| 3 | Python → subprocess `openssl` | Fallback para Python 3.13+ (módulo `crypt` removido) |

## Configuração do sshd

O bloco `Match User ansible` aplicado pelo script:

```
Match User ansible
    PubkeyAuthentication yes
    AuthorizedKeysFile .ssh/authorized_keys
    PasswordAuthentication no
    PermitEmptyPasswords no
    X11Forwarding no
    AllowAgentForwarding no
    PermitTunnel no
```

| Versão RHEL | Método de configuração |
|---|---|
| RHEL 8, 9, 10 | Drop-in: `/etc/ssh/sshd_config.d/99-ansible-user.conf` |
| RHEL 7 | Append no `/etc/ssh/sshd_config` (com backup `.bak.YYYYMMDDHHMMSS`) |

## Medidas de segurança

- Senha de 64 caracteres com letras maiúsculas, minúsculas, números e símbolos
- Login por senha **bloqueado** (`passwd -l`) — acesso exclusivo via chave SSH
- `PasswordAuthentication no` no bloco `Match` do sshd
- `X11Forwarding no`, `AllowAgentForwarding no`, `PermitTunnel no`
- `authorized_keys` marcado como imutável (`chattr +i`)
- Contextos SELinux restaurados com `restorecon`
- Arquivo sudoers validado com `visudo -cf` (removido automaticamente se inválido)
- Configuração do sshd validada com `sshd -t` antes de recarregar

## Códigos de erro (SAU)

SAU = **S**etup **A**nsible **U**ser

| Código | Área | Descrição |
|---|---|---|
| **SAU-101** | Privilégios | Comando `sudo` não encontrado no servidor |
| **SAU-102** | Privilégios | Usuário não possui permissão de sudo |
| **SAU-201** | Sistema | Arquivo `/etc/os-release` não encontrado |
| **SAU-202** | Sistema | Sistema operacional não suportado (depende de `DISTRO_MODE`) |
| **SAU-203** | Sistema | Versão do RHEL inferior a 7 |
| **SAU-301** | Senha | Falha ao gerar senha aleatória |
| **SAU-302** | Senha | Falha ao gerar hash SHA-512 da senha |
| **SAU-403** | Usuário | Nenhum UID livre na faixa configurada (`ANSIBLE_UID_MIN`-`ANSIBLE_UID_MAX`) |
| **SAU-401** | SSH | Chave pública não configurada no script |
| **SAU-501** | SSHD | Configuração do sshd inválida (`sshd -t` falhou) |
| **SAU-601** | Sudoers | Arquivo sudoers inválido (`visudo -cf` falhou) |

Formato da mensagem de erro exibida ao usuário:

```
[ERRO SAU-XXX] Descrição do problema.
               Detalhes e instruções para resolver...

  >>> Em caso de dúvida, entre em contato com a SETIC informando o código do erro.
  >>> Código do erro: SAU-XXX
  >>> Servidor: nome-do-servidor.exemplo.com.br
  >>> Data/Hora: 22/04/2026 14:35:12
```

Para a descrição detalhada de cada código com causas e soluções, consulte o [FAQ](FAQ.md).

## Como desfazer (rollback)

Use o script `rollback-ansible-user.sh` para reverter **todas** as alterações feitas pelo setup:

```bash
# Execução local (com confirmação interativa)
sudo bash rollback-ansible-user.sh

# Execução via curl | bash (requer --force)
curl -ksSL https://gitlab.exemplo.com.br/setic/rollback-ansible-user.sh | bash -s -- --force
```

### O que o rollback remove

| # | Ação |
|---|------|
| 1 | Remove a flag imutável (`chattr -i`) do `authorized_keys` |
| 2 | Remove o arquivo sudoers (`/etc/sudoers.d/ansible`) |
| 3 | Remove a configuração SSH — drop-in (`99-ansible-user.conf`) ou bloco `Match` no `sshd_config` |
| 4 | Valida a configuração do sshd (`sshd -t`) e recarrega o serviço |
| 5 | Encerra processos do usuário `ansible` (se houver) |
| 6 | Remove o usuário e o diretório home (`/home/ansible`) |

### Opções

| Flag | Descrição |
|------|-----------|
| `--force` | Executa sem pedir confirmação (obrigatório quando executado via `curl \| bash`) |

> **Nota:** Quando executado via pipe (`curl | bash`), o script detecta que stdin não é um
> terminal e exige `--force` para evitar que trave no prompt de confirmação.

### Rollback manual

Caso prefira desfazer manualmente:

```bash
chattr -i /home/ansible/.ssh/authorized_keys
userdel -r ansible
rm -f /etc/sudoers.d/ansible
rm -f /etc/ssh/sshd_config.d/99-ansible-user.conf   # RHEL 8+
# RHEL 7: remova o bloco entre "# BEGIN ansible-user-config" e "# END ansible-user-config"
systemctl reload sshd
```

## Estrutura dos arquivos

```
bash-ansible-user/
├── setup-ansible-user.sh      # Script principal (setup)
├── rollback-ansible-user.sh   # Script de rollback (desfaz tudo)
├── README.md                  # Esta documentação
├── FAQ.md                     # Perguntas frequentes e guia de resolução de erros
└── LICENSE.md                 # Licença GPL v3
```

## Arquivos criados/modificados no servidor alvo

| Arquivo | Ação |
|---|---|
| `/home/ansible/` | Diretório home criado |
| `/home/ansible/.ssh/` | Diretório SSH criado (permissão 0700) |
| `/home/ansible/.ssh/authorized_keys` | Chave pública adicionada (permissão 0600, imutável) |
| `/etc/sudoers.d/ansible` | Regra sudo criada (permissão 0440) |
| `/etc/ssh/sshd_config.d/99-ansible-user.conf` | Drop-in sshd criado (RHEL 8+) |
| `/etc/ssh/sshd_config` | Bloco Match adicionado (RHEL 7 apenas, com backup) |
