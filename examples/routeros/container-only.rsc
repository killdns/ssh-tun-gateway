# Запуск первого SSH TUN контейнера без настройки маршрутизации LAN.
# Для RB4011 используется образ ARMv7.

:local serverIp "203.0.113.10"
:local serverPort "22"
:local containerBridge "containers"
:local containerVeth "veth-ssh-tun-1"
:local containerAddress "172.18.0.20/24"
:local containerIp "172.18.0.20"
:local containerGateway "172.18.0.1"
:local containerGatewayCidr "172.18.0.1/24"
:local containerSubnet "172.18.0.0/24"
:local envList "ENV_SSH_TUN_1"
:local mountList "MOUNT_SSH_TUN_1"
:local imageTar "disk1/ssh-tun-gateway-armv7.tar"
:local rootDir "disk1/images/ssh-tun-gateway-1"
:local configDir "disk1/ssh-tun-1"
:local runMode "gateway"
:local socksBind "0.0.0.0"
:local socksPort "1080"
:local socksUser ""
:local socksPassword ""
:local socksAllowNoAuth "1"
:local socksDnsServer "1.1.1.1"
:local socksWorkers "2"
:local socksUdpPortMin "20000"
:local socksUdpPortMax "20999"
:local socksUdpAdvertiseIp ""

:if ([:len [/interface/veth/find where name=$containerVeth]] = 0) do={
    /interface/veth/add name=$containerVeth address=$containerAddress gateway=$containerGateway
}
:if ([:len [/interface/bridge/find where name=$containerBridge]] = 0) do={
    /interface/bridge/add name=$containerBridge
}
:if ([:len [/ip/address/find where interface=$containerBridge]] = 0) do={
    /ip/address/add address=$containerGatewayCidr interface=$containerBridge
}
:if ([:len [/interface/bridge/port/find where interface=$containerVeth]] = 0) do={
    /interface/bridge/port/add bridge=$containerBridge interface=$containerVeth
}

# Разрешаем только управляющее SSH-соединение контейнера через обычный WAN.
:if ([:len [/ip/firewall/nat/find where comment="SSH TUN 1: NAT транспорта"]] = 0) do={
    /ip/firewall/nat/add chain=srcnat src-address=$containerSubnet dst-address=$serverIp protocol=tcp dst-port=$serverPort action=masquerade comment="SSH TUN 1: NAT транспорта"
}
:if ([:len [/ip/firewall/filter/find where comment="SSH TUN 1: разрешить транспорт"]] = 0) do={
    /ip/firewall/filter/add chain=forward src-address=$containerIp dst-address=$serverIp protocol=tcp dst-port=$serverPort action=accept place-before=0 comment="SSH TUN 1: разрешить транспорт"
}
:if ([:len [/ip/firewall/filter/find where comment="SSH TUN 1: разрешить ответ"]] = 0) do={
    /ip/firewall/filter/add chain=forward dst-address=$containerIp src-address=$serverIp protocol=tcp src-port=$serverPort connection-state=established,related action=accept place-before=0 comment="SSH TUN 1: разрешить ответ"
}

:if ([:len [/container/mounts/find where list=$mountList]] = 0) do={
    /container/mounts/add list=$mountList src=$configDir dst=/config
}

:if ([:len [/container/envs/find where list=$envList]] = 0) do={
    /container/envs/add list=$envList key=RUN_MODE value=$runMode
    /container/envs/add list=$envList key=SSH_HOST value=$serverIp
    /container/envs/add list=$envList key=SSH_ROUTE_IP value=$serverIp
    /container/envs/add list=$envList key=SSH_USER value="ssh-tunnel-1"
    /container/envs/add list=$envList key=SSH_PORT value=$serverPort
    /container/envs/add list=$envList key=CONTAINER_GATEWAY value=$containerGateway
    /container/envs/add list=$envList key=LAN_CIDRS value="10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
    /container/envs/add list=$envList key=LOCAL_TUN_ID value="0"
    /container/envs/add list=$envList key=REMOTE_TUN_ID value="0"
    /container/envs/add list=$envList key=TUN_LOCAL value="10.255.255.2"
    /container/envs/add list=$envList key=TUN_REMOTE value="10.255.255.1"
    /container/envs/add list=$envList key=TUN_MTU value="1400"
    /container/envs/add list=$envList key=ENABLE_NAT value="1"
    /container/envs/add list=$envList key=SOCKS_BIND value=$socksBind
    /container/envs/add list=$envList key=SOCKS_PORT value=$socksPort
    /container/envs/add list=$envList key=SOCKS_USER value=$socksUser
    /container/envs/add list=$envList key=SOCKS_PASSWORD value=$socksPassword
    /container/envs/add list=$envList key=SOCKS_ALLOW_NO_AUTH value=$socksAllowNoAuth
    /container/envs/add list=$envList key=SOCKS_DNS_SERVER value=$socksDnsServer
    /container/envs/add list=$envList key=SOCKS_WORKERS value=$socksWorkers
    /container/envs/add list=$envList key=SOCKS_UDP_PORT_MIN value=$socksUdpPortMin
    /container/envs/add list=$envList key=SOCKS_UDP_PORT_MAX value=$socksUdpPortMax
    /container/envs/add list=$envList key=SOCKS_UDP_ADVERTISE_IP value=$socksUdpAdvertiseIp
}

:if ([:len [/container/find where name="ssh-tun-gateway-1"]] = 0) do={
    /container/add file=$imageTar interface=$containerVeth root-dir=$rootDir mountlists=$mountList envlist=$envList name="ssh-tun-gateway-1" user=0:0 start-on-boot=yes logging=yes
}
/container/start [find where name="ssh-tun-gateway-1"]

# Маршруты, mangle, DNS и правила транзитного трафика здесь намеренно отсутствуют.
# В режимах socks и both пустые socksUser/socksPassword означают работу без
# авторизации. Не открывайте SOCKS-порт в Интернет.
# Для UDP ASSOCIATE разрешите доверенным клиентам UDP 20000-20999 к containerIp.
