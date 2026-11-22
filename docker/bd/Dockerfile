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
