# Security

## Scope

`elsewhere` fetches URLs through a tunnel built from the owner's own links. The
security-relevant surfaces:

- **The config file carries credentials.** `~/Library/Application
  Support/elsewhere/config.json` holds share links (UUIDs, REALITY keys) — it is written
  0600 in a 0700 directory, and every printable form is redacted through `Redactor`. A
  way to get the raw link into a log, an error message, or a tool result is a
  vulnerability — report it.
- **Fetch destinations are guarded.** The private-address guard refuses loopback,
  link-local, and site-local destinations (and every redirect hop) so a URL cannot turn
  `elsewhere` into an SSRF tool against this Mac's own services.
- **The engine is upstream's.** The Xray-core it runs is XTLS/libXray's unmodified Apple
  build; defects in Xray-core or libXray themselves belong to
  [XTLS](https://github.com/XTLS/libXray). The engine's provenance is recorded and
  verified in the
  [swift-libxray repository](https://github.com/laconicman/swift-libxray), which ships
  the artifact — report provenance concerns there.
- **Inbounds are loopback-only.** The generated config listens on 127.0.0.1 with UDP off;
  `serve` (M2) listens on nothing but stdio.

## Reporting

Use GitHub's private vulnerability reporting on this repository (Security → Report a
vulnerability). Please do not open a public issue for something that could expose a
proxy credential — share links carry secrets in cleartext.
