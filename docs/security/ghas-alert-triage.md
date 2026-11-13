# GHAS alert triage (sprint 2026-11)

Open code-scanning alerts at the start of this sprint, and the disposition of each. This pass does not dismiss alerts on GitHub.

| Alert | Rule | Path | Disposition | Reason | Recommended GitHub dismissal |
| --- | --- | --- | --- | --- | --- |
| code-scanning #1 | js/incomplete-sanitization | tools/gen-icons.mjs | fixed | Single-quoted JavaScript strings now escape backslashes before quotes, so a `\` cannot leave the closing quote live. | none (fixed) |
| code-scanning #2 | js/incomplete-multi-character-sanitization | tools/gen-icons.mjs | fixed | SVG comments are stripped until no closed comment remains, and an unclosed `<!--` is dropped, so that marker cannot survive into generated markup. | none (fixed) |

Both alerts are in the development-only icon generator (`node tools/gen-icons.mjs`). Shipped `Web/icons.js` is unchanged for the current Lucide sources. Nothing in this set needs an owner decision.

- code-scanning #1: https://github.com/fleethacker-data-crucible/PacketRat/security/code-scanning/1
- code-scanning #2: https://github.com/fleethacker-data-crucible/PacketRat/security/code-scanning/2
