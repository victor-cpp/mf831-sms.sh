#!/usr/bin/env bash
#
# mf831-sms.sh — Чтение и отправка SMS через веб-API модема ZTE MF831 (8810FT совместимый).
#
#   чтение:  GET  /goform/goform_get_cmd_process?cmd=sms_data_total&...
#   статус:  GET  /goform/goform_get_cmd_process?cmd=sms_capacity_info
#   прочит.: POST /goform/goform_set_cmd_process  (goformId=SET_MSG_READ)
#   удалить: POST /goform/goform_set_cmd_process  (goformId=DELETE_SMS)
#
#   Отправка:
#   POST /goform/goform_set_cmd_process
#        goformId=SEND_SMS
#        Number=<номер>
#        sms_time=<YY;MM;DD;HH;MM;SS;±TZ>
#        MessageBody=<текст в UCS-2BE, HEX>
#        ID=-1
#        encode_type=UNICODE
#
# Зависимости: bash, curl, iconv, python3, coreutils.

set -euo pipefail

MODEM_HOST="${MODEM_HOST:-192.168.1.1}"
BASE_URL="${MODEM_URL:-http://${MODEM_HOST}}"
TIMEOUT="${MODEM_TIMEOUT:-10}"
PASSWORD="${MODEM_PASSWORD:-}"

BASE_URL="${BASE_URL%/}"
COOKIE_JAR="$(mktemp "${TMPDIR:-/tmp}/mts-sms-cookies.XXXXXX")"

AUTH_DONE=0
AD_VALUE=""
JSON_MODE=0
INSECURE=0

cleanup() {
    rm -f "$COOKIE_JAR"
}
trap cleanup EXIT INT TERM

die() {
    printf 'Ошибка: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Использование:
  mf831-sms.sh [опции] <команда> [аргументы]

Команды:
  list [--unread|--read|--sent|--all] [--limit N] [--json]
      Показать SMS. По умолчанию — все сообщения.
  send <номер> <текст>
      Отправить SMS.
  mark-read <id> [id...]
      Отметить SMS прочитанными.
  delete <id> [id...]
      Удалить SMS.
  capacity
      Показать заполненность хранилища SMS.

Опции:
  -H, --host <адрес>       IP или хост модема (по умолчанию 192.168.1.1)
  -u, --url <URL>          Полный URL модема, например https://192.168.1.1
  -p, --password <пароль>  Пароль веб-интерфейса, если модем требует вход
  -k, --insecure           Не проверять TLS-сертификат (для HTTPS)
  -t, --timeout <сек>      Таймаут HTTP-запроса (по умолчанию 10)
      --json               Показать сырой ответ API в JSON
  -h, --help               Показать эту справку

Переменные окружения:
  MODEM_HOST, MODEM_URL, MODEM_PASSWORD, MODEM_TIMEOUT

Примеры:
  ./mf831-sms.sh list
  ./mf831-sms.sh list --unread
  ./mf831-sms.sh send +79123456789 "Привет из терминала"
  ./mf831-sms.sh mark-read 12 15
  ./mf831-sms.sh delete 12
  ./mf831-sms.sh capacity
  ./mf831-sms.sh -H 192.168.0.1 -p admin list
EOF
}

check_deps() {
    local bin
    for bin in curl iconv python3 od mktemp base64 md5sum; do
        command -v "$bin" >/dev/null 2>&1 || die "не найдена программа '$bin'"
    done
}

do_curl() {
    local -a tls_args=()
    [ "$INSECURE" -eq 1 ] && tls_args=(-k)
    curl -sS --compressed \
        --connect-timeout "$TIMEOUT" \
        --max-time "$TIMEOUT" \
        "${tls_args[@]}" \
        -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
        -H "Referer: ${BASE_URL}/index.html" \
        -H "X-Requested-With: XMLHttpRequest" \
        "$@"
}

# Низкоуровневые запросы: не вызывают ensure_login (иначе будет рекурсия).
api_get_raw() {
    local endpoint="$1"
    shift
    local response
    if ! response="$(do_curl -G "${BASE_URL}${endpoint}" "$@")"; then
        die "не удалось подключиться к модему ${BASE_URL}"
    fi
    printf '%s' "$response"
}

api_post_raw() {
    local endpoint="$1"
    shift
    local response
    if ! response="$(do_curl -X POST "${BASE_URL}${endpoint}" "$@")"; then
        die "не удалось подключиться к модему ${BASE_URL}"
    fi
    printf '%s' "$response"
}

api_get() {
    ensure_login
    api_get_raw "$@"
}

json_field() {
    local key="$1"
    python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    value = data.get(sys.argv[1], "")
except Exception:
    sys.exit(1)
if isinstance(value, bool):
    print("true" if value else "false")
elif isinstance(value, (dict, list)):
    print(json.dumps(value, ensure_ascii=False))
else:
    print(value)
' "$key" 2>/dev/null || true
}

# Для прошивок, где включён вход в веб-интерфейс. На 8810FT обычно не нужен.
ensure_login() {
    [ -z "$PASSWORD" ] && return 0
    [ "$AUTH_DONE" -eq 1 ] && return 0

    local password_b64 response result
    password_b64="$(printf '%s' "$PASSWORD" | base64 | tr -d '\n')"
    response="$(api_post_raw "/goform/goform_set_cmd_process" \
        --data-urlencode "isTest=false" \
        --data-urlencode "goformId=LOGIN" \
        --data-urlencode "password=${password_b64}")"

    result="$(printf '%s' "$response" | json_field result)"
    if [ "$result" != "0" ] && [ "$result" != "success" ]; then
        die "не удалось войти в веб-интерфейс модема. Ответ: ${response}"
    fi

    AUTH_DONE=1
    # AD нужен не на всех прошивках. Если получить его не удалось,
    # пробуем работать без него — многие модемы это допускают.
    if AD_VALUE="$(compute_ad)"; then
        :
    else
        AD_VALUE=""
    fi
}

# AD = md5(md5(cr_version + wa_inner_version) + RD) — используется ZTE
# в запросах goform_set_cmd_process на прошивках с авторизацией.
compute_ad() {
    local version_json rd_json version rd version_hash
    version_json="$(api_get_raw "/goform/goform_get_cmd_process" \
        --data-urlencode "isTest=false" \
        --data-urlencode "cmd=cr_version,wa_inner_version" \
        --data-urlencode "multi_data=1")"
    rd_json="$(api_get_raw "/goform/goform_get_cmd_process" \
        --data-urlencode "isTest=false" \
        --data-urlencode "cmd=RD")"

    version="$(printf '%s' "$version_json" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
print((data.get("cr_version") or "") + (data.get("wa_inner_version") or ""))
' 2>/dev/null || true)"

    rd="$(printf '%s' "$rd_json" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
print(data.get("RD") or "")
' 2>/dev/null || true)"

    [ -n "$version" ] && [ -n "$rd" ] || return 1

    version_hash="$(printf '%s' "$version" | md5sum | cut -d' ' -f1)"
    printf '%s%s' "$version_hash" "$rd" | md5sum | cut -d' ' -f1
}

# Часовой пояс в формате ZTE: +3, -5, +5.5, +5.75 и т.п.
timezone_offset() {
    local tz sign hours minutes
    tz="$(date +%z)"
    sign="${tz:0:1}"
    hours="$((10#${tz:1:2}))"
    minutes="$((10#${tz:3:2}))"

    if [ "$hours" -eq 0 ] && [ "$minutes" -eq 0 ]; then
        printf '0'
    elif [ "$minutes" -eq 0 ]; then
        printf '%s%d' "$sign" "$hours"
    elif [ "$minutes" -eq 30 ]; then
        printf '%s%d.5' "$sign" "$hours"
    elif [ "$minutes" -eq 45 ]; then
        printf '%s%d.75' "$sign" "$hours"
    else
        printf '%s%d.%d' "$sign" "$hours" "$minutes"
    fi
}

# Текст -> UCS-2BE HEX (как MessageBody в ZTE).
encode_message() {
    printf '%s' "$1" | iconv -f UTF-8 -t UTF-16BE | od -An -v -tx1 \
        | tr -d ' \n' | tr 'a-f' 'A-F'
}

print_list() {
    python3 -c '
import json, sys

def decode_content(value):
    if not value:
        return ""
    value = value.strip()
    if len(value) % 4 == 0 and all(c in "0123456789abcdefABCDEF" for c in value):
        try:
            return bytes.fromhex(value).decode("utf-16-be")
        except Exception:
            return value
    return value

def format_date(value):
    value = (value or "").strip()
    parts = [part.strip() for part in value.split(",")]
    if len(parts) >= 6 and all(part.isdigit() for part in parts[:6]):
        return "20%s-%s-%s %s:%s:%s" % tuple(parts[:6])
    return value

try:
    data = json.load(sys.stdin)
except Exception as exc:
    print("Не удалось разобрать JSON: %s" % exc, file=sys.stderr)
    sys.exit(1)

messages = data.get("messages") or []
if not messages:
    print("Сообщений нет.")
    sys.exit(0)

labels = {
    "0": "прочитано",
    "1": "НЕ ПРОЧИТАНО",
    "2": "отправлено",
    "3": "ошибка",
    "4": "черновик",
}
for message in messages:
    tag = str(message.get("tag", ""))
    label = labels.get(tag, "tag=%s" % tag)
    print("#%s  [%s]  %s  %s" % (
        message.get("id", "?"),
        label,
        format_date(message.get("date", "")),
        message.get("number", ""),
    ))
    content = decode_content(message.get("content", "")).replace("\x00", "")
    for line in content.splitlines() or [""]:
        print("    " + line)
    print()
'
}

cmd_list() {
    local tag=10
    local limit=500
    local json_mode="$JSON_MODE"

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --unread) tag=1; shift ;;
            --read) tag=0; shift ;;
            --sent) tag=2; shift ;;
            --all) tag=10; shift ;;
            --json) json_mode=1; shift ;;
            --limit)
                [ "$#" -ge 2 ] || die "после --limit нужно указать число"
                limit="$2"
                shift 2
                ;;
            *) die "неизвестный параметр команды list: $1" ;;
        esac
    done

    [[ "$limit" =~ ^[0-9]+$ ]] || die "--limit должен быть числом"
    [ "$limit" -gt 0 ] || die "--limit должен быть больше нуля"

    local response
    response="$(api_get "/goform/goform_get_cmd_process" \
        --data-urlencode "cmd=sms_data_total" \
        --data-urlencode "page=0" \
        --data-urlencode "data_per_page=${limit}" \
        --data-urlencode "mem_store=1" \
        --data-urlencode "tags=${tag}" \
        --data-urlencode "order_by=order by id desc" \
        --data-urlencode "_=$(date +%s%3N)")"

    if [ "$json_mode" -eq 1 ]; then
        printf '%s' "$response" | python3 -m json.tool
    else
        printf '%s' "$response" | print_list
    fi
}

cmd_send() {
    [ "$#" -ge 2 ] || die "использование: mf831-sms.sh send <номер> <текст>"

    local number="$1"
    shift
    local text="$*"
    local sms_time body_hex response result

    number="${number//[^0-9+]/}"
    [[ "$number" =~ ^\+?[0-9]+$ ]] || die "некорректный номер получателя"
    [ -n "$text" ] || die "пустой текст сообщения"

    # ZTE ждёт локальное время модема: YY;MM;DD;HH;MM;SS;±TZ
    sms_time="$(date +'%y;%m;%d;%H;%M;%S;')$(timezone_offset)"
    body_hex="$(encode_message "$text")"

    local -a data=(
        --data-urlencode "isTest=false"
        --data-urlencode "goformId=SEND_SMS"
        --data-urlencode "notCallback=true"
        --data-urlencode "Number=${number}"
        --data-urlencode "sms_time=${sms_time}"
        --data-urlencode "MessageBody=${body_hex}"
        --data-urlencode "ID=-1"
        --data-urlencode "encode_type=UNICODE"
    )

    ensure_login
    [ -n "$AD_VALUE" ] && data+=(--data-urlencode "AD=${AD_VALUE}")

    response="$(api_post_raw "/goform/goform_set_cmd_process" "${data[@]}")"
    result="$(printf '%s' "$response" | json_field result)"

    if [ "$result" = "success" ]; then
        printf 'SMS отправлено на %s\n' "$number"
    else
        printf 'Ответ модема: %s\n' "$response" >&2
        return 1
    fi
}

build_ids() {
    local ids=""
    local id
    for id in "$@"; do
        [[ "$id" =~ ^[0-9]+$ ]] || die "некорректный id SMS: $id"
        ids+="${id};"
    done
    printf '%s' "$ids"
}

cmd_mark_read() {
    [ "$#" -ge 1 ] || die "использование: mf831-sms.sh mark-read <id> [id...]"

    local ids response result
    ids="$(build_ids "$@")"

    local -a data=(
        --data-urlencode "isTest=false"
        --data-urlencode "goformId=SET_MSG_READ"
        --data-urlencode "msg_id=${ids}"
        --data-urlencode "tag=0"
    )

    ensure_login
    [ -n "$AD_VALUE" ] && data+=(--data-urlencode "AD=${AD_VALUE}")

    response="$(api_post_raw "/goform/goform_set_cmd_process" "${data[@]}")"
    result="$(printf '%s' "$response" | json_field result)"

    if [ "$result" = "success" ]; then
        printf 'Отмечено прочитанным: %s\n' "${ids%;}"
    else
        printf 'Ответ модема: %s\n' "$response" >&2
        return 1
    fi
}

cmd_delete() {
    [ "$#" -ge 1 ] || die "использование: mf831-sms.sh delete <id> [id...]"

    local ids response result
    ids="$(build_ids "$@")"

    local -a data=(
        --data-urlencode "isTest=false"
        --data-urlencode "goformId=DELETE_SMS"
        --data-urlencode "msg_id=${ids}"
        --data-urlencode "notCallback=true"
    )

    ensure_login
    [ -n "$AD_VALUE" ] && data+=(--data-urlencode "AD=${AD_VALUE}")

    response="$(api_post_raw "/goform/goform_set_cmd_process" "${data[@]}")"
    result="$(printf '%s' "$response" | json_field result)"

    if [ "$result" = "success" ]; then
        printf 'Удалено SMS: %s\n' "${ids%;}"
    else
        printf 'Ответ модема: %s\n' "$response" >&2
        return 1
    fi
}

cmd_capacity() {
    local response
    response="$(api_get "/goform/goform_get_cmd_process" \
        --data-urlencode "cmd=sms_capacity_info" \
        --data-urlencode "_=$(date +%s%3N)")"
    printf '%s' "$response" | python3 -m json.tool
}

COMMAND=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        -H|--host)
            [ "$#" -ge 2 ] || die "после --host нужен адрес"
            MODEM_HOST="$2"
            BASE_URL="http://${MODEM_HOST}"
            shift 2
            ;;
        -u|--url)
            [ "$#" -ge 2 ] || die "после --url нужен URL"
            BASE_URL="${2%/}"
            shift 2
            ;;
        -p|--password)
            [ "$#" -ge 2 ] || die "после --password нужен пароль"
            PASSWORD="$2"
            shift 2
            ;;
        -k|--insecure) INSECURE=1; shift ;;
        -t|--timeout)
            [ "$#" -ge 2 ] || die "после --timeout нужно число секунд"
            TIMEOUT="$2"
            shift 2
            ;;
        --json) JSON_MODE=1; shift ;;
        -*) die "неизвестная опция: $1 (см. --help)" ;;
        *) COMMAND="$1"; shift; break ;;
    esac
done

[ -n "$COMMAND" ] || { usage; exit 1; }
[[ "$TIMEOUT" =~ ^[0-9]+$ ]] || die "--timeout должен быть числом"

check_deps

case "$COMMAND" in
    list|ls) cmd_list "$@" ;;
    send) cmd_send "$@" ;;
    mark-read|read) cmd_mark_read "$@" ;;
    delete|del|rm) cmd_delete "$@" ;;
    capacity|cap) cmd_capacity "$@" ;;
    *) die "неизвестная команда: ${COMMAND} (см. --help)" ;;
esac
