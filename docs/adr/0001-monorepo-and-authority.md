# ADR 0001: ChatGal monorepo and authority boundaries

## Status

Accepted (2026-09-12)

## Context

Rebuild Fusion Lua app「你好戒戒」as Flutter ChatGal with pluggable content packages, reliable saves, and AI-assisted dialogue. Original single-file coupling cannot support multi-author content.

## Decision

1. **Monorepo** under `ChatGal` with Flutter app + pure Dart packages.
2. **gal_core** is pure Dart: no Flutter, Dio, or Drift. Deterministic reducer only.
3. **World facts are authority**: variables, inventory, quests, eventHistory. Chat/memory never invent items.
4. **AI proposes, engine commits**: dialogue segments + optional AttributeProposal / proposedActionId. Engine validates and applies.
5. **Package format** `.chatgal` is ZIP + UTF-8 JSON + Markdown + images. No script execution.
6. **Saves bind PackageRef** (packageId, version, contentHash). Missing package locks save; never auto-swap.

## Consequences

- T01 freezes schemas before large UI work.
- Character-specific rules (e.g. depravity keywords) live in content packages, not engine.
- iOS deferred until Android path is real; no false support claims.
