# ADR-003: Run Portable Lifecycle Cleanup Jobs

## Status

Accepted

## Date

2026-04-30

## Context

The `Storage` API supports `Delete` and `Notify` rules. A rule can select
objects by age, activation time, and prefix. Native lifecycle features differ
between backends and do not provide the same behavior.

## Decision

Run lifecycle rules as Kubernetes CronJobs instead of native bucket lifecycle
rules.

For each `Storage` with lifecycle rules, the Composition creates:

- one ConfigMap with one rclone script for each rule;
- one CronJob with one container for each rule.

The rules work as follows:

- `Notify` lists matching objects and does not change them;
- `Delete` removes matching objects;
- `minAge` selects objects by relative age;
- `at` starts repeated processing after that time;
- a target selects a bucket or a prefix in that bucket.

The default schedule is `17 2 * * *`. Operators can change it in the storage
`EnvironmentConfig`.

Jobs use the current consumer Secret and the backend settings from the
`EnvironmentConfig`. They do not receive a Kubernetes service-account token.
`concurrencyPolicy: Forbid` prevents two scheduled Jobs from running at the
same time.
Jobs have a deadline and a finite retry limit. Failed Pods do not restart in
place. These limits prevent a failed Job from blocking later scheduled runs.

## Consequences

- All backends use the same Job and script generator.
- Cleanup depends on Kubernetes, network access, rclone, and valid consumer
  credentials.
- Containers for rules in the same Job run at the same time. Rules with
  overlapping targets can conflict.
- An `at` rule runs on every later schedule. `Notify` can report the same
  object more than once.

## Current limits

- The API does not reject rules with overlapping targets.
- The execution order of rules in one Job is not deterministic.
