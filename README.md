# SSH TUN Gateway

[Русская версия](README_RU.md)

`ssh-tun-gateway` is a small Linux container that creates an IPv4 point-to-point
OpenSSH TUN tunnel and can expose the tunnel as:

- an L3 gateway for routed TCP, UDP, and DNS traffic;
- a SOCKS5 proxy with TCP `CONNECT` and UDP `ASSOCIATE`;
- both at the same time.

```text
LAN client -> router or Docker host -> container -> OpenSSH TUN -> Linux server -> Internet
```

The SOCKS5 service is provided by
[HevSocks5Server](https://github.com/heiher/hev-socks5-server). It is built
statically from a pinned release archive whose SHA-256 checksum is verified
during the image build.

## Supported platforms

| Platform | Typical target |
| --- | --- |
| `linux/amd64` | x86-64 servers and PCs |
| `linux/arm64` | 64-bit ARM routers and single-board computers |
| `linux/arm/v7` | 32-bit ARM devices, including MikroTik RB4011 |

Published tags are multi-platform images, so Docker selects the correct
variant automatically.

## Operating modes

| `RUN_MODE` | L3 gateway | SOCKS5 |
| --- | --- | --- |
| `gateway` | yes | no |
| `socks` | no | yes |
| `both` | yes | yes |

The default mode is `gateway`. Every mode still uses the OpenSSH TUN tunnel;
the SOCKS5 server opens its outbound connections through that tunnel.

## Requirements

### Container host

- Linux with `/dev/net/tun`.
- Docker, Podman, or a container runtime with equivalent networking support.
- The `NET_ADMIN` capability.
- An individual SSH private key and a verified `known_hosts` file.

### SSH server

- Linux with OpenSSH server, `iproute2`, `iptables`, and `sudo`.
- `PermitTunnel point-to-point` for restricted tunnel accounts.
- IPv4 forwarding and outbound NAT.
- One persistent server-side TUN device and one `/30` network per client.

The templates in [server](server) configure restricted accounts without shell,
PTY, agent, X11, or TCP forwarding access. See
[server/README.md](server/README.md).

## Quick start with Docker Compose

1. Copy [examples/compose.yaml](examples/compose.yaml) into a deployment
   directory and copy [examples/env.example](examples/env.example) there as
   `.env`.
2. Create a `config` directory containing:

   ```text
   config/id_ed25519
   config/known_hosts
   ```

3. Set restrictive permissions on the private key and edit `.env` for your
   network.
4. Replace `ghcr.io/OWNER/ssh-tun-gateway:latest` in `compose.yaml` with the
   published image name.
5. Start the container:

   ```sh
   docker compose up -d
   docker compose logs -f
   ```

For a direct `docker run` deployment:

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

## Core environment variables

| Variable | Description |
| --- | --- |
| `SSH_HOST` | Numeric IPv4 address of the SSH server |
| `CONTAINER_GATEWAY` | Original gateway in the container network |
| `LAN_CIDRS` | Comma-separated networks that must remain reachable outside the TUN |

`LAN_CIDRS` is required even in `socks` mode. The container moves its default
route into the tunnel, so explicit return routes to SOCKS clients are necessary.

## Tunnel settings

| Variable | Default | Description |
| --- | --- | --- |
| `SSH_ROUTE_IP` | `SSH_HOST` | Server address pinned to the original gateway |
| `SSH_USER` | `ssh-tunnel` | Restricted SSH tunnel account |
| `SSH_PORT` | `22` | SSH server port |
| `UPLINK_INTERFACE` | automatic | Original uplink interface |
| `IDENTITY_FILE` | `/config/id_ed25519` | Private SSH key |
| `KNOWN_HOSTS_FILE` | `/config/known_hosts` | Verified OpenSSH host keys |
| `STRICT_HOST_KEY_CHECKING` | `yes` | OpenSSH host key policy |
| `LOCAL_TUN_ID` | `0` | Container-side TUN number |
| `REMOTE_TUN_ID` | `0` | Server-side TUN number |
| `TUN_LOCAL` | `10.255.255.2` | Container TUN address |
| `TUN_REMOTE` | `10.255.255.1` | Server TUN address |
| `TUN_MTU` | `1400` | Tunnel MTU |
| `ENABLE_NAT` | `1` | Masquerade routed LAN clients behind `TUN_LOCAL` |

Each client must have a unique `SSH_USER`, SSH key, `REMOTE_TUN_ID`, and `/30`
network. `LOCAL_TUN_ID=0` may be reused because containers have separate network
namespaces.

## SOCKS5 settings

| Variable | Default | Description |
| --- | --- | --- |
| `SOCKS_BIND` | `0.0.0.0` | SOCKS5 listen address |
| `SOCKS_PORT` | `1080` | TCP control and `CONNECT` port |
| `SOCKS_USER` | empty | Optional username |
| `SOCKS_PASSWORD` | empty | Optional password |
| `SOCKS_ALLOW_NO_AUTH` | `1` | Permit startup without credentials |
| `SOCKS_DNS_SERVER` | `1.1.1.1` | Resolver used after the TUN is established |
| `SOCKS_WORKERS` | `2` | HevSocks5Server worker count |
| `SOCKS_UDP_PORT_MIN` | `20000` | First UDP relay port |
| `SOCKS_UDP_PORT_MAX` | `20999` | Last UDP relay port |
| `SOCKS_UDP_ADVERTISE_IP` | empty | Relay address returned to UDP clients |

For a few trusted clients, a smaller UDP range such as `20000-20031` is usually
enough. Allow TCP `1080` and the selected UDP range only from trusted networks.

`SOCKS_UDP_ADVERTISE_IP` should stay empty when clients route directly to the
container address. Set it to the host or router address only when clients reach
the proxy through destination NAT, and forward the complete UDP range to the
container as well.

SOCKS5 UDP requires client-side `UDP ASSOCIATE` support. A browser's basic SOCKS
setting often proxies TCP only. For transparent whole-device UDP, use
`RUN_MODE=gateway` or `RUN_MODE=both` and route the device through the container.

## MikroTik notes

RouterOS examples are under [examples/routeros](examples/routeros):

- `container-only.rsc` creates the container without changing LAN routing;
- `policy-routing.rsc` also demonstrates policy routing and DNS redirection.

Review every variable before importing a script. The files contain documentation
addresses, not deployment values. For an RB4011, use the `linux/arm/v7` image.

To create a RouterOS-compatible TAR from a published multi-platform image:

```sh
docker pull --platform linux/arm/v7 ghcr.io/OWNER/ssh-tun-gateway:1.0.0
docker save -o ssh-tun-gateway-armv7.tar ghcr.io/OWNER/ssh-tun-gateway:1.0.0
```

## Building locally

Build one architecture into the local Docker image store:

```sh
docker buildx build --platform linux/amd64 -t ssh-tun-gateway:amd64 --load .
docker buildx build --platform linux/arm64 -t ssh-tun-gateway:arm64 --load .
docker buildx build --platform linux/arm/v7 -t ssh-tun-gateway:armv7 --load .
```

Build all variants and push a multi-platform manifest:

```sh
docker buildx build \
  --platform linux/amd64,linux/arm64,linux/arm/v7 \
  -t REGISTRY/OWNER/ssh-tun-gateway:VERSION --push .
```

## Publishing from GitHub Actions

The release workflow publishes the same multi-platform image to:

- `ghcr.io/<github-owner>/ssh-tun-gateway`;
- `<dockerhub-username>/ssh-tun-gateway` on Docker Hub.

Configure the following repository settings:

| Type | Name | Value |
| --- | --- | --- |
| GitHub Actions variable | `DOCKERHUB_USERNAME` | Docker Hub account name |
| GitHub Actions secret | `DOCKERHUB_TOKEN` | Docker Hub access token with write access |

Create the `ssh-tun-gateway` repository on Docker Hub before the first release.
GHCR authentication uses the automatically generated `GITHUB_TOKEN`.

Push a semantic version tag to publish:

```sh
git tag -a v1.0.0 -m "Release v1.0.0"
git push origin v1.0.0
```

The workflow publishes `1.0.0`, `1.0`, `1`, and `latest` tags and attaches an
SBOM plus maximum-level build provenance. A manual run may publish a custom tag
such as `edge` without changing `latest`.

## Security

The container is a network component with elevated privileges even though the
SOCKS process runs as an unprivileged user. Read [SECURITY.md](SECURITY.md)
before deployment.
In particular:

- never publish an unauthenticated SOCKS endpoint to the Internet;
- never reuse a private SSH key across clients;
- never disable host key checking in production;
- keep the SSH server account restricted and retain `AllowTcpForwarding no`.

## License

This project is licensed under the [MIT License](LICENSE). HevSocks5Server is
also MIT-licensed; its license is copied into the container image.
