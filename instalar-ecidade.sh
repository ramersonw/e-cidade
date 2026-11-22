#!/bin/sh
# =============================================================================
#  instalar-ecidade.sh - Instala ou corrige uma instalação Docker do e-Cidade
#
#  - Instalação nova: clona o projeto, aplica os arquivos Docker corrigidos,
#    sobe os containers (web, bd, pgadmin), restaura a base zerada e configura
#    o modo Desktop.
#  - Instalação existente: faz backup do banco e dos arquivos Docker antigos,
#    aplica os arquivos corrigidos e recria os containers PRESERVANDO o banco
#    de dados (./docker/bd/pgsql).
#
#  Uso: sh instalar-ecidade.sh [opções] [DIRETORIO]
#
#  Opções:
#    -d, --dir DIR           Diretório da instalação (padrão: /projetos/e-cidade)
#    -r, --repo URL          Repositório do e-Cidade
#                            (padrão: https://github.com/ramersonw/e-cidade.git)
#    -b, --branch NOME       Branch (padrão: main)
#        --clone-completo    Clona o histórico completo (padrão: --depth 1)
#        --repo-base URL     Repositório da base de dados zerada
#                            (padrão: https://github.com/e-cidade/base-dados-ecidade.git)
#        --dump ARQUIVO      Usa um dump local (.sql ou .sql.bz2) em vez de clonar a base
#        --sem-banco         Não restaura a base mesmo que o banco esteja vazio
#        --sem-backup        Não faz backup do banco antes de corrigir
#        --atualizar-codigo  Em instalação existente, executa "git pull" no projeto
#        --reinstalar-desktop  Reinstala a extensão Desktop mesmo se já configurada
#    -h, --help              Mostra esta ajuda
#
#  Variáveis de ambiente opcionais: APP_PORT (8282), PGADMIN_PORT (8283),
#  DB_PORTA (5432), PGADMIN_EMAIL, PGADMIN_PASSWORD, XDEBUG_MODE (off) - gravadas no .env.
# =============================================================================
set -eu

DIR=/projetos/e-cidade
REPO=https://github.com/ramersonw/e-cidade.git
BRANCH=main
CLONE_DEPTH="--depth 1"
REPO_BASE=https://github.com/e-cidade/base-dados-ecidade.git
DUMP=""
RESTAURAR_BANCO=1
FAZER_BACKUP=1
ATUALIZAR_CODIGO=0
REINSTALAR_DESKTOP=0

# ----------------------------------------------------------------------------
# Utilitários
# ----------------------------------------------------------------------------
if [ -t 1 ]; then C_OK='\033[1;32m'; C_AV='\033[1;33m'; C_ER='\033[1;31m'; C_IN='\033[1;36m'; C_0='\033[0m'
else C_OK=''; C_AV=''; C_ER=''; C_IN=''; C_0=''; fi
info()  { printf "${C_IN}==>${C_0} %s\n" "$*"; }
ok()    { printf "${C_OK} ok${C_0} %s\n" "$*"; }
aviso() { printf "${C_AV}AVISO:${C_0} %s\n" "$*" >&2; }
erro()  { printf "${C_ER}ERRO:${C_0} %s\n" "$*" >&2; exit 1; }

ajuda() { sed -n '2,/^# =====*$/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0; }

while [ $# -gt 0 ]; do
    case "$1" in
        -d|--dir) DIR="$2"; shift 2 ;;
        -r|--repo) REPO="$2"; shift 2 ;;
        -b|--branch) BRANCH="$2"; shift 2 ;;
        --clone-completo) CLONE_DEPTH=""; shift ;;
        --repo-base) REPO_BASE="$2"; shift 2 ;;
        --dump) DUMP="$2"; shift 2 ;;
        --sem-banco) RESTAURAR_BANCO=0; shift ;;
        --sem-backup) FAZER_BACKUP=0; shift ;;
        --atualizar-codigo) ATUALIZAR_CODIGO=1; shift ;;
        --reinstalar-desktop) REINSTALAR_DESKTOP=1; shift ;;
        -h|--help) ajuda ;;
        -*) erro "Opção desconhecida: $1 (use --help)" ;;
        *) DIR="$1"; shift ;;
    esac
done

# Caminho absoluto
case "$DIR" in /*) ;; *) DIR="$(pwd)/$DIR" ;; esac
DIR="${DIR%/}"
BACKUP_DIR="$(dirname "$DIR")/$(basename "$DIR")-backups"
DATA="$(date +%Y%m%d-%H%M%S)"

# ----------------------------------------------------------------------------
# Pré-requisitos
# ----------------------------------------------------------------------------
info "Verificando pré-requisitos"
command -v docker >/dev/null 2>&1 || erro "docker não encontrado. Instale: https://docs.docker.com/get-docker/"
docker info >/dev/null 2>&1 || erro "Sem acesso ao Docker (execute como root ou com um usuário do grupo docker)"
if docker compose version >/dev/null 2>&1; then
    DC_BIN="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    DC_BIN="docker-compose"
else
    erro "docker compose não encontrado"
fi
command -v git >/dev/null 2>&1 || erro "git não encontrado"
if command -v bunzip2 >/dev/null 2>&1; then BUNZIP="bunzip2 -c"
elif command -v bzip2 >/dev/null 2>&1; then BUNZIP="bzip2 -dc"
else BUNZIP=""; fi
ok "docker / $DC_BIN / git"

dc() { (cd "$DIR" && $DC_BIN "$@"); }

# ----------------------------------------------------------------------------
# Modo: nova instalação ou correção
# ----------------------------------------------------------------------------
if [ -f "$DIR/docker-compose.yml" ] && [ -f "$DIR/composer.json" ]; then
    MODO=correcao
    info "Instalação existente encontrada em $DIR: modo CORREÇÃO (o banco será preservado)"
elif [ -d "$DIR" ] && [ -n "$(ls -A "$DIR" 2>/dev/null)" ]; then
    erro "$DIR existe, não está vazio e não parece ser uma instalação do e-Cidade"
else
    MODO=nova
    info "Nova instalação em $DIR"
fi

# ----------------------------------------------------------------------------
# Código-fonte
# ----------------------------------------------------------------------------
if [ "$MODO" = nova ]; then
    mkdir -p "$(dirname "$DIR")"
    info "Clonando $REPO (branch $BRANCH)"
    # shellcheck disable=SC2086
    git clone $CLONE_DEPTH -b "$BRANCH" "$REPO" "$DIR"
    ok "Código clonado"
elif [ "$ATUALIZAR_CODIGO" = 1 ]; then
    info "Atualizando código (git pull)"
    (cd "$DIR" && git -c safe.directory="$DIR" pull --ff-only) || aviso "git pull falhou; seguindo com o código atual"
fi

# ----------------------------------------------------------------------------
# Backup (somente correção)
# ----------------------------------------------------------------------------
BD_EXISTENTE=0
[ -f "$DIR/docker/bd/pgsql/PG_VERSION" ] && BD_EXISTENTE=1

if [ "$MODO" = correcao ]; then
    mkdir -p "$BACKUP_DIR"
    info "Backup dos arquivos Docker atuais em $BACKUP_DIR/docker-arquivos-$DATA.tar.gz"
    ITENS="docker-compose.yml docker"
    [ -f "$DIR/.env" ] && ITENS="$ITENS .env"
    # shellcheck disable=SC2086
    (cd "$DIR" && tar -czf "$BACKUP_DIR/docker-arquivos-$DATA.tar.gz" --exclude=docker/bd/pgsql $ITENS) \
        || aviso "Não foi possível gerar o backup dos arquivos Docker"

    if [ "$FAZER_BACKUP" = 1 ] && [ "$BD_EXISTENTE" = 1 ]; then
        BD_CID="$(dc ps -q bd 2>/dev/null || true)"
        if [ -n "$BD_CID" ] && [ "$(docker inspect -f '{{.State.Running}}' "$BD_CID" 2>/dev/null)" = true ]; then
            if docker exec "$BD_CID" psql -U postgres -tAc "select 1 from pg_database where datname='ecidade'" 2>/dev/null | grep -q 1; then
                info "Backup do banco ecidade em $BACKUP_DIR/ecidade-$DATA.dump (pode demorar)"
                if docker exec "$BD_CID" pg_dump -U postgres -Fc ecidade > "$BACKUP_DIR/ecidade-$DATA.dump"; then
                    ok "Backup do banco: $(du -h "$BACKUP_DIR/ecidade-$DATA.dump" | cut -f1)"
                else
                    rm -f "$BACKUP_DIR/ecidade-$DATA.dump"
                    erro "Falha no backup do banco. Corrija ou use --sem-backup."
                fi
            fi
        else
            # Banco parado: cópia dos arquivos (consistente, pois o PostgreSQL não está rodando).
            # Feita via container para funcionar mesmo sem root no host (pasta 0700 do uid 999).
            info "Banco parado: backup dos arquivos em $BACKUP_DIR/pgsql-$DATA.tar.gz (pode demorar)"
            IMG_TAR=postgres:12.17-bullseye
            PROJ_IMG="$(basename "$DIR" | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9_-]//g')-bd"
            for I in "$PROJ_IMG" ecidadecontass:bd; do
                docker image inspect "$I" >/dev/null 2>&1 && { IMG_TAR="$I"; break; }
            done
            if docker run --rm --entrypoint tar -v "$DIR/docker/bd/pgsql:/pgsql:ro" -v "$BACKUP_DIR:/backup" \
                "$IMG_TAR" -czf "/backup/pgsql-$DATA.tar.gz" -C / pgsql; then
                ok "Backup dos arquivos do banco: $(du -h "$BACKUP_DIR/pgsql-$DATA.tar.gz" | cut -f1)"
            else
                erro "Falha no backup dos arquivos do banco. Corrija ou use --sem-backup."
            fi
        fi
    fi
fi

# ----------------------------------------------------------------------------
# Arquivos Docker corrigidos
# ----------------------------------------------------------------------------
info "Gravando arquivos Docker corrigidos"
mkdir -p "$DIR/docker/bd" "$DIR/docker/scripts" "$DIR/docker/apache2" \
         "$DIR/docker/supervisord/conf.d" "$DIR/docker/pgadmin"

cat > "$DIR/docker-compose.yml" <<'ECIDADE_ARQUIVO_EOF'

networks:
  ecidade:
    driver: bridge

volumes:
  pgadmin-data:

services:
    web:
        build:
            context: ./docker
            dockerfile: Dockerfile
        restart: always
        extra_hosts:
            - 'host.docker.internal:host-gateway'
        environment:
          DB_SERVIDOR: bd
          DB_PORTA: '5432'
          # UID/GID com que o Apache/PHP gravam arquivos. Vazio = dono da pasta do projeto no host.
          WWW_UID: '${WWW_UID:-}'
          WWW_GID: '${WWW_GID:-}'
          # true: ajusta dono/permissões das pastas a cada inicialização
          FIX_PERMISSIONS: '${FIX_PERMISSIONS:-true}'
          # auto | always | never
          COMPOSER_INSTALL: '${COMPOSER_INSTALL:-auto}'
          # Xdebug: off (padrão) | debug | develop,debug | develop,coverage,debug
          XDEBUG_MODE: '${XDEBUG_MODE:-off}'
        volumes:
            - './:/var/www/html'
        tmpfs:
            # Oculta, dentro do container web, os dados do PostgreSQL que ficam em
            # ./docker/bd/pgsql (dentro da raiz do site). Evita que sejam expostos
            # ou tenham o dono alterado pelo container web.
            - /var/www/html/docker/bd/pgsql:size=1m,mode=0700
        networks:
          - ecidade
        ports:
          - '${APP_PORT:-8282}:80'
        depends_on:
          bd:
            condition: service_healthy

    bd:
      # Sem "image:" fixa: cada instância (pasta) tem a própria imagem
      # (<pasta>-bd / <pasta>-web), evitando que o build de uma afete as outras.
      restart: always
      ports:
        - "${DB_PORTA:-5432}:5432"
      build:
        context: ./docker/bd
      environment:
        POSTGRES_USER: postgres
        POSTGRES_PASSWORD: postgres
        # POSTGRES_DB: ${DB_BASE}
        POSTGRES_INITDB_ARGS: '--encoding=LATIN1 --lc-collate=pt_BR.ISO-8859-1 --lc-ctype=pt_BR.ISO-8859-1 --lc-messages=pt_BR.ISO-8859-1 --lc-monetary=pt_BR.ISO-8859-1 --lc-numeric=pt_BR.ISO-8859-1 --lc-time=pt_BR.ISO-8859-1'
      # Parâmetros exigidos pelo e-Cidade (INSTALL.md, item 1.3)
      command:
        - postgres
        - -c
        - max_connections=${DB_MAX_CONNECTIONS:-100}
        - -c
        - bytea_output=escape
        - -c
        - max_locks_per_transaction=256
        - -c
        - escape_string_warning=off
        - -c
        - standard_conforming_strings=off
      volumes:
        - ./docker/scripts/iniciarbd.sql:/docker-entrypoint-initdb.d/iniciarbd.sql:ro
        - './docker/bd/pgsql:/var/lib/postgresql/data'
      networks:
        - ecidade
      healthcheck:
        test: [ "CMD-SHELL", "pg_isready -U postgres -d postgres" ]
        interval: 10s
        timeout: 5s
        retries: 30
        start_period: 30s

    pgadmin:
      image: dpage/pgadmin4:8.14
      restart: always
      environment:
        PGADMIN_DEFAULT_EMAIL: '${PGADMIN_EMAIL:-admin@ecidade.com.br}'
        PGADMIN_DEFAULT_PASSWORD: '${PGADMIN_PASSWORD:-admin}'
        PGADMIN_CONFIG_SERVER_MODE: 'True'
        PGADMIN_CONFIG_MASTER_PASSWORD_REQUIRED: 'False'
        PGADMIN_LISTEN_PORT: '80'
      volumes:
        - pgadmin-data:/var/lib/pgadmin
        # Servidor "e-Cidade" pré-cadastrado (importado no primeiro acesso)
        - ./docker/pgadmin/servers.json:/pgadmin4/servers.json:ro
      networks:
        - ecidade
      ports:
        - '${PGADMIN_PORT:-8283}:80'
      depends_on:
        bd:
          condition: service_healthy
ECIDADE_ARQUIVO_EOF

cat > "$DIR/docker/Dockerfile" <<'ECIDADE_ARQUIVO_EOF'
FROM ubuntu:22.04

LABEL maintainer="igor@contassconsultoria.com.br.com.br"
ENV GIT_SSH_COMMAND "ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"

# Habilita modo n�o interativo na instalação de pacotes
ENV DEBIAN_FRONTEND noninteractive

# Desabilita o cache do gerenciador de pacote
RUN echo "Acquire::http {No-Cache=True;};" > /etc/apt/apt.conf.d/no-cache

# Atualiza a lista de repositórios
RUN apt-get update

# Instala as dependências deste container
RUN apt-get install -y --no-install-recommends tzdata \
  locales \
  ca-certificates \
  sudo \
  software-properties-common \
  curl \
  unzip \
  zip \
  pigz \
  vim \
  sqlite3 \
  wget \
  language-pack-gnome-pt \
  language-pack-pt-base \
  myspell-pt \
  myspell-pt-br \
  wbrazilian \
  wportuguese \
  ghostscript \
  git \
  gnupg \
  gpg-agent \
  ssh \
  file \
  supervisor

# Instala o repositório do PostgreSQL
RUN wget -O- https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor | tee /usr/share/keyrings/postgresql.gpg && \
  echo "deb [arch=amd64,arm64,ppc64el signed-by=/usr/share/keyrings/postgresql.gpg] http://apt.postgresql.org/pub/repos/apt/ jammy-pgdg main" | tee /etc/apt/sources.list.d/postgresql.list

# Instala o repositório PPA do PHP
RUN apt-add-repository -y ppa:ondrej/php

# Configura a timezone do container para America/Sao_Paulo
ENV TZ America/Sao_Paulo
RUN echo $TZ > /etc/timezone && \
  cp /usr/share/zoneinfo/${TZ} /etc/localtime && \
  dpkg-reconfigure -f noninteractive tzdata

# Ajusta a codificação de ordenação para o LATIN1
RUN sed -i "s|copy \"iso14651_t1\"|copy \"iso14651_t1\"\nreorder-after <U00A0>\n<U0020><CAP>;<CAP>;<CAP>;<U0020>\nreorder-end|" /usr/share/i18n/locales/pt_BR

# Regera o locales
RUN localedef -i pt_BR -c -f ISO-8859-1 -A /usr/share/locale/locale.alias pt_BR && \
  locale-gen pt_BR && \
  echo "locales locales/default_environment_locale select pt_BR.UTF-8" | debconf-set-selections && \
  dpkg-reconfigure --frontend noninteractive locales

# Atualiza a lista de repositórios
RUN apt-get update

# Aceita os termos EULA para o pacote MS Core Fonts e instala o pacote
RUN echo ttf-mscorefonts-installer msttcorefonts/accepted-mscorefonts-eula select true | debconf-set-selections && \
  apt-get install -y --no-install-recommends ttf-mscorefonts-installer

# Instala o cliente PSQL
RUN apt-get install -y --no-install-recommends postgresql-client-12

# Instala o Libreoffice Writer
RUN apt-get install -y --no-install-recommends libreoffice-writer

# Instala o pacote do servidor web Apache2
RUN apt-get install -y --no-install-recommends \
  apache2

# Instala os pacotes do PHP como módulo FPM
RUN apt-get install -y --no-install-recommends \
  php7.4 \
  php7.4-bcmath \
  php7.4-bz2 \
  php7.4-cli \
  php7.4-common \
  php7.4-curl \
  php7.4-imagick \
  php7.4-gd \
  php7.4-interbase \
  php7.4-json \
  php7.4-mbstring \
  php7.4-pgsql \
  php7.4-soap \
  php7.4-sqlite3 \
  php7.4-xml \
  php7.4-xmlrpc \
  php7.4-zip \
  php7.4-intl \
  php7.4-opcache \
  php7.4-readline \
  php7.4-fpm \
  php7.4-xdebug \
  php7.4-apcu

# Habilita o xdebug no PHP
RUN echo "xdebug.mode=develop,coverage,debug" >> /etc/php/7.4/mods-available/xdebug.ini && \
    echo "xdebug.remote_autostart=on" >> /etc/php/7.4/mods-available/xdebug.ini && \
    echo "xdebug.client_port=9003" >> /etc/php/7.4/mods-available/xdebug.ini && \
    echo "xdebug.log_level=0" >> /etc/php/7.4/mods-available/xdebug.ini && \
    echo "xdebug.idekey=PHPSTORM" >> /etc/php/7.4/mods-available/xdebug.ini && \
    echo "xdebug.client_host=host.docker.internal" >> /etc/php/7.4/mods-available/xdebug.ini && \
    echo "xdebug.log=/dev/stdout" >> /etc/php/7.4/mods-available/xdebug.ini
#    echo "xdebug.remote_handler=dbgp" >> /etc/php/7.4/mods-available/xdebug.ini

# Ajusta a permissão do imagick
RUN sed -i "s|<policy domain=\"coder\" rights=\"none\" pattern=\"PDF\" />|<policy domain=\"coder\" rights=\"read\|write\" pattern=\"PDF\" />|" /etc/ImageMagick-6/policy.xml

# Ajusta as configurações PHP como módulo FPM
RUN sed -i "s|^pm\ =.*|pm = ondemand|" /etc/php/7.4/fpm/pool.d/www.conf && \
  sed -i "s|^pm.max_children.*|pm.max_children = 300|" /etc/php/7.4/fpm/pool.d/www.conf && \
  sed -i "s|^pm.process_idle_timeout.*|pm.process_idle_timeout = 60s|" /etc/php/7.4/fpm/pool.d/www.conf && \
  sed -i "s|^pm.max_requests.*|pm.max_requests = 500|" /etc/php/7.4/fpm/pool.d/www.conf

# Ajusta as configurações do Apache2
RUN sed -i "s|^MaxRequestWorkers.*|MaxRequestWorkers         350|" /etc/apache2/mods-available/mpm_event.conf && \
  echo "umask 002" >> /etc/apache2/envvars && \
  a2enmod rewrite ssl proxy_fcgi setenvif && \
  a2enconf php7.4-fpm && \
  a2disconf serve-cgi-bin && \
  a2dissite 000-default.conf

# Instala o composer
RUN curl -sS https://getcomposer.org/installer -o composer-setup.php && \
  php composer-setup.php --install-dir=/usr/local/bin --filename=composer && \
  rm composer-setup.php

# Instala o node.js para suporte a módulos compilados com o NPM
#RUN curl -sS https://deb.nodesource.com/gpgkey/nodesource-repo.gpg
RUN curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
ENV NODE_MAJOR 20
RUN echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_$NODE_MAJOR.x nodistro main" | tee /etc/apt/sources.list.d/nodesource.list
RUN apt-get install -y gcc g++ make nodejs

# Exporta variável que permite a execução do composer como root sem emitir avisos
#ENV PATH=$PATH:/root/composer/vendor/bin COMPOSER_ALLOW_SUPERUSER=1

ENV COMPOSER_ALLOW_SUPERUSER=1

# Adiciona vhosts
ADD apache2/ecidade.conf /etc/apache2/sites-available/

# Configura o php.ini com os parâmetros necessários para o e-cidade.
# O log de erros do PHP vai para um arquivo real em /var/log/php (gravável pelo
# www-data). Antes ele era um link para /dev/stderr, que os workers do PHP-FPM
# (usuário www-data) não têm permissão de abrir: o PHP não conseguia gravar logs.
RUN mkdir -p /var/log/php && \
  chown www-data:www-data /var/log/php && \
  chmod 1777 /var/log/php && \
  for SAPI in fpm cli; do \
    sed -i 's|^short_open_tag = .*|short_open_tag = On|g' /etc/php/7.4/$SAPI/php.ini && \
    sed -i 's|^session.gc_maxlifetime = .*|session.gc_maxlifetime = 7200|g' /etc/php/7.4/$SAPI/php.ini && \
    sed -i 's|^;date.timezone =.*|date.timezone = "America/Sao_Paulo"|g' /etc/php/7.4/$SAPI/php.ini && \
    sed -i 's|^;error_log.*|error_log = /var/log/php/php_errors.log|g' /etc/php/7.4/$SAPI/php.ini || exit 1; \
  done

# Ajusta o pool do PHP-FPM:
#  - HOME gravável para o www-data (LibreOffice/ImageMagick gravam perfil/cache no HOME)
#  - captura a saída dos workers e envia o log do master para o "docker logs"
RUN sed -i 's|^;\?catch_workers_output = .*|catch_workers_output = yes|' /etc/php/7.4/fpm/pool.d/www.conf && \
  sed -i 's|^;\?decorate_workers_output = .*|decorate_workers_output = no|' /etc/php/7.4/fpm/pool.d/www.conf && \
  echo 'env[HOME] = /home/www-data' >> /etc/php/7.4/fpm/pool.d/www.conf && \
  echo 'env[TMPDIR] = /tmp' >> /etc/php/7.4/fpm/pool.d/www.conf && \
  sed -i 's|^;\?error_log = .*|error_log = /proc/self/fd/2|' /etc/php/7.4/fpm/php-fpm.conf

# O www-data tinha como HOME /var/www (pertence ao root): cria um HOME próprio.
RUN mkdir -p /home/www-data && \
  usermod -d /home/www-data www-data && \
  chown www-data:www-data /home/www-data

# Git dentro do container: o código é um bind mount com dono do host
RUN git config --system --add safe.directory '*'

# Configura o Supervisor
RUN mkdir -p /run/php/
COPY supervisord/supervisord.conf /etc/supervisor/supervisord.conf
COPY supervisord/conf.d/ /etc/supervisor/conf.d/

# Usuário mantido por compatibilidade com o procedimento antigo
# ("docker exec ... sudo ..."). O container agora roda como root: o supervisord
# inicia o Apache e o PHP-FPM, que trocam para o usuário www-data.
RUN id contass >/dev/null 2>&1 || adduser --uid 1000 --disabled-password --gecos "" contass && \
  usermod -g www-data contass && \
  echo 'contass ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/contass && \
  chmod 0440 /etc/sudoers.d/contass

# Limpa os temporários
RUN apt-get clean && \
  rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* /var/cache/*

# Adiciona o script de inicialiação
COPY ./scripts/iniciar.sh /iniciar.sh
RUN chmod 755 /iniciar.sh

EXPOSE 80

WORKDIR /var/www/html

HEALTHCHECK --interval=15s --timeout=5s --start-period=30s --retries=40 \
  CMD test -f /run/ecidade-pronto && curl -s -o /dev/null http://127.0.0.1/ || exit 1

CMD ["/bin/bash", "/iniciar.sh"]
ECIDADE_ARQUIVO_EOF

cat > "$DIR/docker/bd/Dockerfile" <<'ECIDADE_ARQUIVO_EOF'
FROM postgres:12.17-bullseye

ENV DEBIAN_FRONTEND=noninteractive

RUN echo "Acquire::http {No-Cache=True;};" > /etc/apt/apt.conf.d/no-cache

# O repositorio "bullseye-pgdg" foi descontinuado em apt.postgresql.org e faz o
# "apt-get update" falhar. Nao precisamos dele (o PostgreSQL ja vem na imagem).
# "--no-upgrade" evita atualizar pacotes ja presentes na imagem (locales, tzdata):
# o Debian 11 saiu do LTS e alguns .deb de atualizacao nao existem mais nos espelhos.
# Manter a glibc da imagem tambem preserva a ordenacao (collation) de bancos existentes.
RUN rm -f /etc/apt/sources.list.d/pgdg.list && \
  apt-get update && \
  apt-get install -y --no-install-recommends --no-upgrade \
    tzdata \
    locales \
    myspell-pt \
    myspell-pt-br \
    wbrazilian \
    wportuguese && \
  apt-get clean && rm -rf /var/lib/apt/lists/*

ENV TZ=America/Sao_Paulo
RUN echo $TZ > /etc/timezone && \
  cp /usr/share/zoneinfo/${TZ} /etc/localtime && \
  dpkg-reconfigure -f noninteractive tzdata

RUN sed -i "s|copy \"iso14651_t1\"|copy \"iso14651_t1\"\nreorder-after <U00A0>\n<U0020><CAP>;<CAP>;<CAP>;<U0020>\nreorder-end|" /usr/share/i18n/locales/pt_BR && \
  sed -i "s|^#\ pt_BR ISO-8859-1|pt_BR ISO-8859-1|g" /etc/locale.gen && \
  sed -i "s|^#\ pt_BR.UTF-8 UTF-8|pt_BR.UTF-8 UTF-8|g" /etc/locale.gen

RUN localedef -i pt_BR -c -f ISO-8859-1 -A /usr/share/locale/locale.alias pt_BR && \
  locale-gen pt_BR

ENV LANG=pt_BR.UTF-8
ENV LANGUAGE=pt_BR:pt
ENV LC_ALL=pt_BR.UTF-8
ECIDADE_ARQUIVO_EOF

cat > "$DIR/docker/scripts/iniciar.sh" <<'ECIDADE_ARQUIVO_EOF'
#!/bin/bash
# =============================================================================
# Inicialização do container web do e-Cidade
#
# O código-fonte é um bind mount do host (./ -> /var/www/html). O Apache e o
# PHP-FPM rodam como "www-data", que precisa GRAVAR em várias pastas do sistema
# (tmp, storage, cache, extension, imagens/files, legacy_config, ...).
#
# Para isso o www-data passa a usar o mesmo UID/GID do dono do código no host:
#   - código com dono comum (ex.: uid 1000): www-data vira uid 1000. Os arquivos
#     continuam editáveis pelo usuário do host e graváveis pelo PHP.
#   - código com dono root (uid 0): o www-data mantém o uid 33 e os arquivos
#     passam a pertencer a ele (equivalente ao "chown -R www-data" do INSTALL.md,
#     mas sem atingir os dados do PostgreSQL nem o .git).
#
# Variáveis (opcionais, definidas no docker-compose.yml / .env):
#   WWW_UID, WWW_GID     força o UID/GID do www-data
#   FIX_PERMISSIONS      true (padrão) | false: ajusta dono/permissões no boot
#   COMPOSER_INSTALL     auto (padrão: só se o vendor estiver ausente/desatualizado)
#                        | always | never
#   XDEBUG_MODE          off (padrão: extensão desativada) | modos do Xdebug 3,
#                        ex.: debug | develop,debug | develop,coverage,debug
# =============================================================================

APP_DIR=/var/www/html
cd "$APP_DIR" || exit 1

log() { echo "[iniciar.sh] $*"; }

rm -f /run/ecidade-pronto

# ---------------------------------------------------------------------------
# 1. UID/GID do www-data
# ---------------------------------------------------------------------------
HOST_UID=$(stat -c %u "$APP_DIR")
HOST_GID=$(stat -c %g "$APP_DIR")
WWW_UID=${WWW_UID:-$HOST_UID}
WWW_GID=${WWW_GID:-$HOST_GID}
if [ "$WWW_UID" = "0" ]; then WWW_UID=33; fi
if [ "$WWW_GID" = "0" ]; then WWW_GID=33; fi

if [ "$(id -u www-data)" != "$WWW_UID" ] || [ "$(id -g www-data)" != "$WWW_GID" ]; then
    log "Ajustando www-data para UID=$WWW_UID GID=$WWW_GID"
    groupmod -o -g "$WWW_GID" www-data
    usermod -o -u "$WWW_UID" -g "$WWW_GID" www-data
fi
WWW_UID=$(id -u www-data)
WWW_GID=$(id -g www-data)

# Pastas do próprio container usadas pelo www-data
mkdir -p /home/www-data /var/log/php /run/php /var/lib/php/sessions
chown -R www-data:www-data /home/www-data
chmod 1777 /var/log/php
touch /var/log/php/php_errors.log
chown www-data:www-data /var/log/php/php_errors.log
chmod 0666 /var/log/php/php_errors.log

# ---------------------------------------------------------------------------
# 2. Estrutura de pastas graváveis da aplicação
# ---------------------------------------------------------------------------
PASTAS_GRAVAVEIS=(
    tmp
    storage
    storage/app/public
    storage/framework/cache/data
    storage/framework/sessions
    storage/framework/testing
    storage/framework/views
    storage/logs
    bootstrap/cache
    cache
    cache/menus
    cache/forms
    cache/preferencias
    extension/log
    extension/data
    extension/data/extension
    extension/modification/data
    extension/modification/log
    imagens/files
    legacy_config
    updatedb/log
    anexos
    model/licitacao/PNCP/anexoslicitacao
    model/licitacao/PNCP/arquivos
    jobs/configuracoes/taskManager/fila
)

# imagens/files é criado a partir do modelo imagens/files.proper (INSTALL.md)
if [ ! -d imagens/files ] && [ -d imagens/files.proper ]; then
    log "Criando imagens/files a partir de imagens/files.proper"
    cp -a imagens/files.proper imagens/files
fi
# Preferências do sistema (INSTALL.md, passo 6)
if [ ! -f legacy_config/preferencias.json ] && [ -f config/preferencias.json.dist ]; then
    mkdir -p legacy_config
    cp config/preferencias.json.dist legacy_config/preferencias.json
fi

for P in "${PASTAS_GRAVAVEIS[@]}"; do
    mkdir -p "$P"
done

# ---------------------------------------------------------------------------
# 3. Dono e permissões
#    Exclui: dados do PostgreSQL (docker/bd/pgsql) e .git (o git do host recusa
#    repositórios com outro dono: "detected dubious ownership").
# ---------------------------------------------------------------------------
if [ "${FIX_PERMISSIONS:-true}" = "true" ]; then
    log "Ajustando dono dos arquivos para www-data ($WWW_UID:$WWW_GID)..."
    find "$APP_DIR" \
        \( -path "$APP_DIR/.git" -o -path "$APP_DIR/docker/bd/pgsql" -o -path "$APP_DIR/node_modules" \) -prune -o \
        \( ! -uid "$WWW_UID" -o ! -gid "$WWW_GID" \) -print0 2>/dev/null \
        | xargs -0 -r chown -h "$WWW_UID:$WWW_GID"
    # Raiz do projeto: o dono precisa permanecer, pois é dele que lemos o UID
    chown "$WWW_UID:$WWW_GID" "$APP_DIR" 2>/dev/null

    # Pastas graváveis: leitura/escrita para dono e grupo, setgid nas pastas
    for P in "${PASTAS_GRAVAVEIS[@]}"; do
        chmod -R ug+rwX "$P"
        find "$P" -type d -exec chmod g+s {} + 2>/dev/null
    done
    chmod ug+rw .env 2>/dev/null
fi

# git dentro do container (bind mount com outro dono)
git config --system --get-all safe.directory 2>/dev/null | grep -qx '\*' \
    || git config --system --add safe.directory '*'

# ---------------------------------------------------------------------------
# 4. Dependências PHP (composer) - executado como www-data
# ---------------------------------------------------------------------------
como_www() {
    runuser -u www-data -- env HOME=/home/www-data COMPOSER_HOME=/home/www-data/.composer "$@"
}

if [ -f composer.json ]; then
    case "${COMPOSER_INSTALL:-auto}" in
        always) RODAR_COMPOSER=1 ;;
        never)  RODAR_COMPOSER=0 ;;
        *)
            RODAR_COMPOSER=0
            if [ ! -f vendor/autoload.php ]; then
                RODAR_COMPOSER=1
            elif [ -f composer.lock ] && [ composer.lock -nt vendor/composer/installed.json ]; then
                RODAR_COMPOSER=1
            fi
            ;;
    esac
    if [ "$RODAR_COMPOSER" = "1" ]; then
        log "Executando composer install..."
        como_www composer install --no-interaction --prefer-dist \
            || log "AVISO: composer install falhou (veja as mensagens acima)"
    fi
fi

# ---------------------------------------------------------------------------
# 5. Xdebug: desativado por padrão (deixa o PHP mais lento e gera stack
#    traces enormes no log). Ative com XDEBUG_MODE no .env e reinicie o web.
# ---------------------------------------------------------------------------
XDEBUG_INI=/etc/php/7.4/mods-available/xdebug.ini
XDEBUG_MODE="${XDEBUG_MODE:-off}"
if [ -f "$XDEBUG_INI" ]; then
    if [ "$XDEBUG_MODE" = "off" ] || [ -z "$XDEBUG_MODE" ]; then
        phpdismod -v 7.4 xdebug
        log "Xdebug desativado (para ativar: XDEBUG_MODE=debug no .env)"
    else
        sed -i "s|^xdebug.mode=.*|xdebug.mode=${XDEBUG_MODE}|" "$XDEBUG_INI"
        # /dev/stdout não é acessível aos workers do PHP-FPM (www-data)
        sed -i "s|^xdebug.log=.*|xdebug.log=/var/log/php/xdebug.log|" "$XDEBUG_INI"
        touch /var/log/php/xdebug.log && chmod 0666 /var/log/php/xdebug.log
        phpenmod -v 7.4 xdebug
        log "Xdebug ativado (xdebug.mode=${XDEBUG_MODE})"
    fi
fi

# ---------------------------------------------------------------------------
# 6. Apache
# ---------------------------------------------------------------------------
a2ensite -q ecidade.conf >/dev/null

touch /run/ecidade-pronto
log "Inicialização concluída. Iniciando supervisord (apache + php-fpm)."

# Inicializa o supervisord
exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf
ECIDADE_ARQUIVO_EOF

cat > "$DIR/docker/scripts/iniciarbd.sql" <<'ECIDADE_ARQUIVO_EOF'
-- iniciarbd.sql
CREATE ROLE ecidade WITH SUPERUSER LOGIN PASSWORD 'ecidade';
CREATE ROLE plugin WITH LOGIN PASSWORD 'plugin';
CREATE ROLE dbseller WITH LOGIN PASSWORD 'dbseller';
CREATE ROLE dbportal WITH LOGIN PASSWORD 'dbportal';
CREATE ROLE contass WITH LOGIN PASSWORD 'contass';
CREATE ROLE usersrole WITH LOGIN PASSWORD 'usersrole';
CREATE DATABASE ecidade OWNER ecidade;
ALTER ROLE ecidade set search_path = public, sicom, recursoshumanos, site, empenho, diversos, issqn, secretariadeeducacao, tfd, arrecadacao, agua, ouvidoria, acordos, laboratorio, cadastro, habitacao, vacinas, inflatores, escola, juridico, notificacoes, orcamento, licitacao, projetos, divida, protocolo, itbi, material, merenda, pessoal, prefeitura, agendamento, veiculos, tributario, recursoshumanos, dbpref, farmacia, marcas, cemiterio, transporteescolar, ambulatorial, patrimonio, gestorbi, caixa, fiscal, biblioteca, configuracoes, contabilidade, esocial, compras, contrib, social, custos;
ECIDADE_ARQUIVO_EOF

cat > "$DIR/docker/apache2/ecidade.conf" <<'ECIDADE_ARQUIVO_EOF'
<VirtualHost *:80>
		SetEnvIf X-Forwarded-Proto https HTTPS=ON

        ServerAdmin webmaster@localhost

        LimitRequestLine 16382
        LimitRequestFieldSize 16382
        Timeout 12000
        AddDefaultCharset ISO-8859-1
        SetEnv no-gzip 1

        DocumentRoot /var/www/html
        <Directory />
                Options FollowSymLinks
                AllowOverride None
        </Directory>
        <Directory /var/www/html>
                Options FollowSymLinks MultiViews
                AllowOverride All
                Order allow,deny
                allow from all
        </Directory>

        # Rota fixa para o endpoint BCI
        Alias /bci /var/www/html/bci.php

        ScriptAlias /cgi-bin/ /usr/lib/cgi-bin/
        <Directory "/usr/lib/cgi-bin">
                AllowOverride None
                Options +ExecCGI -MultiViews +SymLinksIfOwnerMatch
                Order allow,deny
                Allow from all
        </Directory>

        ErrorLog ${APACHE_LOG_DIR}/error.log

        # Possible values include: debug, info, notice, warn, error, crit,
        # alert, emerg.
        LogLevel warn

        CustomLog ${APACHE_LOG_DIR}/access.log combined

    Alias /doc/ "/usr/share/doc/"
    <Directory "/usr/share/doc/">
        Options Indexes MultiViews FollowSymLinks
				AllowOverride None
        Order deny,allow
        Deny from all
        Allow from 127.0.0.0/255.0.0.0 ::1/128
    </Directory>

    # Nunca expor via web os arquivos de infraestrutura (dados do PostgreSQL ficam
    # em docker/bd/pgsql, dentro da raiz do site), o repositório git e o .env
    <DirectoryMatch "^/var/www/html/(docker|\.git)(/|$)">
        Require all denied
    </DirectoryMatch>
    <FilesMatch "^\.env">
        Require all denied
    </FilesMatch>



</VirtualHost>

ECIDADE_ARQUIVO_EOF

cat > "$DIR/docker/supervisord/supervisord.conf" <<'ECIDADE_ARQUIVO_EOF'
[unix_http_server]
file=/dev/shm/supervisor.sock   ; (the path to the socket file)
chmod=0700

[supervisord]
user=root                    ; o supervisord roda como root; apache e php-fpm trocam para www-data
logfile=/tmp/supervisord.log ; (main log file;default $CWD/supervisord.log)
logfile_maxbytes=50MB        ; (max main logfile bytes b4 rotation;default 50MB)
logfile_backups=10           ; (num of main logfile rotation backups;default 10)
loglevel=info                ; (log level;default info; others: debug,warn,trace)
pidfile=/tmp/supervisord.pid ; (supervisord pidfile;default supervisord.pid)
nodaemon=true                ; (start in foreground if true;default false)
minfds=1024                  ; (min. avail startup file descriptors;default 1024)
minprocs=200                 ; (min. avail process descriptors;default 200)

; the below section must remain in the config file for RPC
; (supervisorctl/web interface) to work, additional interfaces may be
; added by defining them in separate rpcinterface: sections
[rpcinterface:supervisor]
supervisor.rpcinterface_factory = supervisor.rpcinterface:make_main_rpcinterface

[supervisorctl]
serverurl=unix:///dev/shm/supervisor.sock ; mesmo socket definido em [unix_http_server]

[include]
files = /etc/supervisor/conf.d/*.conf
ECIDADE_ARQUIVO_EOF

cat > "$DIR/docker/supervisord/conf.d/apache.conf" <<'ECIDADE_ARQUIVO_EOF'
[program:apache]
command=/usr/sbin/apache2ctl -DFOREGROUND
autostart=true
autorestart=true
priority=10
startretries=3
startsecs=1
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
ECIDADE_ARQUIVO_EOF

cat > "$DIR/docker/supervisord/conf.d/php-fpm.conf" <<'ECIDADE_ARQUIVO_EOF'
[program:php-fpm]
command = /usr/sbin/php-fpm7.4 --nodaemonize --fpm-config /etc/php/7.4/fpm/php-fpm.conf
autostart=true
autorestart=true
priority=5
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
ECIDADE_ARQUIVO_EOF

cat > "$DIR/docker/supervisord/conf.d/php-log.conf" <<'ECIDADE_ARQUIVO_EOF'
; Replica o log de erros do PHP (/var/log/php/php_errors.log) no "docker logs"
[program:php-log]
command = /usr/bin/tail -n 0 -F /var/log/php/php_errors.log
autostart=true
autorestart=true
priority=20
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/null
ECIDADE_ARQUIVO_EOF

cat > "$DIR/docker/pgadmin/servers.json" <<'ECIDADE_ARQUIVO_EOF'
{
  "Servers": {
    "1": {
      "Name": "e-Cidade",
      "Group": "Servers",
      "Host": "bd",
      "Port": 5432,
      "MaintenanceDB": "ecidade",
      "Username": "ecidade",
      "SSLMode": "prefer",
      "Comment": "Banco do e-Cidade (container bd). Senha padrao: ecidade"
    }
  }
}
ECIDADE_ARQUIVO_EOF


chmod 755 "$DIR/docker/scripts/iniciar.sh"
ok "docker-compose.yml e docker/* atualizados"

# ----------------------------------------------------------------------------
# .env
# ----------------------------------------------------------------------------
env_set() { # env_set CHAVE VALOR  (substitui ou acrescenta no .env)
    if grep -q "^$1=" "$DIR/.env"; then
        sed -i "s|^$1=.*|$1=$2|" "$DIR/.env"
    else
        printf '%s=%s\n' "$1" "$2" >> "$DIR/.env"
    fi
}
env_get() { sed -n "s/^$1=//p" "$DIR/.env" | tail -1 | tr -d '"'"'"; }

if [ ! -f "$DIR/.env" ]; then
    cp "$DIR/.env.example" "$DIR/.env"
    ok ".env criado a partir do .env.example"
fi
# O host do banco é o nome do serviço no docker compose ("bd"). O valor
# "e-cidade-bd-1" só funciona se a pasta do projeto se chamar "e-cidade".
case "$(env_get DB_HOST)" in
    ""|e-cidade-bd-1|localhost|127.0.0.1) env_set DB_HOST bd; ok "DB_HOST=bd" ;;
esac
[ -n "$(env_get DB_PORT)" ] || env_set DB_PORT 5432
for V in APP_PORT PGADMIN_PORT DB_PORTA PGADMIN_EMAIL PGADMIN_PASSWORD XDEBUG_MODE; do
    eval "VAL=\${$V:-}"
    [ -n "$VAL" ] && env_set "$V" "$VAL"
done

# Banco e backups fora do controle do git
if [ -d "$DIR/.git" ]; then
    grep -qx 'docker/bd/pgsql' "$DIR/.git/info/exclude" 2>/dev/null || echo 'docker/bd/pgsql' >> "$DIR/.git/info/exclude"
fi

# ----------------------------------------------------------------------------
# Containers
# ----------------------------------------------------------------------------
# Várias instâncias no mesmo host: o nome do projeto (prefixo dos containers)
# vem do nome da pasta, e cada instância precisa de portas próprias.
PROJETO="$(env_get COMPOSE_PROJECT_NAME)"
[ -n "$PROJETO" ] || PROJETO="$(basename "$DIR" | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9_-]//g')"
info "Projeto docker compose: $PROJETO (containers $PROJETO-web-1, $PROJETO-bd-1, $PROJETO-pgadmin-1)"
for PAR in "APP_PORT:8282" "DB_PORTA:5432" "PGADMIN_PORT:8283"; do
    VAR="${PAR%%:*}"; PORTA="$(env_get "$VAR")"; PORTA="${PORTA:-${PAR#*:}}"
    DONO="$(docker ps --format '{{.Label "com.docker.compose.project"}}|{{.Names}}|{{.Ports}}' \
        | grep -E "[:.]$PORTA->" | grep -v "^$PROJETO|" | cut -d'|' -f2 | head -1 || true)"
    [ -z "$DONO" ] || erro "Porta $PORTA ($VAR) já usada pelo container $DONO. Rode novamente com outra porta, ex.: $VAR=$((PORTA + 100)) sh $0 $DIR"
done

info "Construindo imagens e subindo containers (a primeira vez demora vários minutos)"
dc up -d --build --remove-orphans

aguardar_saude() { # aguardar_saude SERVICO TIMEOUT_SEG
    SVC="$1"; LIM="$2"; T=0
    while [ "$T" -lt "$LIM" ]; do
        CID="$(dc ps -q "$SVC" 2>/dev/null || true)"
        if [ -n "$CID" ]; then
            ST="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$CID" 2>/dev/null || true)"
            case "$ST" in
                healthy) return 0 ;;
                exited|dead) dc logs --tail 50 "$SVC"; erro "Container $SVC parou" ;;
            esac
        fi
        sleep 5; T=$((T + 5))
    done
    dc logs --tail 50 "$SVC"
    erro "Tempo esgotado aguardando o container $SVC"
}

info "Aguardando o banco de dados"
aguardar_saude bd 600
ok "Banco de dados pronto"
info "Aguardando o container web (permissões e composer install na primeira vez)"
aguardar_saude web 1800
ok "Container web pronto"

psql_bd() { dc exec -T bd psql -U postgres -v ON_ERROR_STOP=1 -tA "$@"; }
web_www() { dc exec -T -u www-data -e HOME=/home/www-data web "$@"; }

# ----------------------------------------------------------------------------
# Banco de dados
# ----------------------------------------------------------------------------
if ! psql_bd -c "select 1 from pg_database where datname='ecidade'" | grep -q 1; then
    info "Criando roles e banco ecidade (iniciarbd.sql)"
    dc exec -T bd psql -U postgres -f /docker-entrypoint-initdb.d/iniciarbd.sql >/dev/null
fi
NUM_TABELAS="$(psql_bd -d ecidade -c "select count(*) from pg_tables where schemaname not in ('pg_catalog','information_schema')")"

if [ "$NUM_TABELAS" -gt 0 ]; then
    ok "Banco ecidade já possui $NUM_TABELAS tabelas: preservado"
elif [ "$RESTAURAR_BANCO" = 0 ]; then
    aviso "Banco ecidade vazio e --sem-banco informado: restaure manualmente"
else
    if [ -z "$DUMP" ]; then
        BASE_DIR="$(dirname "$DIR")/base-dados-ecidade"
        if [ -d "$BASE_DIR/.git" ]; then
            info "Usando base de dados existente em $BASE_DIR"
        else
            info "Clonando base de dados zerada ($REPO_BASE)"
            git clone --depth 1 "$REPO_BASE" "$BASE_DIR"
        fi
        DUMP="$(ls "$BASE_DIR"/dump_e-cidade-zerada.sql.bz2 "$BASE_DIR"/dump_e-cidade-zerada.sql "$BASE_DIR"/db/dump_e-cidade-zerada.sql.bz2 2>/dev/null | head -1 || true)"
        [ -n "$DUMP" ] || erro "dump_e-cidade-zerada.sql(.bz2) não encontrado em $BASE_DIR"
    fi
    [ -f "$DUMP" ] || erro "Dump não encontrado: $DUMP"
    LOG_RESTORE="$BACKUP_DIR/restore-$DATA.log"
    mkdir -p "$BACKUP_DIR"
    info "Restaurando $(basename "$DUMP") no banco ecidade (pode levar vários minutos)"
    case "$DUMP" in
        *.bz2)
            [ -n "$BUNZIP" ] || erro "bunzip2/bzip2 não encontrado para descompactar $DUMP"
            $BUNZIP "$DUMP" | dc exec -T bd psql -U ecidade -d ecidade -q > "$LOG_RESTORE" 2>&1 || true ;;
        *)
            dc exec -T bd psql -U ecidade -d ecidade -q < "$DUMP" > "$LOG_RESTORE" 2>&1 || true ;;
    esac
    NUM_TABELAS="$(psql_bd -d ecidade -c "select count(*) from pg_tables where schemaname not in ('pg_catalog','information_schema')")"
    NUM_ERROS="$(grep -c 'ERRO\|ERROR' "$LOG_RESTORE" || true)"
    [ "$NUM_TABELAS" -gt 0 ] || erro "Restauração falhou (nenhuma tabela criada). Veja $LOG_RESTORE"
    ok "Base restaurada: $NUM_TABELAS tabelas ($NUM_ERROS mensagens de erro, log em $LOG_RESTORE)"
fi

# ----------------------------------------------------------------------------
# Aplicação (executado como www-data, dentro do container web)
# ----------------------------------------------------------------------------
info "Configurando a aplicação"
if [ -z "$(env_get APP_KEY)" ]; then
    web_www php artisan key:generate --force
fi
web_www php artisan config:clear >/dev/null || aviso "artisan config:clear falhou"
web_www php artisan cache:clear  >/dev/null || aviso "artisan cache:clear falhou"

# Modo Desktop (INSTALL.md)
DESKTOP_DATA=extension/data/extension/Desktop.data
if [ "$REINSTALAR_DESKTOP" = 1 ] || [ ! -f "$DIR/$DESKTOP_DATA" ]; then
    info "Instalando a extensão Desktop para o usuário dbseller"
    mkdir -p "$BACKUP_DIR"
    LOG_DESKTOP="$BACKUP_DIR/desktop-$DATA.log"
    if web_www sh -c '
        set -e
        mkdir -p extension/log
        [ -f extension/data/extension/Desktop.data ] || cp extension/data/extension/Desktop.data.dist extension/data/extension/Desktop.data
        [ -f extension/modification/data/modification/dbportal-v3-desktop.data ] || \
            cp extension/modification/data/modification/dbportal-v3-desktop.data.dist extension/modification/data/modification/dbportal-v3-desktop.data
        php bin/v3/extension/uninstall Desktop dbseller || true
        php bin/v3/extension/install Desktop dbseller
    ' > "$LOG_DESKTOP" 2>&1; then
        # Mensagens "Arquivo não existe" referem-se a telas cadastradas no banco
        # que não existem no código-fonte; não impedem o funcionamento.
        ok "Extensão Desktop instalada ($(grep -c 'ERROR' "$LOG_DESKTOP" || true) avisos da aplicação, log em $LOG_DESKTOP)"
    else
        tail -20 "$LOG_DESKTOP"
        aviso "Falha ao instalar a extensão Desktop (log completo em $LOG_DESKTOP)"
    fi
else
    ok "Extensão Desktop já configurada (use --reinstalar-desktop para refazer)"
fi

# ----------------------------------------------------------------------------
# Verificação final
# ----------------------------------------------------------------------------
info "Verificando gravação pelo PHP (www-data)"
FALHAS=""
for P in tmp storage/logs storage/framework/cache storage/framework/sessions storage/framework/views \
         bootstrap/cache cache extension/log extension/data/extension imagens/files legacy_config; do
    web_www sh -c "f=\"$P/.teste-gravacao\$\$\" && : > \"\$f\" && rm -f \"\$f\"" 2>/dev/null || FALHAS="$FALHAS $P"
done
web_www php -r 'error_log("instalar-ecidade: teste de log do PHP");' 2>/dev/null || FALHAS="$FALHAS php_errors.log"
if [ -n "$FALHAS" ]; then
    aviso "Sem permissão de gravação em:$FALHAS"
else
    ok "PHP grava em todas as pastas verificadas e no log de erros"
fi

HTTP="$(dc exec -T web curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1/login.php || true)"
[ "$HTTP" = 200 ] && ok "login.php respondeu HTTP 200" || aviso "login.php respondeu HTTP $HTTP"

IP="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1)"
[ -n "$IP" ] || IP=localhost
APP_PORT_V="$(env_get APP_PORT)"; APP_PORT_V="${APP_PORT_V:-8282}"
PGA_PORT_V="$(env_get PGADMIN_PORT)"; PGA_PORT_V="${PGA_PORT_V:-8283}"
PGA_EMAIL_V="$(env_get PGADMIN_EMAIL)"; PGA_EMAIL_V="${PGA_EMAIL_V:-admin@ecidade.com.br}"
PGA_PASS_V="$(env_get PGADMIN_PASSWORD)"; PGA_PASS_V="${PGA_PASS_V:-admin}"

cat <<FIM

=============================================================================
 e-Cidade instalado ($MODO) em $DIR
=============================================================================
 Sistema:  http://$IP:$APP_PORT_V/           usuário: dbseller  senha: dbseller
 pgAdmin:  http://$IP:$PGA_PORT_V/           login: $PGA_EMAIL_V / $PGA_PASS_V
           servidor "e-Cidade" já cadastrado (usuário ecidade, senha ecidade)
 Banco:    $IP:$(env_get DB_PORTA | grep . || echo 5432)  (postgres/postgres, ecidade/ecidade)

 Logs:     cd $DIR && $DC_BIN logs -f web
           log do PHP: $DC_BIN exec web tail -f /var/log/php/php_errors.log
           log Laravel: $DIR/storage/logs/laravel.log
 Backups:  $BACKUP_DIR
=============================================================================
FIM
