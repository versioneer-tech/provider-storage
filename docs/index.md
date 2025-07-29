# provider-storage

## Introduction

The `provider-storage` [Configuration Package](https://docs.crossplane.io/latest/concepts/packages/) is the root project for a collection of different configuration packages that enable the creation of S3-compatible object storage called `buckets` or `containers` as well as the possibility to request access from or grant access to those `buckets`.

The following configuration packages are built from `provider-storage`:

- `storage-minio`

## First steps

Before you can work with any of the configuration packages built from `provider-storage` you need to [install Crossplane](https://docs.crossplane.io/latest/software/install/) into your Kubernetes cluster. An easy way to start testing the configuration package is on a local [kind](https://kind.sigs.k8s.io/) cluster.

You can either follow a tutorial to set up everything from scratch to deploy your first [Claim](https://docs.crossplane.io/latest/concepts/claims/) or, if you already have experience with Crossplane and Kubernetes, follow a how-to guide on how to install a specific configuration package built from `providers-storage`.

## Getting help

## How the documentation is organized

The documentation is organized in four distinct parts:

- [Tutorials](tutorials.md) invite you to follow a series of steps to install, run and deploy your first [Claim](https://docs.crossplane.io/latest/concepts/claims/) for each configuration package.
- **How-to guides** are more advanced than tutorials and guide you through specific problems and use-cases.
- [Reference guides](reference-guides.md) contain the API definitions for the [Composite Resource Definitions](https://docs.crossplane.io/latest/concepts/composite-resource-definitions/) of the configuration packages.
- [Discussions](discussions.md) provide some insight in the inner workings of the [Compositions](https://docs.crossplane.io/latest/concepts/compositions/) and some reasoning behind their implementation.

!!! note

    All configuration packages built from `provider-storage` share the same Composite Resource Definition!
