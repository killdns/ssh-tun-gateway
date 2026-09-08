# Security policy

## Reporting a vulnerability

Do not open a public issue for a vulnerability that could expose an SSH key,
an unrestricted proxy, or a remote gateway. Report it privately through the
repository owner's GitHub security advisory page.

## Deployment boundaries

- Never commit private SSH keys, passwords, `known_hosts`, or a populated
  `.env` file.
- Verify the SSH host key through an independent trusted channel before using
  it in `known_hosts`.
- Restrict TCP port `1080` and the configured SOCKS5 UDP relay range to trusted
  client networks. Do not expose an unauthenticated SOCKS proxy to the Internet.
- Give every tunnel client its own SSH account, key, server-side TUN device,
  and `/30` network.
- The container requires `/dev/net/tun` and `NET_ADMIN`. Treat it as a network
  appliance and keep the image and host patched.
- Keep `AllowTcpForwarding no` on the SSH server. This project uses an L3 TUN
  device and does not need OpenSSH TCP forwarding.

Only example addresses from RFC 5737 and example credentials belong in the
repository.
