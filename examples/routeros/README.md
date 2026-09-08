# RouterOS examples

These scripts are templates, not commands to import unchanged.

- `container-only.rsc` creates the VETH, bridge, environment list, mount, and
  container. It intentionally leaves LAN routing to the administrator.
- `policy-routing.rsc` adds an example policy-routing table, one test client,
  DNS redirection, NAT, and firewall rules.

Before importing either file, review at least the SSH server address and port,
container network, LAN CIDRs, tunnel addresses, SSH account, remote TUN number,
image path, and storage paths. The included `203.0.113.0/24` addresses are
documentation examples and will not reach a real server.

MikroTik RB4011 uses the `linux/arm/v7` image. Download
`ssh-tun-gateway-armv7.tar` from
[release v0.1.0](https://github.com/killdns/ssh-tun-gateway/releases/tag/v0.1.0),
upload it to the router, and mount a directory containing only the client's
`id_ed25519` and verified `known_hosts` files. Other release assets provide
archives for `linux/arm64` and `linux/amd64`.

When `RUN_MODE=socks` or `RUN_MODE=both` is selected, allow trusted clients to
reach TCP port `1080` and the configured UDP relay range on the container IP.
Do not expose either to WAN.
