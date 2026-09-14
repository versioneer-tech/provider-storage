# ADR-002: Rotate Static Credentials by Generation

## Status

Accepted

## Date

2026-01-16

## Context

For backends that issue static access keys, an immediate key
replacement can break a consumer that has not reloaded its Secret. Keeping too
many old keys increases the security risk.

## Decision

Use `spec.credentialsRollover` to define the active credential generations:

- `interval` is `daily`, `weekly`, `monthly`, `quarterly`, `yearly`,
  or `none`;
- `maxToKeep` is the total number of active generations, including the
  current generation;
- the default is `interval: none` and `maxToKeep: 1`;
- `maxToKeep` must be `1` when `interval` is `none`.

A time-based generation uses the current UTC period. The suffix format is:

| Interval | Suffix format |
| --- | --- |
| `daily` | `-YYYYMMDD` |
| `weekly` | `-YYYYwWW` |
| `monthly` | `-YYYYMM` |
| `quarterly` | `-YYYYqQ` |
| `yearly` | `-YYYY` |
| `none` | No suffix |

A Composition must calculate the generation once per reconciliation. It must
use that value for all identities, credentials, permissions, and Secrets.

Each desired generation creates backend-specific credentials. The first
generation is current. Provider Storage writes it to the stable Secret named
`spec.principal`. Crossplane removes generations that are not in the desired
set.

## Consequences

- Consumers keep one Secret name. They must reload it before an old generation
  is removed.
- An overlap gives consumers time to reload, but it also keeps more keys valid.
- Rotation occurs during reconciliation after the period changes. It does not
  occur at an exact time.
- This decision applies only to static access keys.

## Current limits

- AWS and OTC calculate time in more than one pipeline step. A reconciliation
  across a period boundary can create inconsistent resource names.
- OTC policies do not reliably include all retained identities.
