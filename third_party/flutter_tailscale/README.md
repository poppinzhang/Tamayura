# Flutter-Tailscale

[简体中文](README.zh-CN.md) | English

Flutter-Tailscale is a reusable Tailscale integration component for native Flutter applications, built around a Go `tsnet` core and a Flutter plugin. Tamayura is the first consumer.

**Status: unpublished implementation, 2026-11-15.** The repository contains a Dart/Flutter package, a Go `tsnet` runtime, an Android network adapter, native build scripts, and automated tests. Local authenticated transport and lifecycle checks pass; real embedded-node internet connectivity and Android background behavior still require device validation. There is no published package or release.

## Implemented capabilities

- Optional in-app authentication with the official Tailscale control service, with persistent per-application node identity.
- Node state and visible peer information, without requiring an administrative tailnet API token.
- Outbound and inbound TCP forwarding between application services and a tailnet.
- A Dart interface for lifecycle, connections, and status snapshots, with a separate gRPC adapter import.
- Independent operation of the host application's existing local network features.

The runtime targets Android, macOS, Windows, and Linux. Build checks and local transport checks do not establish real network support on each platform; see the implementation record. iOS is a future target. Flutter Web requires a different approach. A separate project does not require a separate process on every platform: desktop helpers and mobile native libraries can share the same public contract.

Each host application remains responsible for identifying its own services, authorizing business operations, selecting LAN or Tailscale routes, and managing background tasks. Reusing the component does not automatically share another application's login or Tailscale identity. Headscale configuration is reserved for a possible later phase.

## Integration and design documents

Start with the [implementation and verification record](docs/08-implementation.md) and [minimal consumer example](example/README.md). Documents 01–07 preserve the original design; proposed APIs and unimplemented features in those documents are not the current public contract.

The detailed design is maintained in Chinese.

| Document | Contents |
| --- | --- |
| [Scope and architecture](docs/01-scope-and-architecture.md) | Boundaries, components, data flow, ownership, and proposed project structure |
| [API and lifecycle](docs/02-api-and-lifecycle.md) | Proposed Dart contract, state, events, control IPC, errors, and identity persistence |
| [Transport and security](docs/03-transport-and-security.md) | Local authentication, TCP forwarding, gRPC adaptation, peer identity, and resource limits |
| [Platforms and packaging](docs/04-platforms-and-packaging.md) | Desktop and mobile runtime options, lifecycle, build and distribution requirements |
| [Tamayura integration](docs/05-tamayura-integration.md) | Discovery order, dual-path status, RPC integration, downloads, and remaining product decisions |
| [Validation and roadmap](docs/06-validation-and-roadmap.md) | Prototype gates, test matrix, network measurements, and delivery criteria |
| [Decisions and references](docs/07-decisions-and-references.md) | Confirmed scope, proposed decisions, open questions, and primary sources |

Outbound TCP uses a session-pinned local TLS connection and an authenticated CONNECT handshake. Inbound publishing uses explicit source-node allowlists and a pinned mutual-TLS connection to the Dart-owned listener. Use `TailscaleChannel` from `package:flutter_tailscale/grpc.dart` for gRPC; an ordinary channel pointed at a bridge port cannot complete these handshakes.

Changes are recorded in [CHANGELOG.md](CHANGELOG.md). This project is not presented as an official Tailscale SDK; its own license and package publication details remain to be selected.
