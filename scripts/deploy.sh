#!/usr/bin/env bash
# Доставка статического ресурса на devops-vm
# Использование: scripts/deploy.sh [--dry-run]
set -euo pipefail

REMOTE="devops"                  # псевдоним из ~/.ssh/config (ПР № 5, шаг 1.6)
REMOTE_DIR="/var/www/devops-site"
SITE_URL="${SITE_URL:-https://devops.local}"
CA_CERT="${HOME}/devops.crt"

TOP="$(git rev-parse --show-toplevel)"
# rsync трактует "D:/..." как удалённый хост, поэтому при наличии cygpath переводим путь в POSIX-вид
if command -v cygpath > /dev/null 2>&1; then TOP="$(cygpath -u "${TOP}")"; fi
LOCAL_DIR="${TOP}/site/"

# 1. Разбор аргумента --dry-run
DRY_RUN=""
case "${1:-}" in
    "")        ;;
    --dry-run) DRY_RUN="--dry-run" ;;
    *)         echo "Использование: $0 [--dry-run]" >&2; exit 2 ;;
esac

# 2. Проверки по требованиям 4 и 5
if [[ ! -f "${LOCAL_DIR}index.html" ]]; then
    echo "Ошибка: файл site/index.html отсутствует, доставка отменена" >&2
    exit 1
fi
if [[ -n "$(git -C "${TOP}" status --porcelain --untracked-files=no)" ]]; then
    echo "Ошибка: в репозитории есть незафиксированные изменения, доставка отменена" >&2
    exit 1
fi

# 3. Синхронизация каталога ${LOCAL_DIR} на ${REMOTE}:${REMOTE_DIR} (одно SSH-соединение)
rsync -avz --delete --chmod=D755,F644 ${DRY_RUN} \
    -e "ssh -o BatchMode=yes -o ConnectTimeout=5" \
    "${LOCAL_DIR}" "${REMOTE}:${REMOTE_DIR}/"

# 4. При --dry-run — завершение с кодом 0 без проверки доступности
if [[ -n "${DRY_RUN}" ]]; then
    echo "Пробный запуск завершён, сервер не изменён"
    exit 0
fi

# 5. Проверка доступности ${SITE_URL} (сертификат проверяется, без -k)
if ! curl -fsS --max-time 10 --cacert "${CA_CERT}" -o /dev/null "${SITE_URL}/"; then
    echo "Ошибка: ${SITE_URL} недоступен после доставки" >&2
    exit 1
fi

echo "Доставлен коммит $(git -C "${TOP}" rev-parse --short HEAD)"
