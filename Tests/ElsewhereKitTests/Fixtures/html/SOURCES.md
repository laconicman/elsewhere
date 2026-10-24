# Fixture provenance

| File | Source | Retrieved | Licence |
|---|---|---|---|
| `swift-libxray-readme.html` | https://github.com/laconicman/swift-libxray (the rendered `<article>` region, trimmed) | 2026-10-24 | Own content (the owner's repo). |
| `wikipedia-ifconfig.html` | https://en.wikipedia.org/wiki/Ifconfig (`#mw-content-text` region, trimmed) | 2026-10-24 | CC BY-SA 4.0. |
| `apple-docc-shell.html` | https://developer.apple.com/documentation/swift (the SPA shell, unmodified) | 2026-10-24 | © Apple — a test fixture exercising the JS-shell note; fair-use scale, never shipped. |
| `constructs.html` | Hand-written for this suite — every construct the renderer promises. | — | Own content. |
| `trace.txt` | Hand-written `cdn-cgi/trace`-shaped body — the passthrough fixture. | — | Own content. |

Goldens (`*.md` beside these) are generated once by `Renderer` itself and frozen by
eye — `ELSEWHERE_WRITE_GOLDENS=1 swift test` regenerates them.
