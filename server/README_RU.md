# Настройка Linux-сервера

[English](README.md)

Шаблоны настраивают несколько ограниченных пользователей OpenSSH. Каждый из них
может подключиться только к своему point-to-point TUN-интерфейсу. Пока не
выполнена проверка `sshd -t`, не закрывайте текущую административную SSH-сессию.

Команды ниже рассчитаны на Ubuntu или Debian и выполняются из каталога `server`.

## Зависимости и пользователь

```sh
sudo apt update
sudo apt install -y openssh-server iproute2 iptables sudo

sudo groupadd --system ssh-tunnel-clients
sudo useradd --create-home --user-group --shell /bin/bash \
  --groups ssh-tunnel-clients ssh-tunnel-1
sudo passwd --lock ssh-tunnel-1
```

## Установка файлов

```sh
sudo install -o root -g root -m 0755 ssh-tun-device /usr/local/sbin/ssh-tun-device
sudo install -o root -g root -m 0755 ssh-tun-session /usr/local/sbin/ssh-tun-session
sudo install -o root -g root -m 0440 ssh-tunnel.sudoers /etc/sudoers.d/ssh-tunnel
sudo install -o root -g root -m 0644 99-ssh-tunnel.conf /etc/ssh/sshd_config.d/99-ssh-tunnel.conf
sudo install -o root -g root -m 0644 ssh-tun-device@.service /etc/systemd/system/ssh-tun-device@.service
sudo install -d -o root -g root -m 0755 /etc/ssh-tun-gateway
sudo install -o root -g root -m 0644 ssh-tunnel-1.conf.example \
  /etc/ssh-tun-gateway/ssh-tunnel-1.conf
```

Определите внешний интерфейс и укажите его в `WAN_INTERFACE`:

```sh
ip route show default
sudoedit /etc/ssh-tun-gateway/ssh-tunnel-1.conf
```

Файлы `/etc/ssh-tun-gateway` загружаются процессом с правами root. Они должны
принадлежать `root:root` и не должны быть доступны туннельным пользователям для
записи.

## Постоянный TUN-интерфейс

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now ssh-tun-device@ssh-tunnel-1.service
ip tuntap show dev tun0
```

Постоянный интерфейс обязателен: OpenSSH запрашивает TUN до запуска принудительной
команды с правами root. Владелец интерфейса может подключиться к нему без выдачи
общих привилегий root.

## Публичный ключ клиента

```sh
sudo install -d -o ssh-tunnel-1 -g ssh-tunnel-1 -m 0700 \
  /home/ssh-tunnel-1/.ssh
sudoedit /home/ssh-tunnel-1/.ssh/authorized_keys
```

Перед публичным ключом укажите номер серверного TUN:

```text
tunnel="0",no-agent-forwarding,no-port-forwarding,no-X11-forwarding,no-pty ssh-ed25519 AAAA... client-1
```

Исправьте права:

```sh
sudo chown ssh-tunnel-1:ssh-tunnel-1 \
  /home/ssh-tunnel-1/.ssh/authorized_keys
sudo chmod 0600 /home/ssh-tunnel-1/.ssh/authorized_keys
```

## Проверка OpenSSH

```sh
sudo visudo -cf /etc/sudoers.d/ssh-tunnel
sudo sshd -t
sudo systemctl reload ssh
```

Проверьте итоговые ограничения:

```sh
sudo sshd -T -C user=ssh-tunnel-1,host=localhost,addr=127.0.0.1 \
  | grep -E 'permittunnel|forcecommand|passwordauthentication|allowtcpforwarding|clientalive'
```

Должны присутствовать `permittunnel point-to-point`,
`passwordauthentication no`, `allowtcpforwarding no` и принудительная команда
сессии. Параметры `clientaliveinterval 15` и `clientalivecountmax 3` освобождают
TUN не позднее чем примерно через 45 секунд после внезапного исчезновения
клиента. На межсетевом экране сервера ограничьте SSH-порт известными внешними
адресами клиентов.

## Восстановление после жёсткой перезагрузки клиента

Код SSH `255` означает общую ошибку подключения. Сначала найдите конкретное
сообщение OpenSSH непосредственно перед ним в журнале контейнера. Если сервер
пишет `Tunnel device open failed` или новый клиент не может занять свой `tunN`,
старый процесс `sshd`, вероятно, ещё считает оборванную сессию активной.

Для отдельной учётной записи туннеля старую сессию можно завершить так:

```sh
ps -eo pid,user,args | grep '[s]shd: ssh-tunnel-1'
sudo pkill -TERM -u ssh-tunnel-1 || true
sleep 5
ps -eo pid,user,args | grep '[s]shd: ssh-tunnel-1' || true
```

Контейнер повторяет подключение автоматически. Не удаляйте постоянный `tun0` и
не перезапускайте его systemd-сервис: проблема находится в старой SSH-сессии, а
не в самом TUN-интерфейсе. Установленные выше server-side keepalive-параметры
предотвращают длительное удержание интерфейса при следующих аварийных
перезагрузках.

## Следующие клиенты

Каждому клиенту нужны отдельные пользователь, ключ, `tunN`, `REMOTE_TUN_ID=N` и
сеть `/30`. Для второго клиента:

```text
серверный интерфейс: tun1
адреса сервер/клиент: 10.255.255.5 / 10.255.255.6
сеть: 10.255.255.4/30
префикс authorized_keys: tunnel="1",...
```

Создайте пользователя `ssh-tunnel-2`, установите его конфигурацию из
`ssh-tunnel-2.conf.example` и запустите
`ssh-tun-device@ssh-tunnel-2.service`. Не используйте один приватный ключ для
нескольких клиентов.
