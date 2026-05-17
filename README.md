# DevOps test stand

Тестовый production-like стенд для DevOps-задания.

Репозиторий содержит серверный стенд на одной Ubuntu-машине:

- nginx как внешний reverse proxy;
- app как backend-приложение на Go;
- postgres как база данных;
- HTTPS с самоподписанным сертификатом;
- firewall;
- SSH hardening;
- backup-скрипт для Postgres;
- GitHub Actions CI;
- nginx rate limiting для /api/.

## Архитектура

Пользователь -> nginx -> app -> postgres

Снаружи опубликованы только порты:

- 22/tcp для SSH;
- 80/tcp для HTTP redirect на HTTPS;
- 443/tcp для HTTPS.

app и postgres не публикуют порты наружу. Они доступны только внутри Docker-сети backend.

## Структура проекта

- README.md
- docker-compose.yml
- .env.example
- nginx/app.conf
- html/index.html
- app/Dockerfile
- app/go.mod
- app/go.sum
- app/main.go
- scripts/backup-db.sh
- .github/workflows/ci.yml

## Требования к серверу

Проверялось на Ubuntu 24.04 LTS в Multipass VM.

Рекомендуемые параметры VM:

- 2 CPU;
- 2 GB RAM;
- 12 GB disk.

Также подойдёт Ubuntu 22.04 или 24.04 на VPS.

## Быстрый деплой

1. Установить зависимости:

    sudo apt-get update
    sudo apt-get install -y ca-certificates curl git openssl ufw

2. Установить Docker:

    curl -fsSL https://get.docker.com | sudo sh
    sudo systemctl enable --now docker

3. Склонировать репозиторий:

    sudo rm -rf /opt/app
    sudo mkdir -p /opt/app
    sudo chown -R "$USER:$USER" /opt/app
    git clone https://github.com/diasrofi/devops-test-sop.git /opt/app
    cd /opt/app

4. Создать .env:

    cp .env.example .env
    POSTGRES_PASSWORD="$(openssl rand -base64 24 | tr -d '\n')"
    sed -i "s|POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$POSTGRES_PASSWORD|" .env
    chmod 600 .env

Файл .env не хранится в git, потому что содержит пароль базы данных.

5. Создать self-signed SSL-сертификат:

    mkdir -p ssl
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
      -keyout ssl/privkey.pem \
      -out ssl/fullchain.pem \
      -subj "/CN=devtest.local"
    chmod 600 ssl/privkey.pem

6. Запустить стенд:

    sudo docker compose up -d --build
    sudo docker compose ps

Ожидаемый результат:

    app            Up
    app-nginx      Up
    app-postgres   Up ... healthy

## Проверка приложения

Health endpoint:

    curl -k https://localhost/api/health

Ожидаемый ответ:

    ok

API endpoint:

    curl -k https://localhost/api/hello

Ожидаемый ответ:

    {"message":"hello","time":"..."}

Если стенд запущен в Multipass VM, проверить с основной машины можно так:

    VM_IP="$(multipass info devtest-final | awk '/IPv4:/ {print $2; exit}')"
    curl -k "https://$VM_IP/api/health"
    curl -k "https://$VM_IP/api/hello"

## Firewall

Настройка UFW:

    sudo ufw --force reset
    sudo ufw default deny incoming
    sudo ufw default allow outgoing
    sudo ufw allow 22/tcp
    sudo ufw allow 80/tcp
    sudo ufw allow 443/tcp
    sudo ufw --force enable
    sudo ufw status verbose

Должны быть разрешены только:

- 22/tcp;
- 80/tcp;
- 443/tcp.

## SSH hardening

Файл конфигурации:

    /etc/ssh/sshd_config.d/99-devops-hardening.conf

Содержимое:

    PasswordAuthentication no
    PermitRootLogin no
    PubkeyAuthentication yes

Применить настройки:

    sudo sshd -t
    sudo systemctl restart ssh

Проверить:

    sudo sshd -T | grep -E "^(passwordauthentication|permitrootlogin|pubkeyauthentication) "

Ожидаемый результат:

    permitrootlogin no
    pubkeyauthentication yes
    passwordauthentication no

Важно: на реальном VPS перед отключением password login нужно заранее добавить SSH-ключ.

## Backup Postgres

Скрипт находится здесь:

    scripts/backup-db.sh

Установка на сервер:

    sudo cp scripts/backup-db.sh /usr/local/bin/backup-db.sh
    sudo chmod 755 /usr/local/bin/backup-db.sh

Ручной запуск:

    sudo /usr/local/bin/backup-db.sh
    sudo ls -lh /var/backups/app/

Что делает скрипт:

- читает переменные из /opt/app/.env;
- запускает pg_dump внутри контейнера app-postgres;
- сжимает дамп через gzip;
- сохраняет backup в /var/backups/app;
- проверяет, что файл не пустой;
- удаляет backup-файлы старше 7 дней.

Пример cron для ежедневного backup в 03:00:

    0 3 * * * /usr/local/bin/backup-db.sh >> /var/log/backup-db.log 2>&1

## Restore из backup

Посмотреть backup-файлы:

    sudo ls -lh /var/backups/app/

Восстановить базу из конкретного файла:

    gunzip -c /var/backups/app/db-YYYYMMDD-HHMMSS.sql.gz | \
      sudo docker exec -i app-postgres psql -U app app

## Проверка после reboot

Перезагрузить сервер:

    sudo reboot

После перезагрузки проверить:

    cd /opt/app
    sudo docker compose ps
    curl -k https://localhost/api/health
    curl -k https://localhost/api/hello
    sudo /usr/local/bin/backup-db.sh

На тестовом стенде после reboot было проверено:

- Docker service: enabled, active;
- app: Up;
- app-nginx: Up;
- app-postgres: Up, healthy;
- /api/health: ok;
- /api/hello: JSON response;
- backup успешно создаёт .sql.gz файл;
- firewall активен;
- SSH password login выключен;
- root login выключен.

## Логи

Все сервисы:

    cd /opt/app
    sudo docker compose logs

Только nginx:

    sudo docker compose logs nginx

Только приложение:

    sudo docker compose logs app

Только Postgres:

    sudo docker compose logs postgres

## CI

В репозитории настроен GitHub Actions workflow:

    .github/workflows/ci.yml

CI проверяет:

- docker compose config;
- синтаксис backup-скрипта через bash -n;
- backup-скрипт через shellcheck;
- nginx config через nginx -t.

## Реализованные бонусы

Сделаны дополнительные пункты:

- GitHub Actions CI;
- проверка docker compose config;
- проверка nginx config через nginx -t;
- shellcheck для backup-скрипта;
- nginx rate limiting для /api/.

## Troubleshooting

### /api/hello возвращает 502

Проверить контейнеры:

    cd /opt/app
    sudo docker compose ps

Проверить логи:

    sudo docker compose logs app
    sudo docker compose logs nginx

Частые причины:

- контейнер app не запущен;
- postgres ещё не стал healthy;
- неправильный DATABASE_URL;
- ошибка в proxy_pass в nginx config.

### Backup падает или создаёт пустой файл

Проверить .env:

    sudo cat /opt/app/.env

Проверить контейнер Postgres:

    cd /opt/app
    sudo docker compose ps postgres

Запустить backup вручную:

    sudo /usr/local/bin/backup-db.sh

В скрипте используется set -euo pipefail, поэтому при ошибке он завершится сразу и не будет молча создавать невалидный backup.

### Контейнеры не поднялись после reboot

Проверить Docker:

    sudo systemctl is-enabled docker
    sudo systemctl is-active docker

Если Docker выключен:

    sudo systemctl enable --now docker

Проверить контейнеры:

    cd /opt/app
    sudo docker compose ps

В docker-compose.yml используется restart: unless-stopped, поэтому контейнеры должны автоматически подняться после старта Docker.

## Почему такие решения

### Почему Postgres без внешнего порта

Postgres нужен только backend-приложению. Поэтому у postgres нет секции ports, и база недоступна снаружи.

### Почему app без внешнего порта

Внешний трафик должен идти через nginx. Поэтому app слушает 8080 только внутри Docker-сети.

### Почему restart: unless-stopped

Так контейнеры автоматически поднимаются после reboot, но не запускаются насильно, если администратор остановил их вручную.

### Почему depends_on с service_healthy

Приложение должно стартовать после того, как Postgres реально готов принимать подключения.

### Почему self-signed SSL

Стенд развёрнут в локальной VM без публичного домена. Для Lets Encrypt нужен публичный домен, поэтому здесь используется самоподписанный сертификат.

## Что можно добавить позже

Если бы было больше времени, я бы добавил:

- fail2ban для защиты SSH от brute force;
- автоматическую проверку восстановления backup;
- мониторинг через Netdata или Prometheus/node-exporter;
- Ansible playbook для полностью автоматического деплоя.
