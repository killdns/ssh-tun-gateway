# Шаблон RouterOS: выбранные IPv4-клиенты -> шлюз через SSH TUN.
# Для RB4011 нужен архив ARMv7. Сначала измените все значения в этом блоке.

:local serverIp "203.0.113.10"
:local serverPort "22"
:local containerBridge "containers"
:local containerVeth "veth-ssh-tun"
:local containerAddress "172.18.0.20/24"
:local containerIp "172.18.0.20"
:local containerGateway "172.18.0.1"
:local containerSubnet "172.18.0.0/24"
:local lanCidrs "192.168.88.0/24"
:local testClient "192.168.88.10"
:local forcedDns "1.1.1.1"
:local routingTable "via_ssh_tun"
:local policyList "SSH_TUN_CLIENTS"
:local connectionMark "ssh_tun"
:local envList "ENV_SSH_TUN"
:local mountList "MOUNT_SSH_TUN"
:local imageTar "disk1/ssh-tun-gateway-armv7.tar"
:local rootDir "disk1/images/ssh-tun-gateway"
:local configDir "disk1/ssh-tun"
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

# Повторно используем мост контейнеров, если его уже создал SOCKS-контейнер.
:if ([:len [/interface/veth/find where name=$containerVeth]] = 0) do={
    /interface/veth/add name=$containerVeth address=$containerAddress gateway=$containerGateway
}
:if ([:len [/interface/bridge/find where name=$containerBridge]] = 0) do={
    /interface/bridge/add name=$containerBridge
}
:if ([:len [/ip/address/find where interface=$containerBridge]] = 0) do={
    /ip/address/add address=($containerGateway . "/24") interface=$containerBridge
}
:if ([:len [/interface/bridge/port/find where interface=$containerVeth]] = 0) do={
    /interface/bridge/port/add bridge=$containerBridge interface=$containerVeth
}

# Управляющее SSH-соединение должно выходить через обычный WAN.
/ip/firewall/nat/add chain=srcnat src-address=$containerSubnet action=masquerade comment="NAT транспорта контейнера"
/ip/firewall/filter/add chain=forward src-address=$containerIp dst-address=$serverIp protocol=tcp dst-port=$serverPort action=accept place-before=0 comment="Разрешить транспорт SSH TUN"
/ip/firewall/filter/add chain=forward dst-address=$containerIp protocol=tcp src-port=$serverPort connection-state=established,related action=accept place-before=0 comment="Разрешить ответ транспорта SSH TUN"

# Подключаем id_ed25519 и known_hosts из disk1/ssh-tun.
/container/mounts/add list=$mountList src=$configDir dst=/config

/container/envs/add list=$envList key=RUN_MODE value=$runMode
/container/envs/add list=$envList key=SSH_HOST value=$serverIp
/container/envs/add list=$envList key=SSH_ROUTE_IP value=$serverIp
/container/envs/add list=$envList key=SSH_USER value="ssh-tunnel-1"
/container/envs/add list=$envList key=SSH_PORT value=$serverPort
/container/envs/add list=$envList key=CONTAINER_GATEWAY value=$containerGateway
/container/envs/add list=$envList key=LAN_CIDRS value=$lanCidrs
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

/container/add file=$imageTar interface=$containerVeth root-dir=$rootDir mountlists=$mountList envlist=$envList name=ssh-tun-gateway user=0:0 start-on-boot=yes logging=yes
/container/start ssh-tun-gateway

# Политика маршрутизации. Сначала добавляем одно тестовое устройство.
/routing/table/add name=$routingTable fib
/ip/route/add dst-address=0.0.0.0/0 gateway=$containerIp routing-table=$routingTable comment="Маршрут по умолчанию через SSH TUN"
/ip/firewall/address-list/add list=$policyList address=$testClient comment="Тестовый клиент SSH TUN"

# Маркируем DNS, даже когда клиент обращается к самому MikroTik. Остальные
# локальные службы роутера остаются вне туннеля, чтобы не потерять управление.
/ip/firewall/mangle/add chain=prerouting in-interface-list=LAN src-address-list=$policyList protocol=udp dst-port=53 connection-state=new connection-mark=no-mark action=mark-connection new-connection-mark=$connectionMark passthrough=yes comment="Маркировать DNS UDP для SSH TUN"
/ip/firewall/mangle/add chain=prerouting in-interface-list=LAN src-address-list=$policyList protocol=tcp dst-port=53 connection-state=new connection-mark=no-mark action=mark-connection new-connection-mark=$connectionMark passthrough=yes comment="Маркировать DNS TCP для SSH TUN"
/ip/firewall/mangle/add chain=prerouting in-interface-list=LAN src-address-list=$policyList dst-address-type=!local connection-state=new connection-mark=no-mark action=mark-connection new-connection-mark=$connectionMark passthrough=yes comment="Маркировать соединения SSH TUN"
/ip/firewall/mangle/add chain=prerouting in-interface-list=LAN src-address-list=$policyList connection-mark=$connectionMark action=mark-routing new-routing-mark=$routingTable passthrough=no comment="Политика маршрутизации SSH TUN"

# Принудительно направляем обычный DNS через ту же политику. DoH и DoT уже
# следуют маршруту клиента, но правило для порта 53 не может их перенаправить.
/ip/firewall/nat/add chain=dstnat in-interface-list=LAN src-address-list=$policyList protocol=udp dst-port=53 action=dst-nat to-addresses=$forcedDns to-ports=53 comment="Перенаправить DNS UDP через SSH TUN"
/ip/firewall/nat/add chain=dstnat in-interface-list=LAN src-address-list=$policyList protocol=tcp dst-port=53 action=dst-nat to-addresses=$forcedDns to-ports=53 comment="Перенаправить DNS TCP через SSH TUN"

# Эти правила должны находиться перед FastTrack и общим запретом forward. Они
# исключают маркированные соединения из FastTrack, использующего основную таблицу.
/ip/firewall/filter/add chain=forward connection-mark=$connectionMark out-interface=$containerBridge action=accept place-before=0 comment="Клиенты SSH TUN к контейнеру"
/ip/firewall/filter/add chain=forward connection-mark=$connectionMark in-interface=$containerBridge connection-state=established,related action=accept place-before=0 comment="Ответ контейнера SSH TUN"

# Существующие соединения сохраняют старые NAT и метки. После включения правил
# удалите только соединения тестового клиента или переподключите его.
# /ip/firewall/connection/remove [find where src-address~"192.168.88.10"]
