#!/bin/sh
# Gera instalar-ecidade.sh (raiz do projeto) embutindo os arquivos Docker corrigidos no modelo.
set -eu
cd "$(dirname "$0")/../.."
ARQS="docker-compose.yml
docker/Dockerfile
docker/bd/Dockerfile
docker/scripts/iniciar.sh
docker/scripts/iniciarbd.sql
docker/apache2/ecidade.conf
docker/supervisord/supervisord.conf
docker/supervisord/conf.d/apache.conf
docker/supervisord/conf.d/php-fpm.conf
docker/supervisord/conf.d/php-log.conf
docker/pgadmin/servers.json"
TMP=$(mktemp)
for F in $ARQS; do
    grep -q 'ECIDADE_ARQUIVO_EOF' "$F" && { echo "delimitador presente em $F" >&2; exit 1; }
    printf "cat > \"\$DIR/%s\" <<'ECIDADE_ARQUIVO_EOF'\n" "$F" >> "$TMP"
    tr -d '\r' < "$F" >> "$TMP"
    [ -z "$(tail -c1 "$F")" ] || echo >> "$TMP"
    printf 'ECIDADE_ARQUIVO_EOF\n\n' >> "$TMP"
done
awk -v f="$TMP" '/^#@@ARQUIVOS@@$/ { while ((getline l < f) > 0) print l; next } { print }' \
    docker/instalador/instalar-ecidade.tpl.sh | tr -d '\r' > instalar-ecidade.sh
rm -f "$TMP"
chmod 755 instalar-ecidade.sh
echo "gerado: instalar-ecidade.sh ($(wc -l < instalar-ecidade.sh) linhas)"
