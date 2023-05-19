FROM php:8.2-alpine3.17 as base

ARG SHLINK_VERSION=latest
ENV SHLINK_VERSION ${SHLINK_VERSION}
ARG SHLINK_RUNTIME=openswoole
ENV SHLINK_RUNTIME ${SHLINK_RUNTIME}
ENV OPENSWOOLE_VERSION 22.0.0
ENV PDO_SQLSRV_VERSION 5.10.1
ENV MS_ODBC_DOWNLOAD 'b/9/f/b9f3cce4-3925-46d4-9f46-da08869c6486'
ENV MS_ODBC_SQL_VERSION 18_18.1.1.1
ENV LC_ALL "C"

WORKDIR /etc/shlink

# Install required PHP extensions
RUN \
    # Temp install dev dependencies needed to compile the extensions
    apk add --no-cache --virtual .dev-deps sqlite-dev postgresql-dev icu-dev libzip-dev zlib-dev libpng-dev linux-headers && \
    docker-php-ext-install -j"$(nproc)" pdo_mysql pdo_pgsql intl calendar sockets bcmath zip gd && \
    apk add --no-cache sqlite-libs && \
    docker-php-ext-install -j"$(nproc)" pdo_sqlite && \
    # Remove temp dev extensions, and install prod equivalents that are required at runtime
    apk del .dev-deps && \
    apk add --no-cache postgresql icu libzip libpng supercronic

# Install openswoole and sqlsrv driver for x86_64 builds
RUN apk add --no-cache --virtual .phpize-deps ${PHPIZE_DEPS} unixodbc-dev && \
    if [ "$SHLINK_RUNTIME" == 'openswoole' ]; then \
        pecl install openswoole-${OPENSWOOLE_VERSION} && \
        docker-php-ext-enable openswoole ; \
    fi; \
    if [ $(uname -m) == "x86_64" ]; then \
      wget https://download.microsoft.com/download/${MS_ODBC_DOWNLOAD}/msodbcsql${MS_ODBC_SQL_VERSION}-1_amd64.apk && \
      apk add --allow-untrusted msodbcsql${MS_ODBC_SQL_VERSION}-1_amd64.apk && \
      pecl install pdo_sqlsrv-${PDO_SQLSRV_VERSION} && \
      docker-php-ext-enable pdo_sqlsrv && \
      rm msodbcsql${MS_ODBC_SQL_VERSION}-1_amd64.apk ; \
    fi; \
    apk del .phpize-deps

# Install shlink
FROM base as builder
COPY . .
COPY --from=composer:2 /usr/bin/composer ./composer.phar
RUN apk add --no-cache git && \
    # FIXME Ignoring ext-openswoole platform req, as it makes install fail with roadrunner, even though it's a dev dependency and we are passing --no-dev
    php composer.phar install --no-dev --prefer-dist --optimize-autoloader --no-progress --no-interaction --ignore-platform-req=ext-openswoole && \
    if [ "$SHLINK_RUNTIME" == 'openswoole' ]; then \
        php composer.phar remove spiral/roadrunner spiral/roadrunner-jobs spiral/roadrunner-cli spiral/roadrunner-http --with-all-dependencies --update-no-dev --optimize-autoloader --no-progress --no-interaction ; \
    elif [ "$SHLINK_RUNTIME" == 'rr' ]; then \
        php composer.phar remove mezzio/mezzio-swoole --with-all-dependencies --update-no-dev --optimize-autoloader --no-progress --no-interaction ; \
    fi; \
    php composer.phar clear-cache && \
    rm -r docker composer.* && \
    sed -i "s/%SHLINK_VERSION%/${SHLINK_VERSION}/g" config/autoload/app_options.global.php


RUN chown -R 1001 /etc/shlink && \
  chmod -R g=u /etc/shlink

# Prepare final image
FROM base
LABEL maintainer="Alejandro Celaya <alejandro@alejandrocelaya.com>"

COPY --from=builder /etc/shlink .
RUN ln -s /etc/shlink/bin/cli /usr/local/bin/shlink && \
    if [ "$SHLINK_RUNTIME" == 'rr' ]; then \
      php ./vendor/bin/rr get --no-interaction --no-config --location bin/ && chmod +x bin/rr ; \
    fi;

# Expose default port
EXPOSE 8080

# Copy config specific for the image
COPY --chown=1001:0 --chmod=664 docker/docker-entrypoint.sh docker-entrypoint.sh
COPY --chown=1001:0 --chmod=664 docker/config/shlink_in_docker.local.php config/autoload/shlink_in_docker.local.php
COPY docker/config/php.ini ${PHP_INI_DIR}/conf.d/


USER 1001

ENTRYPOINT ["/bin/sh", "./docker-entrypoint.sh"]
