# ``ElsewhereKit``

The façade behind `elsewhere`: the config file, named exits, the generated Xray config,
and `doctor` — every surface (the CLI today, the MCP server at M2) shares it.

## Overview

Elsewhere fetches URLs through a tunnel it brings itself: Xray-core runs **in-process**
via [swift-libxray](https://github.com/laconicman/swift-libxray), started from the stored
exits and bound to the physical interface, so `fetch` reaches networks the system path
cannot — and `--direct` is genuinely direct while a system VPN owns the default route.

The Kit keeps the engine invisible: `XrayCore` is imported internally and never appears
in a public signature, errors are one type (``ElsewhereError``) with a documented
`exitStatus`, and every printable form of a link or outbound passes through
``Redactor`` — a link is a secret, and secrets never reach output.

## Topics

### Project Direction

- <doc:Design>
- <doc:Roadmap>
- <doc:TechDebt>

### Essentials

- ``ElsewhereConfig``
- ``ConfigStore``
- ``XrayConfigBuilder``
- ``Doctor``
- ``Redactor``
- ``ElsewhereError``
