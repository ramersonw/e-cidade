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
