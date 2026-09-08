# SSH TUN Gateway

[English](README.md)

`ssh-tun-gateway` - небольшой Linux-контейнер, который поднимает IPv4-туннель
OpenSSH TUN типа point-to-point и может предоставлять его как:

- L3-шлюз для маршрутизируемого TCP, UDP и DNS-трафика;
- SOCKS5-прокси с командами TCP `CONNECT` и UDP `ASSOCIATE`;
- шлюз и SOCKS5 одновременно.

```text
клиент LAN -> маршрутизатор или Docker-хост -> контейнер -> OpenSSH TUN -> Linux-сервер -> Интернет
```

Для SOCKS5 используется
[HevSocks5Server](https://github.com/heiher/hev-socks5-server). Он статически
собирается из закреплённого релиза, SHA-256 которого проверяется во время сборки
образа.

## Поддерживаемые платформы

| Платформа | Типичное устройство |
| --- | --- |
| `linux/amd64` | серверы и компьютеры x86-64 |
| `linux/arm64` | 64-битные ARM-устройства |
| `linux/arm/v7` | 32-битные ARM-устройства, включая MikroTik RB4011 |

Публикуемый тег содержит единый multi-platform manifest: Docker сам выбирает
подходящий вариант.

## Режимы работы

| `RUN_MODE` | L3-шлюз | SOCKS5 |
| --- | --- | --- |
| `gateway` | да | нет |
| `socks` | нет | да |
| `both` | да | да |

По умолчанию используется `gateway`. В любом режиме сначала поднимается OpenSSH
TUN; исходящие соединения SOCKS5 также проходят через этот туннель.

## Требования

### Хост контейнера

- Linux и устройство `/dev/net/tun`.
- Docker, Podman или совместимая контейнерная среда.
- Capability `NET_ADMIN`.
- Отдельный приватный SSH-ключ и проверенный файл `known_hosts`.

### SSH-сервер

- Linux с OpenSSH server, `iproute2`, `iptables` и `sudo`.
- `PermitTunnel point-to-point` для ограниченных туннельных пользователей.
- Включённая IPv4-маршрутизация и NAT во внешний интерфейс.
- Отдельный постоянный TUN-интерфейс и сеть `/30` для каждого клиента.

Шаблоны из каталога [server](server) создают схему без shell, PTY, SSH agent,
X11 и TCP forwarding. Подробности находятся в
[server/README_RU.md](server/README_RU.md).

## Быстрый запуск через Docker Compose

1. Возьмите [examples/compose.yaml](examples/compose.yaml) и
   [examples/env.example](examples/env.example).
2. Создайте рядом каталог `config`:

   ```text
   config/id_ed25519
   config/known_hosts
   ```

3. Переименуйте `env.example` в `.env` и укажите свои адреса.
4. В `compose.yaml` замените `ghcr.io/OWNER/ssh-tun-gateway:latest` на имя
   опубликованного образа.
5. Запустите контейнер:

   ```sh
   docker compose up -d
   docker compose logs -f
   ```

Прямой запуск через Docker:

```sh
docker run -d \
  --name ssh-tun-gateway \
  --restart unless-stopped \
  --cap-add NET_ADMIN \
  --device /dev/net/tun:/dev/net/tun \
  --env-file .env \
  --mount type=bind,src="$PWD/config",dst=/config,readonly \
  ghcr.io/OWNER/ssh-tun-gateway:latest
```

## Основные переменные

| Переменная | Назначение |
| --- | --- |
| `SSH_HOST` | числовой IPv4-адрес SSH-сервера |
| `CONTAINER_GATEWAY` | исходный шлюз контейнерной сети |
| `LAN_CIDRS` | сети через запятую, которые должны остаться доступны вне TUN |

`LAN_CIDRS` нужен даже при `RUN_MODE=socks`: после замены маршрута по умолчанию
контейнеру необходимы явные обратные маршруты к клиентам SOCKS5.

## Настройки туннеля

| Переменная | По умолчанию | Назначение |
| --- | --- | --- |
| `SSH_ROUTE_IP` | `SSH_HOST` | адрес сервера, закреплённый за исходным шлюзом |
| `SSH_USER` | `ssh-tunnel` | ограниченный пользователь туннеля |
| `SSH_PORT` | `22` | порт SSH-сервера |
| `UPLINK_INTERFACE` | автоматически | исходный uplink-интерфейс |
| `IDENTITY_FILE` | `/config/id_ed25519` | приватный SSH-ключ |
| `KNOWN_HOSTS_FILE` | `/config/known_hosts` | проверенные ключи SSH-сервера |
| `STRICT_HOST_KEY_CHECKING` | `yes` | политика проверки ключа сервера |
| `LOCAL_TUN_ID` | `0` | номер TUN внутри контейнера |
| `REMOTE_TUN_ID` | `0` | номер TUN на сервере |
| `TUN_LOCAL` | `10.255.255.2` | адрес контейнера в TUN |
| `TUN_REMOTE` | `10.255.255.1` | адрес сервера в TUN |
| `TUN_MTU` | `1400` | MTU туннеля |
| `ENABLE_NAT` | `1` | маскарадинг LAN-клиентов за адресом `TUN_LOCAL` |

Для каждого клиента нужны отдельные `SSH_USER`, ключ, `REMOTE_TUN_ID` и сеть
`/30`. Значение `LOCAL_TUN_ID=0` можно повторять в разных контейнерах, поскольку
у них отдельные сетевые пространства имён.

## Настройки SOCKS5

| Переменная | По умолчанию | Назначение |
| --- | --- | --- |
| `SOCKS_BIND` | `0.0.0.0` | адрес прослушивания SOCKS5 |
| `SOCKS_PORT` | `1080` | TCP-порт управления и `CONNECT` |
| `SOCKS_USER` | пусто | необязательный логин |
| `SOCKS_PASSWORD` | пусто | необязательный пароль |
| `SOCKS_ALLOW_NO_AUTH` | `1` | разрешить запуск без авторизации |
| `SOCKS_DNS_SERVER` | `1.1.1.1` | DNS после поднятия TUN |
| `SOCKS_WORKERS` | `2` | число потоков HevSocks5Server |
| `SOCKS_UDP_PORT_MIN` | `20000` | начало диапазона UDP-релеев |
| `SOCKS_UDP_PORT_MAX` | `20999` | конец диапазона UDP-релеев |
| `SOCKS_UDP_ADVERTISE_IP` | пусто | адрес UDP-релея, сообщаемый клиенту |

Для нескольких доверенных клиентов обычно достаточно диапазона
`20000-20031`. Разрешайте TCP `1080` и UDP-диапазон только из доверенных сетей.

При прямой маршрутизации к IP контейнера оставьте `SOCKS_UDP_ADVERTISE_IP`
пустым. Если клиенты подключаются через `dst-nat`, укажите доступный им адрес
хоста или маршрутизатора и перенаправьте в контейнер весь UDP-диапазон.

Клиентское приложение должно поддерживать SOCKS5 `UDP ASSOCIATE`. Простая
настройка SOCKS в браузере нередко проксирует только TCP. Для прозрачного UDP
всего устройства используйте `RUN_MODE=gateway` или `RUN_MODE=both` и
маршрутизируйте устройство через контейнер.

## MikroTik

Примеры RouterOS находятся в [examples/routeros](examples/routeros):

- `container-only.rsc` создаёт контейнер и не меняет маршрутизацию LAN;
- `policy-routing.rsc` дополнительно показывает policy routing и перехват DNS.

Перед импортом проверьте каждую переменную. В файлах используются тестовые
адреса, а не значения конкретного сервера. Для RB4011 нужен `linux/arm/v7`.

Создание TAR для импорта в RouterOS из опубликованного образа:

```sh
docker pull --platform linux/arm/v7 ghcr.io/OWNER/ssh-tun-gateway:1.0.0
docker save -o ssh-tun-gateway-armv7.tar ghcr.io/OWNER/ssh-tun-gateway:1.0.0
```

## Локальная сборка

```sh
docker buildx build --platform linux/amd64 -t ssh-tun-gateway:amd64 --load .
docker buildx build --platform linux/arm64 -t ssh-tun-gateway:arm64 --load .
docker buildx build --platform linux/arm/v7 -t ssh-tun-gateway:armv7 --load .
```

Публикация общего multi-platform manifest вручную:

```sh
docker buildx build \
  --platform linux/amd64,linux/arm64,linux/arm/v7 \
  -t REGISTRY/OWNER/ssh-tun-gateway:VERSION --push .
```

## Публикация через GitHub Actions

Release-workflow публикует один и тот же образ в:

- `ghcr.io/<github-owner>/ssh-tun-gateway`;
- `<dockerhub-username>/ssh-tun-gateway` на Docker Hub.

В настройках GitHub-репозитория добавьте:

| Тип | Имя | Значение |
| --- | --- | --- |
| Actions variable | `DOCKERHUB_USERNAME` | имя учётной записи Docker Hub |
| Actions secret | `DOCKERHUB_TOKEN` | токен Docker Hub с правом записи |

Перед первым запуском создайте репозиторий `ssh-tun-gateway` на Docker Hub.
Для GHCR используется автоматически созданный `GITHUB_TOKEN`.

Публикация версии:

```sh
git tag -a v1.0.0 -m "Release v1.0.0"
git push origin v1.0.0
```

Будут опубликованы теги `1.0.0`, `1.0`, `1` и `latest`, а также SBOM и
provenance сборки. Ручной запуск workflow позволяет выпустить отдельный тег,
например `edge`, не изменяя `latest`.

## Безопасность

Контейнер требует `NET_ADMIN` и является сетевым компонентом с повышенными
правами, хотя сам SOCKS-процесс запускается от непривилегированного пользователя.
Перед развёртыванием прочитайте [SECURITY.md](SECURITY.md).

- Не открывайте SOCKS без авторизации в Интернет.
- Не используйте один приватный SSH-ключ на нескольких клиентах.
- Не отключайте проверку ключа SSH-сервера в рабочей конфигурации.
- Оставьте на сервере `AllowTcpForwarding no`.

## Лицензия

Проект распространяется по [лицензии MIT](LICENSE). HevSocks5Server также
использует MIT; его лицензия копируется внутрь контейнерного образа.
