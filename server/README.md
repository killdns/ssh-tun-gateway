# Linux server setup

[Русская версия](README_RU.md)

These templates configure multiple restricted OpenSSH accounts that may attach
only to their assigned point-to-point TUN devices. Keep an existing
administrative SSH session open until `sshd -t` succeeds.

The commands below assume Ubuntu or Debian and are run from this `server`
directory.

## Install dependencies and accounts

```sh
sudo apt update
sudo apt install -y openssh-server iproute2 iptables sudo

sudo groupadd --system ssh-tunnel-clients
sudo useradd --create-home --user-group --shell /bin/bash \
  --groups ssh-tunnel-clients ssh-tunnel-1
sudo passwd --lock ssh-tunnel-1
```

## Install the templates

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

Find the public network interface and set it as `WAN_INTERFACE` in the client
configuration:

```sh
ip route show default
sudoedit /etc/ssh-tun-gateway/ssh-tunnel-1.conf
```

Files in `/etc/ssh-tun-gateway` are sourced by root and must remain root-owned
and non-writable by tunnel users.

## Create the persistent TUN device

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now ssh-tun-device@ssh-tunnel-1.service
ip tuntap show dev tun0
```

The persistent device is required because SSH requests a TUN device before its
forced command runs as root. Ownership lets the restricted account attach to
its device without granting general root access.

## Authorize one client key

```sh
sudo install -d -o ssh-tunnel-1 -g ssh-tunnel-1 -m 0700 \
  /home/ssh-tunnel-1/.ssh
sudoedit /home/ssh-tunnel-1/.ssh/authorized_keys
```

Prefix the client's public key with the assigned server TUN number:

```text
tunnel="0",no-agent-forwarding,no-port-forwarding,no-X11-forwarding,no-pty ssh-ed25519 AAAA... client-1
```

Then fix ownership and permissions:

```sh
sudo chown ssh-tunnel-1:ssh-tunnel-1 \
  /home/ssh-tunnel-1/.ssh/authorized_keys
sudo chmod 0600 /home/ssh-tunnel-1/.ssh/authorized_keys
```

## Validate and reload OpenSSH

```sh
sudo visudo -cf /etc/sudoers.d/ssh-tunnel
sudo sshd -t
sudo systemctl reload ssh
```

Expected effective restrictions:

```sh
sudo sshd -T -C user=ssh-tunnel-1,host=localhost,addr=127.0.0.1 \
  | grep -E 'permittunnel|forcecommand|passwordauthentication|allowtcpforwarding|clientalive'
```

The result should include `permittunnel point-to-point`,
`passwordauthentication no`, `allowtcpforwarding no`, and the forced session
command. `clientaliveinterval 15` and `clientalivecountmax 3` release a TUN
within approximately 45 seconds after a client disappears without closing its
SSH connection.

Limit the SSH port at the server firewall to known client source addresses.

## Recover after a hard client reboot

SSH status `255` is a generic connection failure. First inspect the OpenSSH
message immediately before it in the container log. If the server reports
`Tunnel device open failed`, or a reconnect cannot attach to its assigned
`tunN`, the old `sshd` process may still consider the interrupted session alive.

For a dedicated tunnel account, terminate the stale session with:

```sh
ps -eo pid,user,args | grep '[s]shd: ssh-tunnel-1'
sudo pkill -TERM -u ssh-tunnel-1 || true
sleep 5
ps -eo pid,user,args | grep '[s]shd: ssh-tunnel-1' || true
```

The container reconnects automatically. Do not delete the persistent `tun0` or
restart its systemd service: the stale SSH session, not the TUN device itself,
is the problem. The server-side keepalive settings above prevent the interface
from remaining occupied for long after future hard reboots.

## Add more clients

Each client needs a unique account, key, `tunN`, `REMOTE_TUN_ID=N`, and `/30`
network. For example, client two uses:

```text
server device: tun1
server/client addresses: 10.255.255.5 / 10.255.255.6
network: 10.255.255.4/30
authorized_keys prefix: tunnel="1",...
```

Copy `ssh-tunnel-2.conf.example`, create `ssh-tunnel-2`, and start
`ssh-tun-device@ssh-tunnel-2.service`. Never share private keys between clients.
