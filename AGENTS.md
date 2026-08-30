# SwiftRDP server — Agent Notes

## After server code changes

When SwiftRDP server code changes, **rebuild and restart** the installed app:

```bash
bash scripts/install-and-run.sh
```

Do not leave a stale SwiftRDP process running after server changes. Follow the signing rules in the umbrella repo root `AGENTS.md` (stable Team ID, no ad-hoc).

## Implementation style

- Unless compatibility is explicitly requested, target the current macOS SDK and current RDP client behavior directly. Do not add compatibility layers, legacy fallbacks, or version branches just in case.
- Prefer the smallest native implementation that is efficient on the hot path. Keep state changes event-driven or bounded, avoid speculative polling and heuristic inference when the platform exposes the actual state.
- When replacing behavior, delete the superseded implementation, dead helpers, stale comments, and tests that only describe the removed behavior. Do not leave parallel old and new paths.
- After cleanup, search for remaining references and run focused tests plus the full test suite before rebuilding the installed app.
