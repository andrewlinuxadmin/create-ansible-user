# FAQ — setup-ansible-user.sh

## Perguntas frequentes

### O script altera a senha de um usuário `ansible` que já existe?

**Não.** Se o usuário já existir, o script pula a criação e apenas configura a chave SSH e as
permissões.

### O script precisa de acesso à internet?

Apenas para o download do próprio script via `curl`. Depois de baixado, ele roda 100% offline.

### É seguro executar com `curl | bash`?

O script usa `set -euo pipefail`, o que faz com que ele aborte imediatamente se houver qualquer erro
ou se o download for parcial. Para ambientes com requisitos de segurança mais rigorosos, baixe o
script primeiro, inspecione o conteúdo e depois execute manualmente.

### Posso executar o script mais de uma vez no mesmo servidor?

**Sim.** O script é idempotente — se o usuário, a chave e as configurações já existirem, ele
detecta e pula cada etapa, sem fazer alterações desnecessárias.

### O que acontece se eu precisar adicionar outra chave SSH?

Edite a variável `SSH_PUBLIC_KEY` no script com a nova chave e execute novamente. A nova chave será
adicionada sem remover as existentes.

> **Atenção:** Se o `authorized_keys` estiver protegido com `chattr +i` (imutável), é necessário
> remover a proteção antes: `chattr -i /home/ansible/.ssh/authorized_keys`

### Posso usar esse script em CentOS, Rocky ou AlmaLinux?

Depende da configuração. Por padrão a variável `DISTRO_MODE` está definida como `rhel_only`, e o
script aceita apenas RHEL. Para permitir distribuições derivadas, altere no início do script:

```bash
DISTRO_MODE="rhel_like"
```

Com `rhel_like`, o script aceita: RHEL, CentOS, Rocky Linux, AlmaLinux e Oracle Linux.
Se a distribuição não estiver na lista, ele exibe o erro `SAU-202` e aborta.

### O script modifica o sshd_config diretamente?

Depende da versão do RHEL:

- **RHEL 8+**: Usa um arquivo drop-in em `/etc/ssh/sshd_config.d/99-ansible-user.conf` (método
  preferido, não altera o arquivo principal).
- **RHEL 7**: Adiciona um bloco `Match User ansible` diretamente no `/etc/ssh/sshd_config`, com
  backup automático do arquivo original.

### Como desfazer as alterações feitas pelo script?

```bash
# Remover a proteção imutável do authorized_keys
chattr -i /home/ansible/.ssh/authorized_keys

# Remover o usuário e seu diretório home
userdel -r ansible

# Remover a configuração do sudoers
rm -f /etc/sudoers.d/ansible

# Remover a configuração do sshd (RHEL 8+)
rm -f /etc/ssh/sshd_config.d/99-ansible-user.conf

# Ou, no RHEL 7, remover o bloco do sshd_config manualmente:
#   Apague as linhas entre "# BEGIN ansible-user-config" e "# END ansible-user-config"

# Recarregar o sshd
systemctl reload sshd
```

