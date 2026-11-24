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
#        --dump ARQUIVO      Usa um dump local (.sql, .sql.bz2 ou pg_dump -Fc) em vez da base zerada
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

#@@ARQUIVOS@@

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
    # Formato custom do pg_dump (-Fc, cabeçalho "PGDMP"): pg_restore
    if [ "$(head -c 5 "$DUMP")" = PGDMP ]; then
        dc exec -T bd pg_restore -U ecidade -d ecidade < "$DUMP" > "$LOG_RESTORE" 2>&1 || true
    else
    case "$DUMP" in
        *.bz2)
            [ -n "$BUNZIP" ] || erro "bunzip2/bzip2 não encontrado para descompactar $DUMP"
            $BUNZIP "$DUMP" | dc exec -T bd psql -U ecidade -d ecidade -q > "$LOG_RESTORE" 2>&1 || true ;;
        *)
            dc exec -T bd psql -U ecidade -d ecidade -q < "$DUMP" > "$LOG_RESTORE" 2>&1 || true ;;
    esac
    fi
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
