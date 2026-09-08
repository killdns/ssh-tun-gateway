#!/bin/sh
set -eu

if [ "$#" -gt 0 ]; then
  exec "$@"
fi

log() {
  printf '%s %s\n' "$(date -Iseconds)" "$*"
}

fail() {
  log "ERROR: $*" >&2
  exit 1
}

RUN_MODE="${RUN_MODE:-gateway}"
SSH_HOST="${SSH_HOST:-}"
SSH_ROUTE_IP="${SSH_ROUTE_IP:-$SSH_HOST}"
SSH_USER="${SSH_USER:-ssh-tunnel}"
SSH_PORT="${SSH_PORT:-22}"
IDENTITY_FILE="${IDENTITY_FILE:-/config/id_ed25519}"
KNOWN_HOSTS_FILE="${KNOWN_HOSTS_FILE:-/config/known_hosts}"
STRICT_HOST_KEY_CHECKING="${STRICT_HOST_KEY_CHECKING:-yes}"
CONTAINER_GATEWAY="${CONTAINER_GATEWAY:-}"
UPLINK_INTERFACE="${UPLINK_INTERFACE:-}"
LAN_CIDRS="${LAN_CIDRS:-}"
LOCAL_TUN_ID="${LOCAL_TUN_ID:-0}"
REMOTE_TUN_ID="${REMOTE_TUN_ID:-0}"
TUN_LOCAL="${TUN_LOCAL:-10.255.255.2}"
TUN_REMOTE="${TUN_REMOTE:-10.255.255.1}"
TUN_MTU="${TUN_MTU:-1400}"
ENABLE_NAT="${ENABLE_NAT:-1}"
SERVER_ALIVE_INTERVAL="${SERVER_ALIVE_INTERVAL:-20}"
SERVER_ALIVE_COUNT_MAX="${SERVER_ALIVE_COUNT_MAX:-3}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-15}"
TUN_WAIT_TIMEOUT="${TUN_WAIT_TIMEOUT:-20}"
RECONNECT_DELAY="${RECONNECT_DELAY:-5}"
REMOTE_COMMAND="${REMOTE_COMMAND:-sudo -n /usr/local/sbin/ssh-tun-session}"
SSH_EXTRA_OPTS="${SSH_EXTRA_OPTS:-}"
IPTABLES_BIN="${IPTABLES_BIN:-}"
SOCKS_BIND="${SOCKS_BIND:-0.0.0.0}"
SOCKS_PORT="${SOCKS_PORT:-1080}"
SOCKS_USER="${SOCKS_USER:-}"
SOCKS_PASSWORD="${SOCKS_PASSWORD:-}"
SOCKS_ALLOW_NO_AUTH="${SOCKS_ALLOW_NO_AUTH:-1}"
SOCKS_DNS_SERVER="${SOCKS_DNS_SERVER:-1.1.1.1}"
SOCKS_WORKERS="${SOCKS_WORKERS:-2}"
SOCKS_UDP_PORT_MIN="${SOCKS_UDP_PORT_MIN:-20000}"
SOCKS_UDP_PORT_MAX="${SOCKS_UDP_PORT_MAX:-20999}"
SOCKS_UDP_ADVERTISE_IP="${SOCKS_UDP_ADVERTISE_IP:-}"

gateway_enabled=0
socks_enabled=0
nat_enabled=0
case "$RUN_MODE" in
  gateway) gateway_enabled=1 ;;
  socks) socks_enabled=1 ;;
  both) gateway_enabled=1; socks_enabled=1 ;;
  *) fail "RUN_MODE must be gateway, socks, or both" ;;
esac
[ "$gateway_enabled" -eq 0 ] || [ "$ENABLE_NAT" != "1" ] || nat_enabled=1

[ "$(id -u)" -eq 0 ] || fail "the container must run as root"
[ -n "$SSH_HOST" ] || fail "SSH_HOST is required"
[ -n "$SSH_ROUTE_IP" ] || fail "SSH_ROUTE_IP is required"
[ -n "$CONTAINER_GATEWAY" ] || fail "CONTAINER_GATEWAY is required"
[ -n "$LAN_CIDRS" ] || fail "LAN_CIDRS is required"
[ -r "$IDENTITY_FILE" ] || fail "identity file is not readable: $IDENTITY_FILE"

if [ "$socks_enabled" -eq 1 ]; then
  [ -n "$SOCKS_BIND" ] || fail "SOCKS_BIND must not be empty"
  case "$SOCKS_BIND" in
    *[!0-9.]*) fail "SOCKS_BIND must be an IPv4 address" ;;
  esac
  case "$SOCKS_DNS_SERVER" in
    ''|*[!0-9.]*) fail "SOCKS_DNS_SERVER must be empty or an IPv4 address" ;;
  esac
  case "$SOCKS_PORT" in
    ''|*[!0-9]*) fail "SOCKS_PORT must be numeric" ;;
  esac
  [ "$SOCKS_PORT" -ge 1024 ] && [ "$SOCKS_PORT" -le 65535 ] || \
    fail "SOCKS_PORT must be between 1024 and 65535"

  if [ -n "$SOCKS_USER" ] || [ -n "$SOCKS_PASSWORD" ]; then
    [ -n "$SOCKS_USER" ] && [ -n "$SOCKS_PASSWORD" ] || \
      fail "SOCKS_USER and SOCKS_PASSWORD must be set together"
  else
    [ "$SOCKS_ALLOW_NO_AUTH" = "1" ] || \
      fail "set SOCKS_USER and SOCKS_PASSWORD, or explicitly set SOCKS_ALLOW_NO_AUTH=1"
  fi

  case "$SOCKS_WORKERS" in
    ''|*[!0-9]*) fail "SOCKS_WORKERS must be numeric" ;;
  esac
  [ "$SOCKS_WORKERS" -ge 1 ] && [ "$SOCKS_WORKERS" -le 64 ] || \
    fail "SOCKS_WORKERS must be between 1 and 64"

  case "$SOCKS_UDP_PORT_MIN:$SOCKS_UDP_PORT_MAX" in
    *[!0-9:]*) fail "SOCKS_UDP_PORT_MIN and SOCKS_UDP_PORT_MAX must be numeric" ;;
  esac
  [ "$SOCKS_UDP_PORT_MIN" -ge 1024 ] && \
    [ "$SOCKS_UDP_PORT_MAX" -le 65535 ] && \
    [ "$SOCKS_UDP_PORT_MIN" -le "$SOCKS_UDP_PORT_MAX" ] || \
    fail "invalid SOCKS UDP port range"

  if [ -n "$SOCKS_UDP_ADVERTISE_IP" ]; then
    case "$SOCKS_UDP_ADVERTISE_IP" in
      *[!0-9.]*) fail "SOCKS_UDP_ADVERTISE_IP must be an IPv4 address" ;;
    esac
  fi

  if printf '%s%s' "$SOCKS_USER" "$SOCKS_PASSWORD" | LC_ALL=C grep -q '[[:cntrl:]]'; then
    fail "SOCKS credentials must not contain control characters"
  fi
  [ "${#SOCKS_USER}" -le 255 ] && [ "${#SOCKS_PASSWORD}" -le 255 ] || \
    fail "SOCKS credentials must not exceed 255 characters"
fi

case "$LOCAL_TUN_ID:$REMOTE_TUN_ID" in
  *[!0-9:]*) fail "LOCAL_TUN_ID and REMOTE_TUN_ID must be numeric" ;;
esac

case "$SSH_ROUTE_IP" in
  *[!0-9.]*|'') fail "SSH_ROUTE_IP must be the server IPv4 address" ;;
esac

TUN_INTERFACE="tun${LOCAL_TUN_ID}"
ssh_pid=""
socks_pid=""
stop_requested=0

mkdir -p /dev/net
[ -e /dev/net/tun ] || mknod /dev/net/tun c 10 200 2>/dev/null || true
[ -c /dev/net/tun ] || fail "/dev/net/tun is unavailable"

if [ -z "$UPLINK_INTERFACE" ]; then
  UPLINK_INTERFACE="$(ip -4 route show default | awk '/^default / { print $5; exit }')"
fi
[ -n "$UPLINK_INTERFACE" ] || fail "cannot detect the container uplink interface"

mkdir -p "$(dirname "$KNOWN_HOSTS_FILE")"
touch "$KNOWN_HOSTS_FILE"
chmod 0600 "$IDENTITY_FILE" "$KNOWN_HOSTS_FILE" 2>/dev/null || true

if [ "$nat_enabled" -eq 1 ] && [ -z "$IPTABLES_BIN" ]; then
  if command -v iptables-legacy >/dev/null 2>&1 && iptables-legacy -S >/dev/null 2>&1; then
    IPTABLES_BIN="iptables-legacy"
  elif command -v iptables >/dev/null 2>&1 && iptables -S >/dev/null 2>&1; then
    IPTABLES_BIN="iptables"
  else
    fail "no working iptables backend; the container needs network-admin privileges"
  fi
fi

enable_forwarding() {
  current="$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || true)"
  if [ "$current" != "1" ]; then
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || return 1
  fi
}

prepare_underlay_routes() {
  ip link show dev "$UPLINK_INTERFACE" >/dev/null 2>&1 || return 1
  ip route replace default via "$CONTAINER_GATEWAY" dev "$UPLINK_INTERFACE" || return 1
  ip route replace "${SSH_ROUTE_IP}/32" via "$CONTAINER_GATEWAY" dev "$UPLINK_INTERFACE" || return 1

  old_ifs="$IFS"
  IFS=','
  for cidr in $LAN_CIDRS; do
    cidr="$(printf '%s' "$cidr" | tr -d ' ')"
    [ -n "$cidr" ] || continue
    ip route replace "$cidr" via "$CONTAINER_GATEWAY" dev "$UPLINK_INTERFACE" || return 1
  done
  IFS="$old_ifs"
}

install_firewall_rules() {
  [ "$gateway_enabled" -eq 1 ] || return 0
  [ "$ENABLE_NAT" = "1" ] || return 0

  old_ifs="$IFS"
  IFS=','
  for cidr in $LAN_CIDRS; do
    cidr="$(printf '%s' "$cidr" | tr -d ' ')"
    [ -n "$cidr" ] || continue

    "$IPTABLES_BIN" -C FORWARD -i "$UPLINK_INTERFACE" -s "$cidr" -o "$TUN_INTERFACE" -j ACCEPT 2>/dev/null || \
      "$IPTABLES_BIN" -I FORWARD 1 -i "$UPLINK_INTERFACE" -s "$cidr" -o "$TUN_INTERFACE" -j ACCEPT || return 1

    "$IPTABLES_BIN" -C FORWARD -i "$TUN_INTERFACE" -o "$UPLINK_INTERFACE" -d "$cidr" \
      -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
      "$IPTABLES_BIN" -I FORWARD 1 -i "$TUN_INTERFACE" -o "$UPLINK_INTERFACE" -d "$cidr" \
        -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT || return 1
  done
  IFS="$old_ifs"

  "$IPTABLES_BIN" -t nat -C POSTROUTING -o "$TUN_INTERFACE" -j MASQUERADE 2>/dev/null || \
    "$IPTABLES_BIN" -t nat -A POSTROUTING -o "$TUN_INTERFACE" -j MASQUERADE || return 1
}

wait_for_tunnel() {
  elapsed=0
  while ! ip link show dev "$TUN_INTERFACE" >/dev/null 2>&1; do
    kill -0 "$ssh_pid" 2>/dev/null || return 1
    [ "$elapsed" -lt "$TUN_WAIT_TIMEOUT" ] || return 1
    sleep 1
    elapsed=$((elapsed + 1))
  done
}

configure_tunnel() {
  ip address replace "${TUN_LOCAL}/32" peer "${TUN_REMOTE}/32" dev "$TUN_INTERFACE" || return 1
  ip link set dev "$TUN_INTERFACE" mtu "$TUN_MTU" up || return 1
  install_firewall_rules || return 1
  ip route replace default via "$TUN_REMOTE" dev "$TUN_INTERFACE" || return 1
}

configure_socks_dns() {
  [ "$socks_enabled" -eq 1 ] || return 0
  [ -n "$SOCKS_DNS_SERVER" ] || return 0
  printf 'nameserver %s\n' "$SOCKS_DNS_SERVER" > /etc/resolv.conf || return 1
}

escape_yaml_value() {
  printf '%s' "$1" | sed "s/'/''/g"
}

write_socks_config() {
  escaped_user="$(escape_yaml_value "$SOCKS_USER")"
  escaped_password="$(escape_yaml_value "$SOCKS_PASSWORD")"

  umask 077
  {
    printf 'main:\n'
    printf '  workers: %s\n' "$SOCKS_WORKERS"
    printf '  port: %s\n' "$SOCKS_PORT"
    printf "  listen-address: '%s'\n" "$SOCKS_BIND"
    printf "  udp-port: '%s-%s'\n" "$SOCKS_UDP_PORT_MIN" "$SOCKS_UDP_PORT_MAX"
    printf "  udp-listen-address: '%s'\n" "$SOCKS_BIND"
    printf '  listen-ipv6-only: false\n'
    printf '  domain-address-type: ipv4\n'
    if [ -n "$SOCKS_UDP_ADVERTISE_IP" ]; then
      printf "  udp-public-address-v4: '%s'\n" "$SOCKS_UDP_ADVERTISE_IP"
    fi
    if [ -n "$SOCKS_USER" ]; then
      printf 'auth:\n'
      printf "  username: '%s'\n" "$escaped_user"
      printf "  password: '%s'\n" "$escaped_password"
    fi
    printf 'misc:\n'
    printf '  log-file: stderr\n'
    printf '  log-level: warn\n'
  } > /tmp/hev-socks5-server.yml || return 1

  chown socks:socks /tmp/hev-socks5-server.yml || return 1
}

start_socks() {
  [ "$socks_enabled" -eq 1 ] || return 0
  configure_socks_dns || return 1
  write_socks_config || return 1

  (
    unset SOCKS_USER SOCKS_PASSWORD
    exec su-exec socks:socks hev-socks5-server /tmp/hev-socks5-server.yml
  ) &
  socks_pid="$!"
  sleep 1
  kill -0 "$socks_pid" 2>/dev/null || return 1
  log "SOCKS5 is listening on ${SOCKS_BIND}:${SOCKS_PORT} (TCP, UDP ASSOCIATE ${SOCKS_UDP_PORT_MIN}-${SOCKS_UDP_PORT_MAX})"
}

stop_socks() {
  if [ -n "$socks_pid" ]; then
    if kill -0 "$socks_pid" 2>/dev/null; then
      kill "$socks_pid" 2>/dev/null || true
    fi
    wait "$socks_pid" 2>/dev/null || true
  fi
  socks_pid=""
  rm -f /tmp/hev-socks5-server.yml
}

monitor_session() {
  while kill -0 "$ssh_pid" 2>/dev/null; do
    if [ "$socks_enabled" -eq 1 ] && ! kill -0 "$socks_pid" 2>/dev/null; then
      log "ERROR: SOCKS5 process stopped; reconnecting the tunnel"
      kill "$ssh_pid" 2>/dev/null || true
      return 1
    fi
    sleep 1
  done
}

restore_underlay_default() {
  ip route del default dev "$TUN_INTERFACE" 2>/dev/null || true
  ip route replace default via "$CONTAINER_GATEWAY" dev "$UPLINK_INTERFACE" 2>/dev/null || true
}

terminate() {
  stop_requested=1
  stop_socks
  if [ -n "$ssh_pid" ] && kill -0 "$ssh_pid" 2>/dev/null; then
    kill "$ssh_pid" 2>/dev/null || true
  fi
  restore_underlay_default
}

trap terminate INT TERM HUP

[ "$gateway_enabled" -eq 0 ] || enable_forwarding || fail "cannot enable net.ipv4.ip_forward"
prepare_underlay_routes || fail "cannot prepare routes through $CONTAINER_GATEWAY"

while [ "$stop_requested" -eq 0 ]; do
  prepare_underlay_routes || fail "cannot restore the SSH underlay route"
  log "Starting mode=${RUN_MODE}, SSH TUN ${TUN_INTERFACE} -> tun${REMOTE_TUN_ID} via ${SSH_HOST}:${SSH_PORT}"

  # SSH_EXTRA_OPTS is intentionally word-split to support several -o options.
  # shellcheck disable=SC2086
  ssh \
    -n \
    -T \
    -4 \
    -w "${LOCAL_TUN_ID}:${REMOTE_TUN_ID}" \
    -p "$SSH_PORT" \
    -i "$IDENTITY_FILE" \
    -o BatchMode=yes \
    -o IdentitiesOnly=yes \
    -o Tunnel=point-to-point \
    -o ExitOnForwardFailure=yes \
    -o ConnectTimeout="$CONNECT_TIMEOUT" \
    -o ServerAliveInterval="$SERVER_ALIVE_INTERVAL" \
    -o ServerAliveCountMax="$SERVER_ALIVE_COUNT_MAX" \
    -o StrictHostKeyChecking="$STRICT_HOST_KEY_CHECKING" \
    -o UserKnownHostsFile="$KNOWN_HOSTS_FILE" \
    $SSH_EXTRA_OPTS \
    "${SSH_USER}@${SSH_HOST}" "$REMOTE_COMMAND" &

  ssh_pid="$!"
  tunnel_ready=0
  if ! wait_for_tunnel; then
    log "SSH did not create $TUN_INTERFACE within ${TUN_WAIT_TIMEOUT}s"
    kill "$ssh_pid" 2>/dev/null || true
  elif ! configure_tunnel; then
    log "ERROR: failed to configure $TUN_INTERFACE"
    kill "$ssh_pid" 2>/dev/null || true
  elif ! start_socks; then
    log "ERROR: failed to start SOCKS5"
    kill "$ssh_pid" 2>/dev/null || true
  else
    tunnel_ready=1
    log "Tunnel is ready: default route via ${TUN_REMOTE}, gateway=${gateway_enabled}, NAT=${nat_enabled}, SOCKS=${socks_enabled}"
  fi

  if [ "$tunnel_ready" -eq 1 ]; then
    monitor_session || true
  fi

  ssh_status=0
  wait "$ssh_pid" || ssh_status="$?"
  ssh_pid=""
  stop_socks
  restore_underlay_default

  [ "$stop_requested" -eq 0 ] || break
  log "SSH exited with status ${ssh_status}; reconnecting in ${RECONNECT_DELAY}s"
  sleep "$RECONNECT_DELAY"
done

log "SSH TUN container stopped"
