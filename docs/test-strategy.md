# Test Strategy

Provider Storage has three test tiers. Unit renders check what each
Composition requests for a known input and observed state. Provider probes
check individual managed resources and make an S3 request with issued
credentials. End-to-end tests check the `Storage` API, reconciliation, and
S3 access through a sequence of claim changes. A passing render or Ready
condition does not replace an S3 access check.

The same capability scenarios should run against MinIO, AWS, OTC, and
OVHcloud. The story and assertions stay common. Backend setup supplies the
provider configuration, a unique physical bucket prefix where needed, the
S3 endpoint, and the client settings. Cloud runs remain opt-in; the local
MinIO run is the CI baseline. The OVHcloud run is opt-in and uses a separate
Composition selector so existing probe claims do not change during the test.
Backend adapters for AWS and OTC remain to be added.

## Capability 1: Buckets, Secrets, Requests, and Grants

The shared examples in `examples/base/` describe the final claim state for
Joe, Jeff, Jane, and John. This suite builds that state one change at a time.
It uses a projection of those examples without `credentialsRollover` or
`lifecycleRules`. It preserves the request and grant metadata in the
examples. Rollover and lifecycle fields belong to their own capability
suites.

| Step | Claim change | Required live evidence |
| --- | --- | --- |
| T0 | Start with no story claims. | The selected namespace has no resources from an earlier story run. |
| T1 | Joe creates bucket `s-joe`. | Bucket and normalized Secret are ready; Joe can write and read an object. |
| T2 | Jeff creates `s-jeff` and `s-jeff-shared`. | Both buckets and Jeff's Secret are ready; Jeff can use both and leaves an object in the shared bucket; Joe cannot use it. |
| T3 | Joe requests `s-jeff-shared`. | The request is visible, but Joe still cannot read or write Jeff's bucket. |
| T4 | Jeff grants Joe `ReadWrite` on `s-jeff-shared`. | Joe can read and write an object in that bucket. |
| T5 | Jeff changes Joe's grant to `ReadOnly`. | Joe can read an existing object but cannot write; this is Jeff's final grant. |
| T6 | Jeff requests `s-joe`. | Jeff cannot access Joe's bucket before the grant. |
| T7 | Joe grants Jeff `ReadWrite` on `s-joe`. | Jeff can read and write Joe's bucket. |
| T8 | Jane creates a claim with no buckets and requests `s-john`. | Jane receives a normalized Secret, but cannot access the absent bucket. |
| T9 | John creates `s-john` and requests `s-joe`, `s-jeff`, and `s-jane`. | John's bucket and Secret are ready. His ungranted requests give no access; `s-jane` has no bucket. |
| T10 | John grants Jane `ReadWrite` on `s-john`. | Jane can read and write John's bucket. The capability-1 fields now match the shared examples. |

This first story uses one temporary grant change. Add focused `WriteOnly`
and `None` cases to this capability suite after the common path works; they
need not lengthen the path to the shared examples' final state.

Each T1–T10 change is a full `Storage` YAML manifest in
`tests/integration/capability-one/steps/`, named for the actor and action
(for example, `t01-s-joe_create-bucket_s-joe.yaml`). The runner renders only
the backend-specific names and applies that manifest to the existing claim.
It saves captures in directories with the same step names, beginning with
`t00-start-empty`. The end-to-end runner waits for the relevant resources
to reconcile, then polls the S3 result until it matches the expected allow
or deny. It must use a deadline rather than one fixed sleep: policy
enforcement can lag a Ready condition. The runner also checks that each
consumer Secret has the normalized keys and never prints credential values.

The story script should be identical for all backends. An adapter supplies
the bucket-name mapping and connection details, and runs any backend-specific
setup. The adapter must map a logical bucket name consistently in buckets,
requests, grants, S3 checks, and captured fixtures. A backend that cannot
pass a step reports that step as a failure with evidence; the shared story
does not silently skip it. Use an isolated namespace for each story run.
Before cleanup, inventory its cloud buckets and users. Do not assume that
deleting the namespace deletes retained cloud buckets.

## Live Captures and Unit Cases

After each step converges, capture the composed resources and the inputs
needed by the next render: peer `Storage` resources, EnvironmentConfig data,
provider status fields, and credential observer state. Capture only fields
the Composition reads. Replace live IDs, generated names, times, and all
credential values with stable test values. Never copy a raw Kubernetes
Secret into the repository. Keep raw capture files outside Git and remove
them after review.

For T1 through T10, add unit cases for each claim affected by the step. A
grant edit can affect the requester's Composition even when the requester's
claim did not change, so there may be more unit cases than timeline steps.
Render each affected claim at Tn with its sanitized observed state from
Tn−1 and the peer and environment resources available at Tn. Compare the
transition with a reviewed expected manifest. A second render can use the
observed state captured after Tn to check the settled output. T0 is an
end-to-end precondition, since there is no `Storage` to render.

Live captures are evidence for the fixture, not an automatic source of
truth for expected behavior. Review every proposed golden change against
the public `Storage` contract and the S3 results. When a provider or
Composition changes, rerun the affected backend's story, compare new
sanitized captures with the saved fixtures, and update only reviewed
differences. The same unit cases run without cloud credentials.

The MinIO story runs with
`tests/integration/run.bash minio --with-capability-one`. It retains an
isolated namespace for inspection and writes sanitized captures to a
temporary directory. The reviewed MinIO transition fixtures live in
`minio/tests/capability-one/` and run with `tests/unit.bash minio`. Each
fixture uses YAML for its claim input, required resources, observed
resources, and expected render.

The OVHcloud story uses the same YAML steps and S3 checks. Its adapter maps
the logical names to unique project and region names, records sanitized
OVHcloud managed-resource status, and copies the existing Kind controller
credential Secret into the isolated story namespace. Its 15 reviewed
transition fixtures live in `ovh/tests/capability-one/` and run with
`tests/unit.bash ovh`. OVHcloud bucket resources retain their buckets
after claim deletion. The printed cleanup command therefore empties only
the story objects, deletes the claims, and then removes the retained test
buckets and users through the administrator CLI.

## Other Capability Suites

Credential rollover and lifecycle rules have separate planned suites.
They may reuse the runner and capture process, but each has its own timeline
and access or object-state assertions.
