# e-Cidade no Docker: correções e instalador

## Arquivos (caminhos a partir da raiz do projeto)

| Arquivo | Descrição |
|---|---|
| `instalar-ecidade.sh` | **Script único** (POSIX `sh`) que faz uma instalação nova ou corrige uma existente preservando o banco. Já contém todos os arquivos abaixo embutidos. |
| `INSTALL.md` | Seção **Docker** com o procedimento de instalação |
| `docker-compose.yml` | Compose corrigido, com o serviço **pgadmin** |
| `docker/Dockerfile` | Imagem web (Ubuntu 22.04 + Apache + PHP-FPM 7.4) corrigida |
| `docker/bd/Dockerfile` | Imagem do PostgreSQL 12 corrigida (o build estava quebrado) |
| `docker/scripts/iniciar.sh` | Script de boot do container web (permissões, composer) |
| `docker/scripts/iniciarbd.sql` | Roles e banco criados na primeira inicialização do PostgreSQL |
| `docker/apache2/ecidade.conf` | Vhost: bloqueia o acesso web a `docker/`, `.git` e `.env` |
| `docker/supervisord/*` | Supervisor sem `sudo`; log do PHP enviado ao `docker logs` |
| `docker/pgadmin/servers.json` | Servidor "e-Cidade" já cadastrado no pgAdmin |
| `docker/instalador/` | Modelo do instalador e o gerador (`sh docker/instalador/gerar-instalador.sh` recria o `instalar-ecidade.sh` depois de editar os arquivos acima) |

## Uso

```sh
# Instalação nova (clona https://github.com/ramersonw/e-cidade em /projetos/e-cidade)
sh instalar-ecidade.sh

# Corrigir uma instalação existente (detecta sozinho e preserva o banco)
sh instalar-ecidade.sh /caminho/da/instalacao

# Portas diferentes
APP_PORT=8080 PGADMIN_PORT=8081 DB_PORTA=5433 sh instalar-ecidade.sh

sh instalar-ecidade.sh --help
```

Ao final:

- Sistema: `http://IP:8282/` (dbseller / dbseller)
- pgAdmin: `http://IP:8283/` (admin@ecidade.com.br / admin; servidor "e-Cidade", senha `ecidade`)
- PostgreSQL: `IP:5432`

### Várias instâncias no mesmo computador

Cada pasta é uma instância independente. Containers, imagens, rede e volume do pgAdmin
recebem o nome da pasta como prefixo (`cliente2-web-1`, `cliente2-bd-1`,
`cliente2-pgadmin-1`), e o banco fica em `<pasta>/docker/bd/pgsql`. Cada instância
precisa de **três portas próprias**:

```sh
APP_PORT=8382 DB_PORTA=5433 PGADMIN_PORT=8383 sh instalar-ecidade.sh /projetos/cliente2
APP_PORT=8482 DB_PORTA=5434 PGADMIN_PORT=8483 sh instalar-ecidade.sh /projetos/cliente3
```

As portas ficam gravadas no `.env` da instância. O script recusa portas já usadas por
outra instância antes de subir os containers. **O nome da pasta (só o último nível)
precisa ser único**: `/a/e-cidade` e `/b/e-cidade` seriam o mesmo projeto
"e-cidade" e uma instância assumiria os containers da outra. Se precisar repetir o nome,
defina `COMPOSE_PROJECT_NAME=nome_unico` no `.env`.

No modo correção, o script faz antes um backup do banco e um `.tar.gz` dos arquivos
Docker antigos em `<instalação>-backups/`. Com o banco rodando, o backup é um `pg_dump`;
com ele parado, é uma cópia de `docker/bd/pgsql`. Desative com `--sem-backup`.

## Problemas encontrados e correções

### 1. Erros de gravação (causa principal)
O código é um bind mount do host (`./:/var/www/html`) e o PHP-FPM roda como
`www-data` (uid 33), que não é dono de nada no host. O `composer install` do boot
rodava como `contass` (uid 1000) e também falhava ("vendor does not exist and could
not be created"). O INSTALL.md contornava isso com `sudo chown -R www-data html/`, que
**também trocava o dono dos dados do PostgreSQL** (`docker/bd/pgsql` fica dentro da
pasta montada). O resultado era o banco com "Permissão negada", e daí o passo extra
`chown -R postgres:postgres`. Qualquer arquivo criado depois como root, por
`sudo artisan` por exemplo, voltava a quebrar a gravação.

**Correção** (`iniciar.sh`, roda como root a cada boot):
- o `www-data` passa a usar o **UID/GID do dono do código no host**. Se o dono for root,
  mantém o uid 33 e os arquivos passam para ele. Pode ser forçado com `WWW_UID`/`WWW_GID`;
- corrige o dono de arquivos criados por outros usuários (exceto `.git` e dados do banco);
- cria as pastas graváveis que faltavam: `cache/*`, `imagens/files` (a partir de
  `imagens/files.proper`), `extension/log`, `storage/*`, `legacy_config/preferencias.json`...;
- roda o `composer install` como `www-data`, só quando o `vendor` está ausente ou desatualizado;
- dentro do container web, `docker/bd/pgsql` fica coberto por um `tmpfs`, então o banco
  nunca mais é afetado.

### 2. O PHP não gravava logs
`error_log` apontava para um link para `/dev/stderr`. Nos workers do FPM esse stderr é
`/dev/null` (sem `catch_workers_output`), e todo log se perdia. Agora o log vai para
`/var/log/php/php_errors.log`, gravável pelo www-data, e é replicado no
`docker compose logs web`.

### 3. HOME do www-data não gravável
O HOME era `/var/www` (dono root). LibreOffice e ImageMagick, usados na geração de
documentos, gravam perfil e cache no HOME. Agora o HOME é `/home/www-data`, também
definido no pool do FPM.

### 4. Build quebrado
- `docker/bd/Dockerfile`: o repositório `bullseye-pgdg` foi descontinuado
  (`apt-get update` falhava) e o Debian 11 saiu do LTS (download de `locales` com 404).
  O repositório foi removido e o `apt-get install` usa `--no-upgrade`. A imagem base
  continua a mesma (`postgres:12.17-bullseye`) para não mudar a glibc/collation de
  bancos existentes.

### 5. Outros ajustes
- O container roda como root sob o supervisord, sem `sudo` em todo lado. O Apache e o
  PHP-FPM continuam trocando para `www-data`. O usuário `contass` foi mantido por
  compatibilidade.
- O `supervisorctl` apontava para um socket diferente do supervisord; corrigido.
- O PostgreSQL recebe os parâmetros exigidos pelo INSTALL.md, que o Docker não aplicava:
  `standard_conforming_strings=off`, `bytea_output=escape`,
  `max_locks_per_transaction=256`, `escape_string_warning=off`.
- `DB_HOST=e-cidade-bd-1` só funcionava se a pasta se chamasse `e-cidade`; agora é `bd`
  (nome do serviço).
- Healthcheck no container web; no `bd`, o healthcheck usa o usuário `postgres`.
- O Apache nega o acesso a `/docker`, `/.git` e `/.env` (antes os dados do banco
  ficavam dentro da raiz do site).

## Comandos úteis

```sh
cd /projetos/e-cidade
docker compose logs -f web                                # apache, php-fpm e erros do PHP
docker compose exec -u www-data web php artisan cache:clear   # sempre como www-data
docker compose exec bd psql -U ecidade ecidade
```
