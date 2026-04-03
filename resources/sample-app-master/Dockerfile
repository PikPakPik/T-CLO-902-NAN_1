# Stage 1 : build
FROM php:8.2-fpm-alpine AS builder

WORKDIR /var/www/html/

RUN apk add --no-cache git unzip
RUN curl -sS https://getcomposer.org/installer | php && mv composer.phar /usr/local/bin/composer

COPY composer.json composer.lock /var/www/html/

RUN composer install --no-dev --optimize-autoloader --no-interaction --no-progress --no-scripts

COPY . /var/www/html/

RUN composer dump-autoload --optimize

# Stage 1 : runtime
FROM php:8.2-fpm-alpine

WORKDIR /var/www/html/

RUN apk add --no-cache nginx supervisor bash \
    && docker-php-ext-install -j$(nproc) pdo_mysql \
    && cp $PHP_INI_DIR/php.ini-production $PHP_INI_DIR/php.ini \
    && mkdir -p /etc/nginx/conf.d /var/www/html

COPY ./nginx.conf /etc/nginx/nginx.conf
COPY ./supervisord.conf /etc/supervisor/conf.d/supervisord.conf
COPY --from=builder /var/www/html /var/www/html

CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]