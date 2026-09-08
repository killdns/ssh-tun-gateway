# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Added

- IPv4 gateway over OpenSSH point-to-point TUN.
- Optional SOCKS5 TCP `CONNECT` and UDP `ASSOCIATE` modes.
- Multi-client Linux server templates.
- Multi-platform builds for `linux/amd64`, `linux/arm64`, and `linux/arm/v7`.

### Changed

- Updated the build and runtime base to the supported Alpine Linux 3.24 branch.
- GitHub Actions publication to GHCR and Docker Hub with SBOM and provenance.
