# Bash Scripts

[English](README.md) · **Português (BR)**

Utilitários Bash pequenos e autocontidos para tarefas de infraestrutura e
segurança.

## Scripts

### `backup-folder.sh`
Cria um backup compactado (`.tar.gz`) de um diretório, verifica se o arquivo
gerado é válido e, opcionalmente, envia um relatório de status por e-mail.

```bash
./backup-folder.sh -s /var/www -d /mnt/backups -e ops@example.com
```

| Flag | Descrição | Padrão |
|------|-----------|--------|
| `-s` | Diretório de origem a ser copiado | variável `SRC_DIR` |
| `-d` | Diretório de destino do arquivo | variável `DST_DIR` |
| `-e` | Destinatário do relatório por e-mail (vazio = desativado) | variável `EMAIL_RECIPIENT` |
| `-h` | Mostra a ajuda | — |

A integridade é verificada com `gzip -t` e `tar -tzf` no arquivo gerado. A
notificação por e-mail exige um `sendmail` funcional e é ignorada caso
contrário.

### `portscan-vuln.sh`
Escaneia um host com `nmap` e imprime uma classificação de risco simples e
ilustrativa para cada porta TCP aberta.

```bash
./portscan-vuln.sh -p 1-1024 example.com
```

| Flag | Descrição | Padrão |
|------|-----------|--------|
| `-p` | Especificação de portas passada ao nmap (ex.: `22,80,443`, `1-1024`, `-`) | `1-65535` |
| `-h` | Mostra a ajuda | — |

O escaneamento roda o `nmap` **uma única vez** (saída no formato grepable) em
vez de uma vez por porta, o que é drasticamente mais rápido que o laço ingênuo.

> ⚠️ **Uso autorizado apenas.** Escaneie somente hosts que você possui ou tem
> permissão explícita por escrito para testar. As "classificações" de
> vulnerabilidade são um recurso didático, não uma avaliação real.

## Requisitos

- Bash 4+
- `tar`, `gzip`, `mktemp` (para o `backup-folder.sh`)
- `nmap` (para o `portscan-vuln.sh`)
- `sendmail` (opcional, para notificações por e-mail)

## Uso

```bash
chmod +x *.sh
./backup-folder.sh -h
```
