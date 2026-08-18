# Imagem com o toolkit e as dependências que os scripts usam, para rodar a
# triagem num host sem instalar nada nele.
#
#   docker build -t ops-toolkit .
#   docker run --rm ops-toolkit incident-triage
#   docker run --rm ops-toolkit disk-space -j
#
# Para inspecionar o HOST e não o container, monte o que for preciso e use a
# rede/PID do host — sem isso, o relatório descreve o container:
#   docker run --rm --network host --pid host \
#     -v /:/host:ro ops-toolkit incident-triage
FROM debian:12-slim

# Debian slim não traz nada disso; são exatamente as dependências declaradas
# nos cabeçalhos dos scripts.
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
     bash coreutils findutils gzip tar \
     curl openssl jq iproute2 iputils-ping nmap ca-certificates \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/ops-toolkit
COPY bash/ ./bash/
COPY VERSION install.sh ./

# Instala como comandos do sistema, do mesmo jeito que num host
RUN chmod +x bash/*.sh install.sh \
  && ./install.sh -p /usr/local/bin

# Usuário sem privilégio por padrão: os scripts de leitura funcionam assim, e
# quem precisar de root (dmidecode, /etc/shadow) passa --user root explicitamente.
RUN useradd --create-home --shell /bin/bash ops
USER ops
WORKDIR /home/ops

# Sem comando padrão útil: a imagem existe para rodar um dos comandos do toolkit.
CMD ["incident-triage"]
