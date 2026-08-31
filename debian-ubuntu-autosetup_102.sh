#!/usr/bin/env bash
# Interactive baseline configuration for supported Debian and Ubuntu releases.
# Generated for administrators who want conservative, auditable changes.

set -Eeuo pipefail
shopt -s nullglob

SCRIPT_NAME="${0##*/}"
SCRIPT_VERSION="1.0.2"
DRY_RUN=0
AUDIT_ONLY=0
ALLOW_UNSUPPORTED=0
LOG_FILE=""
BACKUP_DIR=""
RUN_ID="$(date +%Y%m%d-%H%M%S)"
OS_ID=""
OS_VERSION_ID=""
OS_CODENAME=""
OS_PRETTY_NAME=""
OS_SUPPORTED=0
RUNNING_OVER_SSH=0
IS_CONTAINER=0
HAS_SYSTEMD=0
NETWORK_BACKEND="unknown"
DEFAULT_IFACE=""
SSH_PORT="22"
APT_UPDATED=0
PROXY_URL=""

declare -a RESULTS_OK=()
declare -a RESULTS_SKIP=()
declare -a RESULTS_WARN=()
BACKED_UP_PATHS=""

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'
else
  C_RESET=""
  C_RED=""
  C_GREEN=""
  C_YELLOW=""
  C_BLUE=""
fi

usage() {
  cat <<EOF
Использование: sudo ./${SCRIPT_NAME} [параметры]

Параметры:
  --dry-run              Показать изменения, не применяя их
  --audit-only           Выполнить только аудит системы и связности
  --allow-unsupported    Разрешить запуск на версии вне матрицы поддержки
  --log-file PATH        Записать журнал в указанный файл
  -h, --help             Показать эту справку

Поддерживаемые релизы на дату выпуска скрипта:
  Debian 13 (trixie), Debian 12 (bookworm LTS)
  Ubuntu 26.04 LTS (resolute), 24.04 LTS (noble), 22.04 LTS (jammy)
EOF
}

info() { printf '%s[INFO]%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok() { printf '%s[ OK ]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
error() { printf '%s[ERR ]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die() { error "$*"; exit 1; }

record_ok() { RESULTS_OK+=("$*"); }
record_skip() { RESULTS_SKIP+=("$*"); }
record_warn() { RESULTS_WARN+=("$*"); }

on_error() {
  local line="$1" command="$2" code="$3"
  error "Неожиданная ошибка (код ${code}) в строке ${line}: ${command}"
  error "Журнал: ${LOG_FILE:-не создан}"
}
trap 'on_error "$LINENO" "$BASH_COMMAND" "$?"' ERR

parse_args() {
  while (($#)); do
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      --audit-only) AUDIT_ONLY=1 ;;
      --allow-unsupported) ALLOW_UNSUPPORTED=1 ;;
      --log-file)
        shift
        (($#)) || die "После --log-file требуется путь"
        LOG_FILE="$1"
        ;;
      -h|--help) usage; exit 0 ;;
      *) die "Неизвестный параметр: $1" ;;
    esac
    shift
  done
}

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Скрипт необходимо запускать от root: sudo ./${SCRIPT_NAME}"
}

require_interactive_terminal() {
  if ((AUDIT_ONLY == 0)) && [[ ! -r /dev/tty ]]; then
    die "Для интерактивной настройки требуется терминал. Для проверки используйте --audit-only."
  fi
}

init_runtime() {
  if [[ -z "$LOG_FILE" ]]; then
    if ((DRY_RUN)); then
      LOG_FILE="/tmp/debian-ubuntu-autosetup-${RUN_ID}.log"
    else
      install -d -m 0750 /var/log/debian-ubuntu-autosetup
      LOG_FILE="/var/log/debian-ubuntu-autosetup/run-${RUN_ID}.log"
    fi
  else
    install -d -m 0750 "$(dirname "$LOG_FILE")"
  fi
  touch "$LOG_FILE"
  chmod 0600 "$LOG_FILE"
  exec > >(tee -a "$LOG_FILE") 2>&1

  if command -v flock >/dev/null 2>&1; then
    exec 9>/run/lock/debian-ubuntu-autosetup.lock
    flock -n 9 || die "Уже запущен другой экземпляр скрипта"
  fi
}

ensure_backup_dir() {
  [[ -n "$BACKUP_DIR" ]] && return 0
  BACKUP_DIR="/var/backups/debian-ubuntu-autosetup/${RUN_ID}"
  if ((DRY_RUN)); then
    info "[dry-run] Будет создан каталог резервных копий: $BACKUP_DIR"
  else
    install -d -m 0700 "$BACKUP_DIR"
  fi
}

backup_path() {
  local path="$1" relative destination
  [[ -e "$path" || -L "$path" ]] || return 0
  printf '%s\n' "$BACKED_UP_PATHS" | grep -Fxq -- "$path" && return 0
  BACKED_UP_PATHS+=$'\n'"$path"
  ensure_backup_dir
  relative="${path#/}"
  destination="$BACKUP_DIR/$relative"
  if ((DRY_RUN)); then
    info "[dry-run] Резервная копия: $path -> $destination"
    return 0
  fi
  install -d -m 0700 "$(dirname "$destination")"
  cp -a -- "$path" "$destination"
}

shell_quote_command() {
  local arg output=""
  for arg in "$@"; do
    printf -v output '%s%q ' "$output" "$arg"
  done
  printf '%s' "${output% }"
}

run() {
  if ((DRY_RUN)); then
    printf '[dry-run] '
    shell_quote_command "$@"
    printf '\n'
  else
    "$@"
  fi
}

write_file() {
  local target="$1" mode="$2" content="$3" temporary
  backup_path "$target"
  if ((DRY_RUN)); then
    info "[dry-run] Будет записан файл $target (права $mode)"
    return 0
  fi
  install -d -m 0755 "$(dirname "$target")"
  temporary="$(mktemp "$(dirname "$target")/.autosetup.XXXXXX")"
  printf '%s' "$content" >"$temporary"
  chmod "$mode" "$temporary"
  chown root:root "$temporary"
  mv -f -- "$temporary" "$target"
}

ask_yes_no() {
  local prompt="$1" default="${2:-n}" answer suffix
  if [[ "$default" == "y" ]]; then suffix="[Y/n]"; else suffix="[y/N]"; fi
  while true; do
    read -r -p "$prompt $suffix " answer </dev/tty || return 1
    answer="${answer:-$default}"
    case "$answer" in
      y|Y|yes|YES|Yes|д|Д|да|Да|ДА) return 0 ;;
      n|N|no|NO|No|н|Н|нет|Нет|НЕТ) return 1 ;;
      *) warn "Введите y/yes/да или n/no/нет" ;;
    esac
  done
}

read_value() {
  local prompt="$1" default="${2:-}" value
  if [[ -n "$default" ]]; then
    read -r -p "$prompt [$default]: " value </dev/tty
    printf '%s' "${value:-$default}"
  else
    read -r -p "$prompt: " value </dev/tty
    printf '%s' "$value"
  fi
}

confirm_phrase() {
  local prompt="$1" phrase="$2" answer
  warn "$prompt"
  read -r -p "Для подтверждения введите: $phrase: " answer </dev/tty
  [[ "$answer" == "$phrase" ]]
}

choose_one() {
  local prompt="$1" max="$2" default="$3" answer
  while true; do
    answer="$(read_value "$prompt" "$default")"
    [[ "$answer" =~ ^[0-9]+$ ]] && ((answer >= 1 && answer <= max)) && { printf '%s' "$answer"; return 0; }
    warn "Введите число от 1 до $max"
  done
}

detect_os() {
  local architecture
  [[ -r /etc/os-release ]] || die "Файл /etc/os-release отсутствует"
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-}"
  OS_VERSION_ID="${VERSION_ID:-}"
  OS_CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
  OS_PRETTY_NAME="${PRETTY_NAME:-$OS_ID $OS_VERSION_ID}"

  case "$OS_ID:$OS_CODENAME" in
    debian:trixie|debian:bookworm|ubuntu:resolute|ubuntu:noble|ubuntu:jammy)
      OS_SUPPORTED=1
      ;;
    *) OS_SUPPORTED=0 ;;
  esac

  case "$OS_ID" in
    debian|ubuntu) ;;
    *) die "Поддерживаются только Debian и Ubuntu. Обнаружено: ${OS_ID:-неизвестно}" ;;
  esac

  [[ -n "$OS_CODENAME" ]] || die "Не удалось определить кодовое имя релиза"
  if [[ "$OS_ID:$OS_CODENAME" == "debian:bookworm" ]]; then
    architecture="$(dpkg --print-architecture 2>/dev/null || true)"
    case "$architecture" in
      amd64|arm64|armhf|i386|ppc64el) ;;
      *)
        OS_SUPPORTED=0
        warn "Debian 12 LTS не заявляет поддержку архитектуры ${architecture:-неизвестно}"
        ;;
    esac
  fi
  if ((OS_SUPPORTED == 0)); then
    warn "Версия $OS_PRETTY_NAME не входит в проверенную матрицу поддержки"
    if ((ALLOW_UNSUPPORTED == 0)); then
      die "Используйте поддерживаемый релиз или явно передайте --allow-unsupported"
    fi
    record_warn "Запуск на неподдерживаемом релизе: $OS_PRETTY_NAME"
  fi

  if [[ "$OS_ID:$OS_CODENAME" == "debian:bookworm" ]]; then
    warn "Debian 12 работает в режиме LTS до 30 июня 2028 года; Debian 13 является stable"
  elif [[ "$OS_ID:$OS_CODENAME" == "ubuntu:jammy" ]]; then
    warn "Стандартная поддержка Ubuntu 22.04 LTS завершается в 2027 году"
  fi
}

detect_environment() {
  [[ -n "${SSH_CONNECTION:-}" || -n "${SSH_CLIENT:-}" ]] && RUNNING_OVER_SSH=1
  if command -v systemd-detect-virt >/dev/null 2>&1 && systemd-detect-virt --container --quiet; then
    IS_CONTAINER=1
  fi
  [[ "$(ps -p 1 -o comm= 2>/dev/null | xargs || true)" == "systemd" ]] && HAS_SYSTEMD=1
  DEFAULT_IFACE="$(ip -o -4 route show to default 2>/dev/null | awk 'NR==1 {print $5}')"
  NETWORK_BACKEND="$(detect_network_backend)"
  if command -v sshd >/dev/null 2>&1; then
    SSH_PORT="$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2; exit}')"
    SSH_PORT="${SSH_PORT:-22}"
  fi
}

detect_network_backend() {
  local iface="${DEFAULT_IFACE:-}"
  if [[ "$OS_ID" == "ubuntu" ]] && command -v netplan >/dev/null 2>&1 && compgen -G '/etc/netplan/*.yaml' >/dev/null; then
    printf 'netplan'
    return
  fi
  if [[ -n "$iface" ]] && command -v nmcli >/dev/null 2>&1 && nmcli -t -f DEVICE,STATE device 2>/dev/null | grep -q "^${iface}:connected"; then
    printf 'networkmanager'
    return
  fi
  if command -v networkctl >/dev/null 2>&1 && systemctl is-active --quiet systemd-networkd 2>/dev/null; then
    if networkctl status "$iface" 2>/dev/null | grep -qE 'State:.*(routable|configured)'; then
      printf 'systemd-networkd'
      return
    fi
  fi
  if [[ -r /etc/network/interfaces ]] || compgen -G '/etc/network/interfaces.d/*' >/dev/null; then
    printf 'ifupdown'
    return
  fi
  if command -v netplan >/dev/null 2>&1; then printf 'netplan'; return; fi
  printf 'unknown'
}

show_system_summary() {
  local architecture init_name
  architecture="$(dpkg --print-architecture 2>/dev/null || uname -m)"
  init_name="$(ps -p 1 -o comm= 2>/dev/null | xargs || true)"
  printf '\n=== Сведения о системе ===\n'
  printf 'ОС:                 %s\n' "$OS_PRETTY_NAME"
  printf 'Кодовое имя:        %s\n' "$OS_CODENAME"
  printf 'Архитектура:        %s\n' "$architecture"
  printf 'PID 1:              %s\n' "${init_name:-неизвестно}"
  printf 'Запуск через SSH:   %s\n' "$([[ $RUNNING_OVER_SSH -eq 1 ]] && echo да || echo нет)"
  printf 'Контейнер:          %s\n' "$([[ $IS_CONTAINER -eq 1 ]] && echo да || echo нет)"
  printf 'Сетевой backend:    %s\n' "$NETWORK_BACKEND"
  printf 'Основной интерфейс: %s\n' "${DEFAULT_IFACE:-не найден}"
  printf 'Текущий SSH-порт:   %s\n' "$SSH_PORT"
  printf 'Dry-run:            %s\n' "$([[ $DRY_RUN -eq 1 ]] && echo да || echo нет)"
  printf 'Журнал:             %s\n\n' "$LOG_FILE"

  if [[ "$init_name" != "systemd" ]]; then
    warn "PID 1 не systemd: управление службами, firewall и таймерами может быть недоступно"
    record_warn "Система запущена без systemd"
  fi
  if ((IS_CONTAINER)); then
    warn "Обнаружен контейнер: сетевые и firewall-этапы будут пропущены"
  fi
  if command -v cloud-init >/dev/null 2>&1; then
    warn "Обнаружен cloud-init. Он может перезаписать сеть и SSH при следующем запуске."
    record_warn "На системе присутствует cloud-init"
  fi
}

show_network_state() {
  printf '\n=== Текущее состояние сети ===\n'
  ip -brief address 2>/dev/null || true
  printf '\nМаршруты:\n'
  ip route show 2>/dev/null || true
  printf '\nDNS:\n'
  if command -v resolvectl >/dev/null 2>&1; then
    resolvectl status 2>/dev/null | sed -n '1,80p' || true
  else
    sed -n '1,40p' /etc/resolv.conf 2>/dev/null || true
  fi
}

test_connectivity() {
  local gateway="" dns_ok=0 https_ok=0
  printf '\n=== Проверка связности ===\n'
  gateway="$(ip -4 route show default 2>/dev/null | awk 'NR==1 {print $3}')"
  if [[ -n "$gateway" ]] && command -v ping >/dev/null 2>&1; then
    if ping -c 1 -W 2 "$gateway" >/dev/null 2>&1; then
      ok "Шлюз $gateway отвечает"
    else
      warn "Шлюз $gateway не ответил на ICMP; это не обязательно означает ошибку"
    fi
  else
    warn "Шлюз или команда ping недоступны"
  fi

  if getent ahosts deb.debian.org >/dev/null 2>&1; then
    ok "DNS-разрешение имён работает"
    dns_ok=1
  else
    error "DNS-разрешение deb.debian.org не работает"
  fi

  if command -v curl >/dev/null 2>&1; then
    local -a curl_command=(curl -fsSIL --connect-timeout 8 --max-time 15 https://deb.debian.org/)
    [[ -n "$PROXY_URL" ]] && curl_command=(curl -fsSIL --proxy "$PROXY_URL" --connect-timeout 8 --max-time 15 https://deb.debian.org/)
    if "${curl_command[@]}" >/dev/null 2>&1; then
      ok "HTTPS-доступ к зеркалу Debian работает"
      https_ok=1
    else
      error "Нет HTTPS-доступа к deb.debian.org"
    fi
  else
    warn "curl ещё не установлен; HTTPS будет проверен командой apt update"
  fi

  if ((dns_ok)) && { ((https_ok)) || ! command -v curl >/dev/null 2>&1; }; then
    record_ok "Базовая сетевая связность проверена"
    return 0
  fi
  record_warn "Проверка сетевой связности выявила проблемы"
  return 1
}

is_ipv4() {
  local ip="$1" IFS=. octets octet
  read -r -a octets <<<"$ip"
  [[ ${#octets[@]} -eq 4 ]] || return 1
  for octet in "${octets[@]}"; do
    [[ "$octet" =~ ^[0-9]{1,3}$ ]] || return 1
    ((10#$octet <= 255)) || return 1
  done
}

is_ipv4_cidr() {
  local value="$1" address prefix
  [[ "$value" == */* ]] || return 1
  address="${value%/*}"; prefix="${value#*/}"
  is_ipv4 "$address" && [[ "$prefix" =~ ^[0-9]+$ ]] && ((prefix >= 0 && prefix <= 32))
}

valid_interface() { [[ "$1" =~ ^[a-zA-Z0-9_.-]+$ ]] && [[ -e "/sys/class/net/$1" ]]; }
valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)); }

valid_ipv4_list() {
  local input="$1" item
  local -a values=()
  IFS=',' read -r -a values <<<"$input"
  ((${#values[@]})) || return 1
  for item in "${values[@]}"; do
    item="${item//[[:space:]]/}"
    is_ipv4 "$item" || return 1
  done
}

is_complex_interface() {
  local iface="$1" address_count
  [[ -d "/sys/class/net/$iface/bridge" || -d "/sys/class/net/$iface/bonding" || -d "/sys/class/net/$iface/wireless" || -L "/sys/class/net/$iface/master" ]] && return 0
  [[ "$iface" == *.* ]] && return 0
  address_count="$(ip -o -4 addr show dev "$iface" scope global 2>/dev/null | wc -l | tr -d '[:space:]')"
  ((address_count > 1)) && return 0
  return 1
}

select_interface() {
  local iface entry
  printf 'Доступные интерфейсы:\n'
  for entry in /sys/class/net/*; do
    iface="${entry##*/}"
    [[ "$iface" == "lo" ]] || printf '  - %s\n' "$iface"
  done
  while true; do
    iface="$(read_value "Интерфейс" "${DEFAULT_IFACE:-}")"
    valid_interface "$iface" && { printf '%s' "$iface"; return; }
    warn "Интерфейс не найден: $iface"
  done
}

collect_network_values() {
  local iface="$1" mode="$2" current_cidr current_gateway cidr gateway dns dhcp6
  current_cidr="$(ip -o -4 addr show dev "$iface" scope global 2>/dev/null | awk 'NR==1 {print $4}')"
  current_gateway="$(ip -4 route show default dev "$iface" 2>/dev/null | awk 'NR==1 {print $3}')"
  NET_MODE="$mode"
  NET_CIDR=""
  NET_GATEWAY=""
  NET_DNS=""
  NET_DHCP6="true"
  if [[ "$mode" == "static" ]]; then
    while true; do
      cidr="$(read_value "IPv4-адрес в CIDR-формате" "$current_cidr")"
      is_ipv4_cidr "$cidr" && break
      warn "Пример корректного значения: 192.168.1.20/24"
    done
    while true; do
      gateway="$(read_value "IPv4-шлюз" "$current_gateway")"
      is_ipv4 "$gateway" && break
      warn "Некорректный IPv4-адрес шлюза"
    done
    while true; do
      dns="$(read_value "IPv4 DNS-серверы через запятую" "1.1.1.1,8.8.8.8")"
      valid_ipv4_list "$dns" && break
      warn "Укажите один или несколько корректных IPv4-адресов через запятую"
    done
    NET_CIDR="$cidr"; NET_GATEWAY="$gateway"; NET_DNS="$dns"
  fi
  if ! ask_yes_no "Использовать DHCP для IPv6?" y; then dhcp6="false"; else dhcp6="true"; fi
  NET_DHCP6="$dhcp6"
}

network_risk_confirmation() {
  if ((RUNNING_OVER_SSH)); then
    confirm_phrase "Изменение сети может оборвать текущую SSH-сессию. Автоматический откат доступен только у Netplan." "APPLY NETWORK"
  else
    ask_yes_no "Применить новую сетевую конфигурацию сейчас?" n
  fi
}

netplan_renderer() {
  local renderer="networkd"
  if command -v netplan >/dev/null 2>&1; then
    renderer="$(netplan get network.renderer 2>/dev/null | tr -d '[:space:]' || true)"
  fi
  case "${renderer,,}" in
    networkmanager) printf 'NetworkManager' ;;
    *) printf 'networkd' ;;
  esac
}

render_netplan_config() {
  local iface="$1" renderer="$2" dns_yaml="" dns_value
  if [[ "$NET_MODE" == "dhcp" ]]; then
    cat <<EOF
# Managed by debian-ubuntu-autosetup
network:
  version: 2
  renderer: ${renderer}
  ethernets:
    ${iface}:
      dhcp4: true
      dhcp6: ${NET_DHCP6}
EOF
  else
    IFS=',' read -r -a dns_values <<<"$NET_DNS"
    for dns_value in "${dns_values[@]}"; do
      dns_value="${dns_value//[[:space:]]/}"
      [[ -n "$dns_yaml" ]] && dns_yaml+=", "
      dns_yaml+="$dns_value"
    done
    cat <<EOF
# Managed by debian-ubuntu-autosetup
network:
  version: 2
  renderer: ${renderer}
  ethernets:
    ${iface}:
      dhcp4: false
      dhcp6: ${NET_DHCP6}
      addresses: [${NET_CIDR}]
      routes:
        - to: default
          via: ${NET_GATEWAY}
      nameservers:
        addresses: [${dns_yaml}]
EOF
  fi
}

configure_netplan() {
  local iface="$1" renderer="${2:-$(netplan_renderer)}" target content
  if ((DRY_RUN == 0)) && ! command -v netplan >/dev/null 2>&1; then
    error "Команда netplan отсутствует"
    return 1
  fi
  target="/etc/netplan/90-autosetup-${iface}.yaml"
  content="$(render_netplan_config "$iface" "$renderer")"$'\n'
  if ! network_risk_confirmation; then
    warn "Изменение сети отменено; постоянный Netplan-файл не создавался"
    record_skip "Изменение сети через Netplan отменено"
    return 0
  fi
  write_file "$target" 0600 "$content"
  run netplan generate
  if ((DRY_RUN)); then
    run netplan try --timeout 90
  else
    info "Netplan откатит изменение через 90 секунд, если вы его не подтвердите"
    if netplan try --timeout 90; then
      ok "Netplan-конфигурация подтверждена"
    else
      error "Netplan отклонил или откатил конфигурацию"
      return 1
    fi
  fi
  record_ok "Сеть настроена через Netplan ($iface)"
}

configure_networkmanager() {
  local iface="$1" profile old_profile dns_spaces
  profile="autosetup-${iface}"
  if ((DRY_RUN == 0)) && ! command -v nmcli >/dev/null 2>&1; then
    error "nmcli отсутствует"
    return 1
  fi
  if command -v nmcli >/dev/null 2>&1; then
    old_profile="$(nmcli -g GENERAL.CONNECTION device show "$iface" 2>/dev/null || true)"
  else
    old_profile=""
  fi
  if ! network_risk_confirmation; then
    warn "Изменение сети отменено; профиль NetworkManager не создавался"
    record_skip "Изменение сети через NetworkManager отменено"
    return 0
  fi
  backup_path /etc/NetworkManager/system-connections
  if ! command -v nmcli >/dev/null 2>&1 || ! nmcli -t -f NAME connection show 2>/dev/null | grep -Fxq "$profile"; then
    run nmcli connection add type ethernet ifname "$iface" con-name "$profile"
  fi
  if [[ "$NET_MODE" == "dhcp" ]]; then
    run nmcli connection modify "$profile" ipv4.method auto ipv4.addresses "" ipv4.gateway "" ipv4.dns ""
  else
    dns_spaces="${NET_DNS//,/ }"
    run nmcli connection modify "$profile" ipv4.method manual ipv4.addresses "$NET_CIDR" ipv4.gateway "$NET_GATEWAY" ipv4.dns "$dns_spaces"
  fi
  if [[ "$NET_DHCP6" == "true" ]]; then
    run nmcli connection modify "$profile" ipv6.method auto
  else
    run nmcli connection modify "$profile" ipv6.method disabled
  fi
  run nmcli connection modify "$profile" connection.autoconnect yes
  if ((DRY_RUN)); then
    run nmcli connection up "$profile"
  elif ! nmcli connection up "$profile"; then
    error "Не удалось активировать $profile"
    if [[ -n "$old_profile" && "$old_profile" != "--" ]]; then
      warn "Попытка вернуть профиль $old_profile"
      nmcli connection up "$old_profile" || true
    fi
    return 1
  fi
  record_ok "Сеть настроена через NetworkManager ($iface)"
}

render_networkd_config() {
  local iface="$1" dns_line="" item dhcp_mode="yes"
  if [[ "$NET_MODE" == "dhcp" ]]; then
    [[ "$NET_DHCP6" == "true" ]] || dhcp_mode="ipv4"
    cat <<EOF
# Managed by debian-ubuntu-autosetup
[Match]
Name=${iface}

[Network]
DHCP=${dhcp_mode}
IPv6AcceptRA=${NET_DHCP6}
EOF
  else
    IFS=',' read -r -a dns_values <<<"$NET_DNS"
    for item in "${dns_values[@]}"; do dns_line+="DNS=${item//[[:space:]]/}"$'\n'; done
    cat <<EOF
# Managed by debian-ubuntu-autosetup
[Match]
Name=${iface}

[Network]
Address=${NET_CIDR}
Gateway=${NET_GATEWAY}
${dns_line}IPv6AcceptRA=${NET_DHCP6}
EOF
  fi
}

configure_networkd() {
  local iface="$1" target content
  target="/etc/systemd/network/90-autosetup-${iface}.network"
  content="$(render_networkd_config "$iface")"$'\n'
  if ! network_risk_confirmation; then
    warn "Изменение сети отменено; постоянный networkd-файл не создавался"
    record_skip "Изменение сети через systemd-networkd отменено"
    return 0
  fi
  write_file "$target" 0644 "$content"
  run systemctl enable --now systemd-networkd
  run networkctl reload
  run networkctl reconfigure "$iface"
  record_ok "Сеть настроена через systemd-networkd ($iface)"
}

configure_ifupdown() {
  local iface="$1" target content
  if grep -RqsE "^[[:space:]]*iface[[:space:]]+${iface}[[:space:]]" /etc/network/interfaces /etc/network/interfaces.d 2>/dev/null; then
    warn "Для $iface уже есть ifupdown-конфигурация. Автоматическая перезапись сложного stanza отключена."
    record_warn "Сеть ifupdown не изменена из-за существующей конфигурации $iface"
    return 1
  fi
  target="/etc/network/interfaces.d/90-autosetup-${iface}"
  if [[ "$NET_MODE" == "dhcp" ]]; then
    content="# Managed by debian-ubuntu-autosetup
auto ${iface}
iface ${iface} inet dhcp
"
  else
    content="# Managed by debian-ubuntu-autosetup
auto ${iface}
iface ${iface} inet static
    address ${NET_CIDR}
    gateway ${NET_GATEWAY}
    dns-nameservers ${NET_DNS//,/ }
"
  fi
  if ! network_risk_confirmation; then
    warn "Изменение сети отменено; постоянный ifupdown-файл не создавался"
    record_skip "Изменение сети через ifupdown отменено"
    return 0
  fi
  write_file "$target" 0644 "$content"
  run ifdown --force "$iface"
  run ifup "$iface"
  record_ok "Сеть настроена через ifupdown ($iface)"
}

configure_network_stage() {
  local choice iface mode
  ((IS_CONTAINER)) && { record_skip "Настройка сети пропущена в контейнере"; return; }
  show_network_state
  if test_connectivity; then
    if ! ask_yes_no "Изменить текущую сетевую конфигурацию?" n; then
      record_skip "Сетевая конфигурация оставлена без изменений"
      return
    fi
  else
    ask_yes_no "Попытаться настроить сеть?" y || { record_skip "Настройка сети пропущена"; return; }
  fi
  iface="$(select_interface)"
  if is_complex_interface "$iface"; then
    error "$iface является bridge/bond/VLAN/slave или имеет несколько IPv4-адресов. Упрощённый сетевой генератор его не изменяет."
    record_warn "Сложная сеть на $iface оставлена без изменений"
    return 1
  fi
  printf '1) DHCP\n2) Статический IPv4\n'
  choice="$(choose_one "Режим адресации" 2 1)"
  [[ "$choice" == "1" ]] && mode="dhcp" || mode="static"
  collect_network_values "$iface" "$mode"
  case "$NETWORK_BACKEND" in
    netplan) configure_netplan "$iface" ;;
    networkmanager) configure_networkmanager "$iface" ;;
    systemd-networkd) configure_networkd "$iface" ;;
    ifupdown) configure_ifupdown "$iface" ;;
    *)
      error "Не удалось безопасно определить механизм управления сетью"
      record_warn "Сеть не изменена: неизвестный backend"
      return 1
      ;;
  esac
  ((DRY_RUN)) || sleep 2
  test_connectivity || warn "После изменения сети проверка связности не прошла полностью"
}

escape_apt_value() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s' "$value"
}

configure_proxy_stage() {
  local escaped content
  if ! ask_yes_no "Нужен HTTP/HTTPS-прокси для APT?" n; then
    record_skip "Прокси не настроен"
    return
  fi
  PROXY_URL="$(read_value "URL прокси, например http://proxy.example:3128")"
  [[ "$PROXY_URL" =~ ^https?://[^[:space:]]+$ ]] || { error "Некорректный URL прокси"; PROXY_URL=""; return 1; }
  if [[ "$PROXY_URL" == *"@"* ]]; then
    warn "URL содержит учётные данные; файл будет доступен только root, но секрет останется на диске"
  fi
  escaped="$(escape_apt_value "$PROXY_URL")"
  content="// Managed by debian-ubuntu-autosetup
Acquire::http::Proxy \"${escaped}\";
Acquire::https::Proxy \"${escaped}\";
"
  write_file /etc/apt/apt.conf.d/80autosetup-proxy 0600 "$content"
  record_ok "APT-прокси настроен"
}

ensure_https_prerequisites() {
  local keyring_package keyring_path
  if [[ "$OS_ID" == "debian" ]]; then
    keyring_package="debian-archive-keyring"; keyring_path="/usr/share/keyrings/debian-archive-keyring.gpg"
  else
    keyring_package="ubuntu-keyring"; keyring_path="/usr/share/keyrings/ubuntu-archive-keyring.gpg"
  fi
  if [[ ! -r "$keyring_path" ]]; then
    warn "Архивный keyring отсутствует; попытка установить через текущие репозитории"
    run apt-get update
    run apt-get install -y "$keyring_package" ca-certificates
  elif ! dpkg-query -W -f='${Status}' ca-certificates 2>/dev/null | grep -q 'ok installed'; then
    run apt-get update
    run apt-get install -y ca-certificates
  fi
}

disable_official_sources_in_list() {
  local file="$1" regex="$2" temporary
  [[ -f "$file" ]] || return 0
  grep -Eq "$regex" "$file" || return 0
  backup_path "$file"
  if ((DRY_RUN)); then
    info "[dry-run] Официальные записи будут отключены в $file"
    return 0
  fi
  temporary="$(mktemp)"
  awk -v re="$regex" '
    $0 !~ /^[[:space:]]*#/ && $0 ~ re { print "# disabled by debian-ubuntu-autosetup: " $0; next }
    { print }
  ' "$file" >"$temporary"
  cat "$temporary" >"$file"
  rm -f "$temporary"
}

disable_official_stanzas() {
  local file="$1" regex="$2" temporary
  [[ -f "$file" ]] || return 0
  grep -Eq "$regex" "$file" || return 0
  backup_path "$file"
  if ((DRY_RUN)); then
    info "[dry-run] Официальные stanza будут отключены в $file"
    return 0
  fi
  temporary="$(mktemp)"
  awk -v RS='' -v ORS='\n\n' -v re="$regex" '
    {
      if ($0 ~ re) {
        if ($0 ~ /(^|\n)Enabled:[[:space:]]*/) {
          gsub(/(^|\n)Enabled:[^\n]*/, "\nEnabled: no")
        } else {
          $0 = $0 "\nEnabled: no"
        }
      }
      print
    }
  ' "$file" >"$temporary"
  cat "$temporary" >"$file"
  rm -f "$temporary"
}

normalize_official_sources() {
  local target="$1" regex="$2" file
  if [[ -f /etc/apt/sources.list ]]; then
    disable_official_sources_in_list /etc/apt/sources.list "$regex"
  fi
  for file in /etc/apt/sources.list.d/*.list; do
    [[ "$file" == "$target" ]] || disable_official_sources_in_list "$file" "$regex"
  done
  for file in /etc/apt/sources.list.d/*.sources; do
    [[ "$file" == "$target" ]] || disable_official_stanzas "$file" "$regex"
  done
}

configure_debian_sources() {
  local types="deb" components="main non-free-firmware" target content
  target="/etc/apt/sources.list.d/debian.sources"
  ask_yes_no "Включить индексы исходных пакетов deb-src?" n && types="deb deb-src"
  ask_yes_no "Добавить компоненты contrib и non-free?" n && components="main contrib non-free non-free-firmware"
  normalize_official_sources "$target" 'deb\.debian\.org|security\.debian\.org|ftp\.[^/[:space:]]*\.debian\.org'
  content="Types: ${types}
URIs: https://deb.debian.org/debian
Suites: ${OS_CODENAME} ${OS_CODENAME}-updates
Components: ${components}
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: ${types}
URIs: https://security.debian.org/debian-security
Suites: ${OS_CODENAME}-security
Components: ${components}
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
"
  write_file "$target" 0644 "$content"
}

configure_ubuntu_sources() {
  local types="deb" target mirror security_mirror architecture content suites
  target="/etc/apt/sources.list.d/ubuntu.sources"
  architecture="$(dpkg --print-architecture)"
  if [[ "$architecture" == "amd64" || "$architecture" == "i386" ]]; then
    mirror="https://archive.ubuntu.com/ubuntu"
    security_mirror="https://security.ubuntu.com/ubuntu"
  else
    mirror="https://ports.ubuntu.com/ubuntu-ports"
    security_mirror="$mirror"
  fi
  ask_yes_no "Включить индексы исходных пакетов deb-src?" n && types="deb deb-src"
  suites="${OS_CODENAME} ${OS_CODENAME}-updates"
  ask_yes_no "Включить официальный pocket backports?" n && suites+=" ${OS_CODENAME}-backports"
  normalize_official_sources "$target" 'archive\.ubuntu\.com|security\.ubuntu\.com|ports\.ubuntu\.com|[a-z0-9.-]+\.archive\.ubuntu\.com'
  content="Types: ${types}
URIs: ${mirror}
Suites: ${suites}
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: ${types}
URIs: ${security_mirror}
Suites: ${OS_CODENAME}-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
"
  write_file "$target" 0644 "$content"
}

apt_update() {
  run apt-get update
  APT_UPDATED=1
}

configure_repositories_stage() {
  if ! ask_yes_no "Нормализовать официальные APT-репозитории и перевести их на HTTPS?" y; then
    record_skip "APT-репозитории не изменены"
    return
  fi
  ensure_https_prerequisites
  backup_path /etc/apt/sources.list
  backup_path /etc/apt/sources.list.d
  if [[ "$OS_ID" == "debian" ]]; then configure_debian_sources; else configure_ubuntu_sources; fi
  if apt_update; then
    ok "APT-репозитории работают"
    record_ok "Официальные APT-репозитории нормализованы"
  else
    error "apt update завершился ошибкой. Исходные файлы сохранены в $BACKUP_DIR"
    record_warn "После изменения репозиториев apt update завершился ошибкой"
    return 1
  fi
}

upgrade_stage() {
  local choice
  if ! ask_yes_no "Обновить установленные пакеты?" y; then
    record_skip "Обновление пакетов пропущено"
    return
  fi
  ((APT_UPDATED)) || apt_update
  printf '1) Обычный upgrade (рекомендуется)\n2) full-upgrade (может удалить пакеты)\n3) Только показать доступные обновления\n'
  choice="$(choose_one "Режим обновления" 3 1)"
  case "$choice" in
    1) run apt-get upgrade -y; record_ok "Выполнен apt upgrade" ;;
    2)
      if confirm_phrase "full-upgrade может устанавливать и удалять зависимости" "FULL UPGRADE"; then
        run apt-get full-upgrade -y
        record_ok "Выполнен apt full-upgrade"
      else
        record_skip "full-upgrade отменён"
      fi
      ;;
    3) apt list --upgradable 2>/dev/null || true; record_skip "Пакеты не обновлялись" ;;
  esac
}

package_available() { apt-cache show --no-all-versions "$1" >/dev/null 2>&1; }

install_packages_stage() {
  local package
  local -a requested=(openssh-server sudo passwd ufw traceroute nano wget git fail2ban clamav clamav-freshclam cron ca-certificates curl dnsutils iputils-ping netcat-openbsd unattended-upgrades)
  local -a available=() missing=()
  if ! ask_yes_no "Установить рекомендуемый набор системных и защитных пакетов?" y; then
    record_skip "Установка пакетов пропущена"
    return
  fi
  ask_yes_no "Установить telnet-клиент для диагностики (передаёт данные без шифрования)?" n && requested+=(telnet)
  ask_yes_no "Установить needrestart для проверки служб после обновлений?" y && requested+=(needrestart)
  ((APT_UPDATED)) || apt_update
  for package in "${requested[@]}"; do
    if ((DRY_RUN)) || package_available "$package"; then available+=("$package"); else missing+=("$package"); fi
  done
  if ((${#missing[@]})); then warn "Недоступные пакеты пропущены: ${missing[*]}"; fi
  if ((${#available[@]})); then
    run apt-get install -y "${available[@]}"
    record_ok "Установлены рекомендуемые пакеты"
  fi
}

configure_unattended_upgrades_stage() {
  local reboot="false" reboot_time="03:30" content
  if ((DRY_RUN == 0)) && ! command -v unattended-upgrade >/dev/null 2>&1; then
    record_skip "unattended-upgrades не установлен"
    return
  fi
  ((HAS_SYSTEMD)) || { record_skip "Автообновления через systemd timer пропущены: systemd не является PID 1"; return; }
  if ! ask_yes_no "Включить автоматическую установку обновлений безопасности?" y; then
    record_skip "Автоматические обновления не включены"
    return
  fi
  if ask_yes_no "Разрешить автоматическую перезагрузку, когда она необходима?" n; then
    reboot="true"
    reboot_time="$(read_value "Время автоматической перезагрузки HH:MM" "03:30")"
    [[ "$reboot_time" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || die "Некорректное время: $reboot_time"
  fi
  content="// Managed by debian-ubuntu-autosetup
APT::Periodic::Update-Package-Lists \"1\";
APT::Periodic::Unattended-Upgrade \"1\";
APT::Periodic::AutocleanInterval \"7\";
Unattended-Upgrade::Automatic-Reboot \"${reboot}\";
Unattended-Upgrade::Automatic-Reboot-Time \"${reboot_time}\";
"
  write_file /etc/apt/apt.conf.d/52autosetup-unattended-upgrades 0644 "$content"
  run systemctl enable --now apt-daily.timer apt-daily-upgrade.timer
  record_ok "Автоматические обновления безопасности включены"
}

valid_username() { [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; }

install_authorized_key() {
  local username="$1" home group key keyfile temporary
  home="$(getent passwd "$username" | cut -d: -f6 || true)"
  home="${home:-/home/$username}"
  group="$(id -gn "$username" 2>/dev/null || printf '%s' "$username")"
  key="$(read_value "Вставьте одну строку публичного SSH-ключа")"
  [[ -n "$key" ]] || { warn "Пустой ключ; добавление пропущено"; return 1; }
  temporary="$(mktemp)"
  printf '%s\n' "$key" >"$temporary"
  if command -v ssh-keygen >/dev/null 2>&1 && ! ssh-keygen -l -f "$temporary" >/dev/null 2>&1; then
    rm -f "$temporary"
    error "ssh-keygen не распознал публичный ключ"
    return 1
  elif ! command -v ssh-keygen >/dev/null 2>&1 && ((DRY_RUN == 0)); then
    rm -f "$temporary"
    error "Команда ssh-keygen отсутствует; ключ нельзя проверить"
    return 1
  fi
  rm -f "$temporary"
  keyfile="$home/.ssh/authorized_keys"
  if ((DRY_RUN)); then
    info "[dry-run] Ключ будет добавлен в $keyfile"
    return 0
  fi
  install -d -m 0700 -o "$username" -g "$group" "$home/.ssh"
  touch "$keyfile"
  chown "$username:$group" "$keyfile"
  chmod 0600 "$keyfile"
  grep -Fqx -- "$key" "$keyfile" || printf '%s\n' "$key" >>"$keyfile"
  return 0
}

create_user_stage() {
  local username
  if ! ask_yes_no "Создать или настроить административного пользователя?" y; then
    record_skip "Создание пользователя пропущено"
    return
  fi
  if ! command -v usermod >/dev/null 2>&1; then
    info "Команда usermod отсутствует; будет установлен содержащий её пакет passwd"
    ((APT_UPDATED)) || apt_update
    run apt-get install -y passwd
    if ((DRY_RUN == 0)) && ! command -v usermod >/dev/null 2>&1; then
      error "После установки passwd команда usermod всё ещё недоступна"
      return 1
    fi
  fi
  while true; do
    username="$(read_value "Имя пользователя")"
    valid_username "$username" && break
    warn "Допустимы строчные латинские буквы, цифры, _ и -; первый символ — буква или _"
  done
  if id "$username" >/dev/null 2>&1; then
    info "Пользователь $username уже существует"
  else
    run adduser --disabled-password --gecos "" "$username"
  fi
  run usermod -aG sudo "$username"
  if ask_yes_no "Задать или изменить пароль пользователя $username?" y; then
    if ((DRY_RUN)); then info "[dry-run] Будет запущена безопасная команда passwd $username"; else passwd "$username"; fi
  fi
  if ask_yes_no "Добавить публичный SSH-ключ для $username?" y; then
    install_authorized_key "$username" && record_ok "SSH-ключ установлен для $username"
  fi
  record_ok "Пользователь $username состоит в группе sudo"
  ADMIN_USER="$username"
}

ensure_sshd_include() {
  local main=/etc/ssh/sshd_config temporary
  grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "$main" 2>/dev/null && return 0
  backup_path "$main"
  if ((DRY_RUN)); then
    info "[dry-run] Include для sshd_config.d будет добавлен в начало $main"
    return 0
  fi
  temporary="$(mktemp)"
  printf 'Include /etc/ssh/sshd_config.d/*.conf\n' >"$temporary"
  cat "$main" >>"$temporary"
  cat "$temporary" >"$main"
  rm -f "$temporary"
}

user_has_authorized_key() {
  local username="$1" home
  [[ -n "$username" ]] || return 1
  home="$(getent passwd "$username" | cut -d: -f6)"
  [[ -s "$home/.ssh/authorized_keys" ]]
}

configure_motd() {
  local hostname_value organization content motd_script
  hostname_value="$(hostname -f 2>/dev/null || hostname)"
  organization="$(read_value "Название организации или системы для MOTD" "$hostname_value")"
  content="${organization}

Доступ разрешён только авторизованным пользователям.
Все действия могут регистрироваться в журнале.
"
  if [[ "$OS_ID" == "ubuntu" && -d /etc/update-motd.d ]]; then
    motd_script="#!/bin/sh
cat /etc/debian-ubuntu-autosetup/motd.txt
"
    write_file /etc/debian-ubuntu-autosetup/motd.txt 0644 "$content"
    write_file /etc/update-motd.d/99-autosetup 0755 "$motd_script"
  else
    write_file /etc/motd 0644 "$content"
  fi
}

configure_sshd_stage() {
  local new_port password_auth="yes" root_login="no" key_auth="yes" content effective admin="${ADMIN_USER:-}"
  if ((DRY_RUN == 0)) && ! command -v sshd >/dev/null 2>&1; then
    record_skip "openssh-server не установлен"
    return
  fi
  ((HAS_SYSTEMD)) || { record_skip "Настройка SSH-службы пропущена: systemd не является PID 1"; return; }
  if ! ask_yes_no "Настроить и усилить SSH-сервер?" y; then
    record_skip "Настройка SSH пропущена"
    return
  fi
  while true; do
    new_port="$(read_value "SSH-порт" "$SSH_PORT")"
    valid_port "$new_port" && break
    warn "Порт должен быть от 1 до 65535"
  done
  ask_yes_no "Разрешить вход по публичным ключам?" y || key_auth="no"
  if ask_yes_no "Оставить парольную SSH-аутентификацию?" y; then
    password_auth="yes"
  else
    password_auth="no"
    if [[ -z "$admin" ]]; then admin="$(read_value "Пользователь, чей SSH-ключ следует проверить")"; fi
    if ! user_has_authorized_key "$admin" && ((DRY_RUN == 0)); then
      error "У $admin не найден непустой authorized_keys; отключение паролей отменено"
      password_auth="yes"
    elif ((RUNNING_OVER_SSH)) && ! confirm_phrase "Перед отключением паролей рекомендуется проверить ключ во второй сессии" "KEY LOGIN WORKS"; then
      warn "Парольная аутентификация оставлена включённой"
      password_auth="yes"
    fi
  fi
  if [[ "$key_auth" == "no" && "$password_auth" == "no" ]]; then
    warn "Нельзя одновременно отключить ключи и пароли; парольная аутентификация оставлена включённой"
    password_auth="yes"
  fi
  if ask_yes_no "Запретить удалённый вход root по SSH?" y; then root_login="no"; else root_login="prohibit-password"; fi

  if command -v ufw >/dev/null 2>&1; then
    run ufw allow "${new_port}/tcp" comment 'OpenSSH autosetup'
  fi
  ensure_sshd_include
  content="# Managed by debian-ubuntu-autosetup
Port ${new_port}
PermitRootLogin ${root_login}
PubkeyAuthentication ${key_auth}
PasswordAuthentication ${password_auth}
KbdInteractiveAuthentication ${password_auth}
UsePAM yes
MaxAuthTries 4
LoginGraceTime 30
"
  write_file /etc/ssh/sshd_config.d/99-autosetup.conf 0644 "$content"
  if ((DRY_RUN)); then
    run sshd -t
    run systemctl reload ssh
  else
    if ! sshd -t; then
      error "Проверка sshd_config не прошла. SSH не перезагружен. Резервная копия: $BACKUP_DIR"
      record_warn "Новая конфигурация SSH не прошла sshd -t"
      return 1
    fi
    effective="$(sshd -T)"
    if ! grep -Fxq "port ${new_port}" <<<"$effective" \
      || { [[ "$root_login" == "no" ]] && ! grep -Fxq "permitrootlogin no" <<<"$effective"; } \
      || { [[ "$root_login" != "no" ]] && ! grep -Eq '^permitrootlogin (prohibit-password|without-password)$' <<<"$effective"; } \
      || ! grep -Fxq "pubkeyauthentication ${key_auth}" <<<"$effective" \
      || ! grep -Fxq "passwordauthentication ${password_auth}" <<<"$effective"; then
      error "Эффективная конфигурация sshd не совпадает с выбранными значениями. SSH не перезагружен."
      record_warn "Параметры SSH перекрываются другой конфигурацией"
      return 1
    fi
    if (($(grep -c '^port ' <<<"$effective") > 1)); then
      warn "Эффективная конфигурация SSH содержит несколько директив Port"
      record_warn "SSH может продолжать слушать дополнительный порт"
    fi
    systemctl reload ssh
    sleep 1
    if ! ss -ltn | awk '{print $4}' | grep -Eq "(^|:|\])${new_port}$"; then
      error "После reload порт $new_port не обнаружен среди прослушиваемых"
      return 1
    fi
  fi
  SSH_PORT="$new_port"
  ask_yes_no "Установить простой MOTD после входа?" y && configure_motd
  if [[ "$new_port" != "22" ]]; then
    warn "Старые правила UFW для порта 22 автоматически не удалялись"
  fi
  record_ok "SSH настроен и проверен; порт $SSH_PORT"
}

enable_ufw_ipv6() {
  local target=/etc/default/ufw temporary
  [[ -f "$target" ]] || return 0
  grep -q '^IPV6=yes' "$target" && return 0
  backup_path "$target"
  if ((DRY_RUN)); then info "[dry-run] IPV6=yes будет установлено в $target"; return; fi
  temporary="$(mktemp)"
  awk 'BEGIN{done=0} /^IPV6=/{print "IPV6=yes"; done=1; next} {print} END{if(!done) print "IPV6=yes"}' "$target" >"$temporary"
  cat "$temporary" >"$target"
  rm -f "$temporary"
}

add_extra_ufw_ports() {
  local input item port proto
  input="$(read_value "Порты через запятую, например 80/tcp,443/tcp; пусто — пропустить")"
  [[ -z "$input" ]] && return 0
  IFS=',' read -r -a items <<<"$input"
  for item in "${items[@]}"; do
    item="${item//[[:space:]]/}"
    port="${item%/*}"; proto="${item#*/}"
    if [[ "$item" != */* ]]; then proto="tcp"; port="$item"; fi
    if valid_port "$port" && [[ "$proto" =~ ^(tcp|udp)$ ]]; then
      run ufw allow "${port}/${proto}"
    else
      warn "Некорректное правило пропущено: $item"
    fi
  done
}

configure_ufw_stage() {
  if ((DRY_RUN == 0)) && ! command -v ufw >/dev/null 2>&1; then
    record_skip "UFW не установлен"
    return
  fi
  ((IS_CONTAINER)) && { record_skip "UFW пропущен в контейнере"; return; }
  if ! ask_yes_no "Настроить и включить UFW?" y; then
    record_skip "Настройка UFW пропущена"
    return
  fi
  enable_ufw_ipv6
  run ufw default deny incoming
  run ufw default allow outgoing
  run ufw allow "${SSH_PORT}/tcp" comment 'OpenSSH autosetup'
  ask_yes_no "Разрешить дополнительные входящие порты?" n && add_extra_ufw_ports
  if ((RUNNING_OVER_SSH)) && ! confirm_phrase "UFW будет включён; SSH-порт $SSH_PORT уже добавлен" "ENABLE UFW"; then
    warn "Включение UFW отменено, правила сохранены"
    record_warn "Правила UFW созданы, но firewall не включён"
    return
  fi
  run ufw --force enable
  if ((DRY_RUN == 0)); then ufw status verbose; fi
  record_ok "UFW включён; входящие подключения запрещены по умолчанию"
}

configure_fail2ban_stage() {
  local backend="auto" banaction="" portscan="false" jail_content filter_content
  if ((DRY_RUN == 0)) && ! command -v fail2ban-client >/dev/null 2>&1; then
    record_skip "Fail2ban не установлен"
    return
  fi
  ((HAS_SYSTEMD)) || { record_skip "Fail2ban пропущен: systemd не является PID 1"; return; }
  if ! ask_yes_no "Настроить Fail2ban для защиты SSH?" y; then
    record_skip "Настройка Fail2ban пропущена"
    return
  fi
  command -v journalctl >/dev/null 2>&1 && backend="systemd"
  if [[ -f /etc/fail2ban/action.d/ufw.conf ]] && command -v ufw >/dev/null 2>&1; then
    banaction="banaction = ufw"
  elif [[ -f /etc/fail2ban/action.d/nftables-multiport.conf ]]; then
    banaction="banaction = nftables-multiport"
  fi
  if ask_yes_no "Включить экспериментальный jail для частых блокировок UFW (возможны ложные срабатывания)?" n; then
    if [[ "$backend" == "systemd" ]] && [[ -f /etc/fail2ban/action.d/ufw.conf ]]; then
      portscan="true"
      filter_content="[Definition]
failregex = ^.*\[UFW BLOCK\].*SRC=<HOST>.*$
ignoreregex =
"
      write_file /etc/fail2ban/filter.d/ufw-portscan.local 0644 "$filter_content"
    else
      warn "Для portscan-jail требуются systemd journal и действие UFW; этап пропущен"
    fi
  fi
  jail_content="# Managed by debian-ubuntu-autosetup
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5
backend = ${backend}
${banaction}

[sshd]
enabled = true
port = ${SSH_PORT}
mode = aggressive
"
  if [[ "$portscan" == "true" ]]; then
    jail_content+="
[ufw-portscan]
enabled = true
filter = ufw-portscan
backend = systemd
journalmatch = _TRANSPORT=kernel
maxretry = 20
findtime = 60
bantime = 3600
action = ufw
"
  fi
  write_file /etc/fail2ban/jail.d/99-autosetup.local 0644 "$jail_content"
  if ((DRY_RUN)); then
    run fail2ban-client -t
    run systemctl enable --now fail2ban
  elif fail2ban-client -t; then
    systemctl enable --now fail2ban
    systemctl restart fail2ban
    fail2ban-client status sshd || true
    record_ok "Fail2ban настроен для SSH"
  else
    error "Конфигурация Fail2ban не прошла проверку"
    record_warn "Fail2ban не перезапущен из-за ошибки конфигурации"
    return 1
  fi
}

configure_clamav_timer() {
  local scan_paths path quoted_paths="" script_content service_content timer_content
  local -a scan_path_array=()
  scan_paths="$(read_value "Каталоги для еженедельной проверки, через пробел" "/home /tmp /var/tmp")"
  read -r -a scan_path_array <<<"$scan_paths"
  for path in "${scan_path_array[@]}"; do
    if [[ "$path" =~ ^/[a-zA-Z0-9_./-]+$ ]] && { [[ -d "$path" ]] || ((DRY_RUN)); }; then
      printf -v quoted_paths '%s %q' "$quoted_paths" "$path"
    else
      warn "Небезопасный или отсутствующий путь пропущен: $path"
    fi
  done
  [[ -n "$quoted_paths" ]] || { error "Не выбрано ни одного корректного каталога"; return 1; }
  script_content="#!/usr/bin/env bash
set -u
install -d -m 0750 /var/log/clamav
exec /usr/bin/flock -n /run/lock/autosetup-clamscan.lock \\
  /usr/bin/nice -n 10 /usr/bin/clamscan -r -i \\
  --exclude-dir='^/proc' --exclude-dir='^/sys' --exclude-dir='^/dev' --exclude-dir='^/run' \\
  --log=/var/log/clamav/autosetup-scan.log${quoted_paths}
"
  service_content="[Unit]
Description=Weekly ClamAV scan configured by debian-ubuntu-autosetup
After=clamav-freshclam.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/autosetup-clamscan
Nice=10
IOSchedulingClass=idle
"
  timer_content="[Unit]
Description=Weekly ClamAV scan timer

[Timer]
OnCalendar=Sun *-*-* 03:00:00
RandomizedDelaySec=30m
Persistent=true

[Install]
WantedBy=timers.target
"
  write_file /usr/local/sbin/autosetup-clamscan 0750 "$script_content"
  write_file /etc/systemd/system/autosetup-clamscan.service 0644 "$service_content"
  write_file /etc/systemd/system/autosetup-clamscan.timer 0644 "$timer_content"
  run systemctl daemon-reload
  run systemctl enable --now autosetup-clamscan.timer
}

configure_clamav_stage() {
  local choice
  if ((DRY_RUN == 0)) && ! command -v clamscan >/dev/null 2>&1; then
    record_skip "ClamAV не установлен"
    return
  fi
  ((HAS_SYSTEMD)) || { record_skip "Настройка ClamAV-служб пропущена: systemd не является PID 1"; return; }
  if ! ask_yes_no "Настроить обновление баз и режим ClamAV?" y; then
    record_skip "Настройка ClamAV пропущена"
    return
  fi
  run systemctl enable --now clamav-freshclam.service
  printf '1) Только ручное сканирование\n2) Еженедельное сканирование выбранных каталогов\n3) Установить также clamav-daemon\n'
  choice="$(choose_one "Режим ClamAV" 3 2)"
  case "$choice" in
    1) record_ok "ClamAV настроен для ручного сканирования" ;;
    2) configure_clamav_timer; record_ok "Настроен еженедельный ClamAV-скан" ;;
    3)
      ((APT_UPDATED)) || apt_update
      run apt-get install -y clamav-daemon
      run systemctl enable --now clamav-daemon.service
      record_ok "ClamAV daemon установлен и включён"
      ;;
  esac
  if ask_yes_no "Запустить начальную проверку выбранных каталогов сейчас? Она может идти долго." n; then
    if [[ -x /usr/local/sbin/autosetup-clamscan ]]; then
      run systemctl start autosetup-clamscan.service
    else
      warn "Периодический профиль не создан; запустите clamscan вручную с нужными путями"
    fi
  fi
}

prepare_network_migration_stage() {
  local choice iface renderer mode current_cidr current_gateway
  ((IS_CONTAINER)) && return
  ((HAS_SYSTEMD)) || { record_skip "Миграция сети пропущена: systemd не является PID 1"; return; }
  if ! ask_yes_no "Подготовить миграцию управления сетью на Netplan или NetworkManager?" n; then
    record_skip "Миграция сетевого backend не запрашивалась"
    return
  fi
  warn "Автоматическое отключение старого backend не выполняется: cloud-init, VLAN, bridge и bond требуют отдельного плана отката."
  iface="$(select_interface)"
  if is_complex_interface "$iface"; then
    error "$iface является сложным или составным интерфейсом; универсальная миграция для него отключена"
    return 1
  fi
  current_cidr="$(ip -o -4 addr show dev "$iface" scope global 2>/dev/null | awk 'NR==1 {print $4}')"
  current_gateway="$(ip -4 route show default dev "$iface" 2>/dev/null | awk 'NR==1 {print $3}')"
  if [[ -z "$current_cidr" ]]; then
    error "На $iface нет текущего глобального IPv4-адреса; автоматическая подготовка невозможна"
    return 1
  fi
  printf '1) Netplan + systemd-networkd\n2) Netplan + NetworkManager (поддерживает nmtui)\n3) Чистый NetworkManager\n'
  choice="$(choose_one "Целевой backend" 3 1)"
  printf 'Текущая конфигурация: %s, шлюз %s\n' "$current_cidr" "${current_gateway:-не найден}"
  if ask_yes_no "Текущий адрес получен по DHCP?" y; then mode="dhcp"; else mode="static"; fi
  collect_network_values "$iface" "$mode"
  ((APT_UPDATED)) || apt_update
  case "$choice" in
    1|2)
      run apt-get install -y netplan.io
      [[ "$choice" == "1" ]] && renderer="networkd" || renderer="NetworkManager"
      [[ "$choice" == "2" ]] && run apt-get install -y network-manager
      if ((DRY_RUN)) || command -v netplan >/dev/null 2>&1; then
        configure_netplan "$iface" "$renderer"
      else
        error "netplan не появился после установки"
        return 1
      fi
      ;;
    3)
      run apt-get install -y network-manager
      if ((DRY_RUN)) || command -v nmcli >/dev/null 2>&1; then
        configure_networkmanager "$iface"
      else
        error "nmcli не появился после установки"
        return 1
      fi
      ;;
  esac
  if [[ "$choice" != "1" ]] && ask_yes_no "Открыть nmtui для просмотра профилей NetworkManager?" n; then
    if ((DRY_RUN)) || command -v nmtui >/dev/null 2>&1; then
      run nmtui
    else
      warn "nmtui не найден после установки NetworkManager"
    fi
  fi
  warn "Проверьте, что старый backend больше не управляет $iface, прежде чем считать миграцию завершённой."
  record_warn "Целевая сеть подготовлена; отключение старого backend требует ручной проверки"
}

final_checks() {
  printf '\n=== Итоговые проверки ===\n'
  test_connectivity || true
  if command -v sshd >/dev/null 2>&1; then
    if sshd -t; then ok "Конфигурация SSH корректна"; else error "Ошибка конфигурации SSH"; fi
  fi
  if command -v ufw >/dev/null 2>&1; then ufw status verbose || true; fi
  if command -v fail2ban-client >/dev/null 2>&1 && systemctl is-active --quiet fail2ban 2>/dev/null; then
    fail2ban-client status || true
  fi
  systemctl --failed --no-pager 2>/dev/null || true
  if [[ -e /var/run/reboot-required ]]; then
    warn "Для завершения обновлений требуется перезагрузка"
    record_warn "Требуется перезагрузка системы"
  fi
}

print_results() {
  local item
  printf '\n=== Итоговый отчёт ===\n'
  if ((${#RESULTS_OK[@]})); then
    printf 'Успешно:\n'
    for item in "${RESULTS_OK[@]}"; do printf '  + %s\n' "$item"; done
  fi
  if ((${#RESULTS_SKIP[@]})); then
    printf 'Пропущено:\n'
    for item in "${RESULTS_SKIP[@]}"; do printf '  - %s\n' "$item"; done
  fi
  if ((${#RESULTS_WARN[@]})); then
    printf 'Требует внимания:\n'
    for item in "${RESULTS_WARN[@]}"; do printf '  ! %s\n' "$item"; done
  fi
  printf 'Журнал: %s\n' "$LOG_FILE"
  if [[ -n "$BACKUP_DIR" ]]; then
    printf 'Резервные копии: %s\n' "$BACKUP_DIR"
  fi
  return 0
}

audit_only_run() {
  show_network_state
  test_connectivity || true
  printf '\nAPT-источники:\n'
  grep -RhsE '^[[:space:]]*(deb|deb-src|Types:|URIs:|Suites:|Components:|Enabled:)' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null || true
  printf '\nСостояние основных служб:\n'
  for service in ssh ufw fail2ban clamav-freshclam clamav-daemon apt-daily-upgrade.timer; do
    printf '%-26s %s\n' "$service" "$(systemctl is-active "$service" 2>/dev/null || true)"
  done
  record_ok "Аудит завершён без внесения изменений"
}

main() {
  parse_args "$@"
  require_root
  require_interactive_terminal
  init_runtime
  detect_os
  detect_environment
  printf '%s v%s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"
  show_system_summary

  if ((AUDIT_ONLY)); then
    audit_only_run
    print_results
    return
  fi

  if ((DRY_RUN)); then
    warn "DRY-RUN: команды изменения будут только показаны. Проверки файлов после записи могут отражать текущее состояние."
  fi

  configure_proxy_stage || warn "Прокси не настроен"
  configure_network_stage || warn "Этап настройки сети завершён с предупреждением"
  configure_repositories_stage || warn "Репозитории требуют ручной проверки"
  upgrade_stage
  install_packages_stage
  create_user_stage
  configure_sshd_stage || warn "SSH требует ручной проверки"
  configure_ufw_stage
  configure_fail2ban_stage || warn "Fail2ban требует ручной проверки"
  configure_clamav_stage
  configure_unattended_upgrades_stage
  prepare_network_migration_stage || warn "Миграция сетевого backend не завершена"
  final_checks
  print_results
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
