# Guia de instalação

Você pode instalar o e-Cidade utilizando Docker ou diretamente no seu servidor web, caso você deseje atualizar sua 
instalação siga os passos do [guia de atualização](UPGRADE.md).

- [Instalação em servidor web](#instalação-em-servidor-web)
- [Instalação utilizando Docker](#docker)
- [Primeiro acesso](#primeiro-acesso)

### Docker
#### Obs.: Tenha o docker instalado na sua maquina. [Link Instalar Docker](https://docs.docker.com/get-started/get-docker/)

**Pré-requisitos:**

- Linux com Docker e o plugin `docker compose`;
- `git` e `bunzip2` (ou `bzip2`);
- Executar como root ou com um usuário do grupo `docker`.

A instalação sobe três containers:

| Serviço | Descrição | Porta padrão |
|---|---|---|
| `web` | Apache + PHP-FPM 7.4 com o e-Cidade | `8282` (`APP_PORT`) |
| `bd` | PostgreSQL 12 (LATIN1 / pt_BR.ISO-8859-1) | `5432` (`DB_PORTA`) |
| `pgadmin` | pgAdmin 4 com o servidor "e-Cidade" já cadastrado | `8283` (`PGADMIN_PORT`) |

#### Instalação automática (recomendado)

O script `instalar-ecidade.sh`, na raiz do projeto, faz todo o processo: clona o
projeto, sobe os containers, restaura a base zerada
([base-dados-ecidade](https://github.com/e-cidade/base-dados-ecidade)) e configura o
modo Desktop.

```bash
# Baixe só o script (ou use o que está no projeto já clonado)
curl -fsSLO https://raw.githubusercontent.com/ramersonw/e-cidade/main/instalar-ecidade.sh

# Instalação nova em /projetos/e-cidade
sh instalar-ecidade.sh /projetos/e-cidade
```

Ao final, o script mostra os endereços de acesso e confere se o PHP consegue gravar nas
pastas do sistema e no log. Use `sh instalar-ecidade.sh --help` para ver todas as
opções (outro repositório ou branch, dump local, sem backup etc.).

**Corrigir ou atualizar uma instalação existente:** execute o script apontando para a
pasta da instalação. Ele detecta a instalação e faz backup do banco em
`<pasta>-backups/` (`pg_dump`, ou cópia dos arquivos se o banco estiver parado). Depois
atualiza os arquivos Docker e recria os containers **preservando o banco de dados**.

```bash
sh instalar-ecidade.sh /projetos/e-cidade
```

#### Várias instalações no mesmo computador

Cada pasta é uma instalação independente: containers, imagens, rede e volumes recebem o
nome da pasta como prefixo (ex.: `cliente2-web-1`, `cliente2-bd-1`,
`cliente2-pgadmin-1`). Informe portas diferentes para cada uma:

```bash
APP_PORT=8382 DB_PORTA=5433 PGADMIN_PORT=8383 sh instalar-ecidade.sh /projetos/cliente2
APP_PORT=8482 DB_PORTA=5434 PGADMIN_PORT=8483 sh instalar-ecidade.sh /projetos/cliente3
```

As portas ficam gravadas no `.env` da instalação. O script recusa portas já usadas por
outra instalação. **O nome da pasta (último nível) deve ser único**; para repetir um
nome, defina `COMPOSE_PROJECT_NAME=nome_unico` no `.env`.

#### Instalação manual

Equivale ao que o script faz. Não é necessário `sudo` nem `chown` manual: ao iniciar, o
container `web` ajusta sozinho as permissões e executa o `composer install`.

```bash
# 1. Projeto e configuração
git clone https://github.com/ramersonw/e-cidade.git e-cidade
cd e-cidade
cp .env.example .env
sed -i 's|^DB_HOST=.*|DB_HOST=bd|' .env      # host do banco = nome do serviço

# 2. Containers (aguarde o "web" ficar "healthy" - a primeira vez demora)
docker compose up -d --build
docker compose ps

# 3. Base de dados zerada
git clone --depth 1 https://github.com/e-cidade/base-dados-ecidade.git ../base-dados-ecidade
bunzip2 -c ../base-dados-ecidade/dump_e-cidade-zerada.sql.bz2 \
  | docker compose exec -T bd psql -U ecidade -d ecidade -q

# 4. Aplicação e modo Desktop (sempre como www-data)
docker compose exec -u www-data web php artisan key:generate --force
docker compose exec -u www-data web sh -c '
  cp -n extension/data/extension/Desktop.data.dist extension/data/extension/Desktop.data
  cp -n extension/modification/data/modification/dbportal-v3-desktop.data.dist \
        extension/modification/data/modification/dbportal-v3-desktop.data
  php bin/v3/extension/uninstall Desktop dbseller
  php bin/v3/extension/install Desktop dbseller'
```

> O `uninstall` antes do `install` é necessário: o `Desktop.data.dist` já marca o
> usuário dbseller como instalado e, sem ele, o `install` recusa com "Extensão já
> instalada" sem aplicar as modificações do modo Desktop.

> As mensagens `Arquivo não existe: '...php'` na instalação do Desktop referem-se a
> telas cadastradas na base que não existem no código e não impedem o funcionamento.

#### Acesso

| | Endereço | Usuário / senha |
|---|---|---|
| e-Cidade | `http://IP:8282/` | `dbseller` / `dbseller` |
| pgAdmin | `http://IP:8283/` | `admin@ecidade.com.br` / `admin` (altere com `PGADMIN_EMAIL` / `PGADMIN_PASSWORD`) |
| PostgreSQL | `IP:5432` | `ecidade` / `ecidade` ou `postgres` / `postgres` |

No pgAdmin, o servidor "e-Cidade" já está cadastrado; na primeira conexão informe a
senha `ecidade`.

#### Permissões, logs e dicas

- O Apache e o PHP rodam como `www-data` com o **mesmo UID/GID do dono da pasta do
  projeto no host**: os arquivos continuam editáveis pelo seu usuário e graváveis pelo
  sistema. Se o dono for root, os arquivos passam para o `www-data` (uid 33). O UID/GID
  pode ser forçado com `WWW_UID` e `WWW_GID` no `.env`.
- Os dados do PostgreSQL ficam em `docker/bd/pgsql`. **Não execute `chown -R` na pasta do
  projeto**, nem dentro do container: as permissões são corrigidas a cada inicialização
  do container `web` (`docker compose restart web`).
- Execute comandos da aplicação como `www-data`, para não criar arquivos de root:
  `docker compose exec -u www-data web php artisan cache:clear`.
- Logs:
  - `docker compose logs -f web`: Apache, PHP-FPM e erros do PHP;
  - `docker compose exec web tail -f /var/log/php/php_errors.log`: log do PHP;
  - `storage/logs/laravel.log` e `extension/log/`: logs da aplicação.
- Banco via terminal: `docker compose exec bd psql -U ecidade ecidade`.

## Instalação em servidor web

Para instalar o projeto execute **todos os passos** abaixo conectado em seu servidor web. Este passo a passo serve para um servidor Ubuntu 22.04 LTS 



### 1. Postgresql

#### 1.1 Instalação

    sudo apt-get update
    sudo apt-get upgrade
    sudo apt-get install postgresql-12 postgresql-contrib-12
    sudo pg_dropcluster --stop 12 main


#### 1.2 Configurando locales

    sudo vim /usr/share/i18n/locales/pt_BR
    sudo localedef -i pt_BR -c -f ISO-8859-1 -A /usr/share/locale/locale.alias pt_BR
    sudo locale-gen pt_BR
    sudo dpkg-reconfigure locales
    export LC_ALL=pt_BR
    sudo echo LC_ALL=pt_BR >> /etc/environment

#### 1.3 Configurando cluster

    sudo pg_createcluster -e LATIN1 12 main
    sudo /etc/init.d/postgresql start
    sudo vim /etc/postgresql/12/main/pg_hba.conf
    sudo /etc/init.d/postgresql reload

#### 1.3 Configurando Postgres

Edit o arquivo postgresql.conf com os dados a abaixo

    sudo vim /etc/postgresql/12/main/postgresql.conf


    listen_addresses = '*'
    max_connections = 20
    bytea_output = 'escape'
    max_locks_per_transaction = 256
    escape_string_warning = off
    standard_conforming_strings = off
    sudo /etc/init.d/postgresql restart

#### 1.4 Configurando Postgres
Cria banco de dados e usuários

    psql -U postgres -h localhost template1 -c "create role ecidade with superuser login password 'ecidade'"
    psql -U postgres -h localhost template1 -c "create role dbportal with superuser login password 'dbportal'"
    psql -U postgres -h localhost template1 -c "create role dbseller with login password 'dbseller'"
    psql -U postgres -h localhost template1 -c "create role plugin with login password 'plugin'"
    psql -U postgres -h localhost template1 -c "create role usersrole with login password 'usersrole'"
    createdb -U dbportal e-cidade

### 2. Apache

    sudo apt-get update
    sudo apt-get upgrade
    sudo apt-get install apache2
    sudo vim /etc/apache2/apache2.conf
    sudo vim /etc/apache2/conf-available/charset.conf
    sudo a2enmod rewrite
    sudo /etc/init.d/apache2 restart
    sudo mkdir /var/www/tmp
    sudo chown -R www-data.www-data /var/www/tmp
    sudo chmod -R 777 /var/www/tmp
    sudo vim /etc/apache2/sites-available/000-default.conf
    sudo a2enmod proxy_fcgi setenvif rewrite
    sudo systemctl restart apache2


### 3. Instale o PHP

#### 3.1 Instale PHP

    sudo apt-get update
    sudo apt-get upgrade
    sudo apt-get install php7.4 php7.4-gd php7.4-pgsql php7.4-cli php7.4-bcmath php7.4-zip php7.4-imagick php7.4-curl php7.4-mbstring php7.4-xml curl libcurl4 libapache2-mod-php7.4 zip
    sudo mkdir /var/www/log
    sudo chown -R www-data.www-data /var/www/log
    sudo chown root.www-data /var/lib/php/

#### 3.2 Configurando PHP

Edit o arquivo e altere os parametros conforme o modelo

    sudo vim /etc/php/7.4/apache2/php.ini
     
    short_open_tag = On
    register_argc_argv = on
    post_max_size = 64M
    upload_max_filesize = 64M
    default_socket_timeout = 60000
    max_execution_time = 60000
    max_input_time = 60000
    memory_limit = 512M
    allow_call_time_pass_reference = on
    error_reporting = E_ALL & ~E_NOTICE
    display_errors = off
    log_errors = on
    error_log = /var/www/log/php-scripts.log
    session.gc_maxlifetime = 7200

#### 3.3 Composer

    cd ~
    curl -sS https://getcomposer.org/installer -o /tmp/composer-setup.php
    sudo php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer


### 4. Instale o Libreoffice

    sudo apt-get install libreoffice-writer python3-uno openjdk-17-jre-headless
    systemctl status rc-local
    sudo vim /lib/systemd/system/rc-local.service
    printf '%s\n' '#!/bin/bash' 'exit 0' | sudo tee -a /etc/rc.local
    sudo chmod +x /etc/rc.local
    sudo vim /etc/rc.local
    sudo systemctl enable rc-local
    sudo systemctl start rc-local.service
    sudo systemctl status rc-local


### 5. Instale o e-Cidade

Faça o clone do repositorio:

    cd /var/www
    sudo mkdir /var/www/e-cidade
    sudo chown -R www-data.www-data /var/www/e-cidade
    sudo chmod -R 775 /var/www/e-cidade
    git clone git@github.com:e-cidade/e-cidade.git e-cidade
    sudo chown -R www-data:www-data e-cidade/
    sudo chmod -R 775 e-cidade/
    sudo chmod -R 777 e-cidade/tmp/
    sudo chmod -R 777 /var/www/e-cidade/storage/
    cd /var/www/e-cidade
    composer install
    cp -a /var/www/e-cidade/imagens/files.proper /var/www/e-cidade/imagens/files
    cp .env.example .env


Restaure o banco dadao inicial:

    cd ~
    git clone git@github.com:e-cidade/base-dados-ecidade.git 
    cd base-dados-ecidade
    bunzip db/dump_e-cidade-zerada.sql.bz2
    psql -U dbportal e-cidade -f dump_e-cidade-zerada.sql


### 6. Instale usuarios versão aparência de Desktop e-Cidade

    cd /var/www/
    sudo chmod -R 775 /var/www/e-cidade/*
    sudo chmod -R 777 /var/www/e-cidade/tmp/
    sudo chmod -R 777 /var/www/e-cidade/storage/
    cd /var/www/e-cidade/
    cd /var/www/e-cidade/config/
    cp preferencias.json.dist preferencias.json
    cd /var/www/e-cidade/extension/data/extension/
    cp Desktop.data.dist Desktop.data  
    cd /var/www/e-cidade/extension/modification/data/modification/
    cp dbportal-v3-desktop.data.dist dbportal-v3-desktop.data
    bin/v3/extension/install Desktop dbseller

### 7. LOGIN PADRÃO

#### O usuário e senha para o banco de dados zerado:
* Usuário: dbseller
* Senha: dbseller
