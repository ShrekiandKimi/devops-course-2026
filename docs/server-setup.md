# Конфигурация виртуальной машины devops-vm

## 1. Параметры машины
- Гипервизор: VirtualBox 7.2.6, имя машины `devops-vm`, тип Linux / Ubuntu (64-bit).
- ОС: Ubuntu Server 24.04.5 LTS (не minimized), образ `ubuntu-24.04.5-live-server-amd64.iso`.
- Память 2048 МБ, 2 ядра CPU, диск 25 ГБ (VDI, динамически расширяемый), разметка «весь диск».
- Имя узла `devops-vm`, FQDN `devops-vm.devops.local` (строка `127.0.1.1 devops-vm.devops.local devops-vm` добавлена в `/etc/hosts` вручную, так как в системе её не было).

## 2. Сетевые интерфейсы
| Адаптер | Тип | Интерфейс | Адрес | Назначение |
|---|---|---|---|---|
| 1 | NAT | enp0s3 | 10.0.2.15/24 | выход в Интернет (пакеты), проброс SSH |
| 2 | Host-only (VirtualBox Host-Only Ethernet Adapter, хост 192.168.56.1) | enp0s8 | 192.168.56.101/24 (DHCP) | доступ с хоста к веб-серверу и SSH |

## 3. Правило проброса портов
Адаптер 1 (NAT), правило `ssh`, TCP: хост `127.0.0.1:2222` -> гость `:2222`
(изначально гостевой порт был 22, после смены порта sshd изменён на 2222).

## 4. Учётные записи
| Имя | Группы | Аутентификация |
|---|---|---|
| student | student, sudo, users | пароль (по SSH запрещён директивой `AllowUsers devops`; вход только с консоли) |
| devops | devops, sudo, users | только SSH-ключ ed25519 (`~/.ssh/devops_vm` на хосте), `sudo` по паролю |
| root | — | пароль заблокирован (`passwd -l root`), вход по SSH запрещён |

Права: `~/.ssh` 700, `~/.ssh/authorized_keys` 600. Запись клиента на хосте: `~/.ssh/config`, `Host devops`.

## 5. Служба SSH
- Файл конфигурации: `/etc/ssh/sshd_config.d/99-hardening.conf` (основной `sshd_config` не изменён, копия — `sshd_config.backup`).
- Директивы: `Port 2222`, `PermitRootLogin no`, `PasswordAuthentication no`, `PubkeyAuthentication yes`, `PermitEmptyPasswords no`, `MaxAuthTries 3`, `LoginGraceTime 30`, `AllowUsers devops`, `X11Forwarding no`, `ClientAliveInterval 300`, `ClientAliveCountMax 2`.
- Сокетная активация отключена: `systemctl disable --now ssh.socket`, `systemctl enable --now ssh.service`, затем `systemctl restart ssh` (иначе порт остаётся 22).
- Проверка: `sudo sshd -t`, действующие значения — `sudo sshd -T`, порт — `sudo ss -tlnp | grep sshd`.

## 6. Правила межсетевого экрана (ufw)
- Политики: `default deny incoming`, `default allow outgoing`; логирование `medium`.
- Правила (создаются до `ufw enable`):
  - `2222/tcp` — `LIMIT` (комментарий `SSH rate-limited`)
  - `80/tcp` — ALLOW (`HTTP`)
  - `443/tcp` — ALLOW (`HTTPS`)
- Порядок: сначала правила, затем `yes | sudo ufw enable`.

## 7. Снимки состояния
| Имя | Состояние |
|---|---|
| 01-clean-install | чистая установка Ubuntu Server 24.04.5, обновлена (`apt update && apt upgrade`) |
| 02-keys-configured | пользователь `devops`, вход по ключу, `~/.ssh/config` |
| 03-ssh-hardened | усиление защиты sshd, порт 2222 |

## 8. Веб-сервер
- Пакет: `nginx` (apt, Ubuntu 24.04 repo, nginx/1.24.0), служба включена в автозапуск.
- Конфигурация ресурса: `/etc/nginx/sites-available/devops-site`, активирована ссылкой в `/etc/nginx/sites-enabled/`; стандартный сайт отключён (`rm /etc/nginx/sites-enabled/default`). Два блока `server`: порт 80 — `return 301 https://$host$request_uri;`, порт 443 `ssl` — `server_name devops.local`, `ssl_protocols TLSv1.2 TLSv1.3`, `root /var/www/devops-site`, `error_page 404 /404.html`. Журналы: `/var/log/nginx/devops-site.access.log` и `devops-site.error.log`.
- Каталог ресурса: `/var/www/devops-site`, владелец `devops:devops`, каталоги 755, файлы 644 (доставка `rsync --chmod=D755,F644`).
- Сертификат: `/etc/ssl/certs/devops.crt` (644, root), ключ `/etc/ssl/private/devops.key` (600, root).
- Команда: `sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout /etc/ssl/private/devops.key -out /etc/ssl/certs/devops.crt -subj "/CN=devops.local" -addext "subjectAltName=DNS:devops.local"`; срок действия 365 дней.
- Применение конфигурации: `sudo nginx -t && sudo systemctl reload nginx` (не `restart`). HSTS не включается.
- Доставка содержимого: `scripts/deploy.sh [--dry-run]`.

## 9. Контейнеризация
- Docker Engine 29.9.2 из официального репозитория `download.docker.com` (пакеты `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin`), `docker.io` не используется. Группа `docker`: `devops` (имеет sudo).
- Проект: `~/app` (на сервере), доставка `rsync -avz --delete --exclude=.env app/ devops:app/`. Образ `devops-app:1.0` (python:3.12-slim, пользователь `app`, CMD в exec-форме).
- Файл `~/app/.env`: права 600, владелец `devops`, пароль PostgreSQL сгенерирован на сервере (`openssl rand -hex 16`); в репозиторий не добавляется (`.gitignore`, `.dockerignore`), шаблон — `app/.env.example`.
- Порты: приложение `127.0.0.1:5000->5000` (только loopback), PostgreSQL не публикуется (доступен приложению по имени `db` в сети проекта `app_backend`). Docker публикует порты в обход ufw, поэтому публикация на `0.0.0.0` запрещена.
- Именованный том: `app_db_data` (`/var/lib/postgresql/data`), сохраняется при `docker compose down`, удаляется только `down -v`.
- Обратный прокси: в HTTPS-блоке `devops-site` `location /app/ { proxy_pass http://127.0.0.1:5000/; }` с заголовками `Host`, `X-Real-IP`, `X-Forwarded-For`, `X-Forwarded-Proto`; статический ресурс `/` сохранён.
