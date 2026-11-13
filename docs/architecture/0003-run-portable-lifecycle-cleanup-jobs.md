# ADR-003: Run Portable Lifecycle Cleanup Jobs

## Status

Accepted

## Date

2026-04-30

## Context

The `Storage` API supports `Delete` and `Notify` rules. A rule can select
objects by age, UTC cutoff, and prefix. Native lifecycle features differ
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
- `at` is a UTC cutoff, not a one-time schedule;
- a target selects a bucket or a prefix in that bucket.

The default schedule is `17 2 * * *`. Operators can change it in the storage
`EnvironmentConfig`.

Jobs use the current consumer Secret and the backend settings from the
`EnvironmentConfig`. They do not receive a Kubernetes service-account token.
`concurrencyPolicy: Forbid` prevents two scheduled Jobs from running at the
same time.
Each Job has a one-hour deadline and permits two retries by default. Failed
Pods do not restart in place. The EnvironmentConfig can set
`storage.lifecycle.activeDeadlineSeconds` from 1 through 86400 and
`storage.lifecycle.backoffLimit` from 0 through 10. The deadline includes
retry time. A Job that exceeds either limit fails and permits a later
scheduled Job to run.

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
