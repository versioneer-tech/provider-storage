# Permission Workflow

The permission workflow is one of the core features of `provider-storage` and makes it possible to request and/or grant permissions from/to other users. For the end user, the functionality of all the Configuration Packages is the same. However, even though MinIO, AWS and Scaleway provide S3-compatible storage backends, they all have their unique limitations. While `storage-minio` and `storage-aws` enable the permission workflow through an `Object` from [`provider-kubernetes`](https://github.com/crossplane-contrib/provider-kubernetes/), `storage-scaleway` uses the capability of [`function-pyhton`](github.com/crossplane-contrib/function-python) to check if permissions have been granted to specific users/applications.

We will work through the different Configuration Packages with the following Claim in mind. We don't need to cover Buckets since they are simply created when the Claim is applied.

```yaml
---
apiVersion: pkg.internal/v1beta1
kind: Storage
metadata:
  name: alice
spec:
  owner: alice
  buckets:
  - bucketName: alice
  - bucketName: alice-shared
    discoverable: true
  bucketAccessRequests:
  - bucketName: bob-shared
    permission: ReadWrite
---
apiVersion: pkg.internal/v1beta1
kind: Storage
metadata:
  name: bob
spec:
  owner: bob
  buckets:
  - bucketName: bob
  - bucketName: bob-shared
    discoverable: true
  bucketAccessGrants:
  - bucketName: bob-shared
    permission: ReadWrite
    grantees:
    - alice
```

## `storage-minio` and `storage-aws`

Both Configuration Packages create multiple **IAM Policies** which are attached to the user objects. This is already the main difference between these two and `storage-scaleway` which creates a single **Bucket Policy**. Let's first imagine that `bob` has not granted `ReadWrite` permissions to `alice` yet but `alice` has already requested permissions.

The Compositions create multiple IAM Policies which follow the pattern `<owner>.owner.<bucketName>`:

- alice.owner.alice
- alice.owner.alice-shared
- bob.owner.bob
- bob.owner.bob-shared

They describe the permissions of each user, i.e. `alice` owns the Buckets `alice` and `alice-shared` and `bob` owns the Buckets `bob` and `bob-shared`. In `storage-minio` they are added to the `User` object directly and in `storage-aws` they are added through a `UserPolicyAttachment`. However, what we are missing is an IAM police `alice.readwrite.bob-shared` since `bob` has not granted any access to his Bucket yet.

In order for the Claim to reconcile and continuously check if `alice.readwrite.bob-shared` exists (i.e. `bob` has finally granted the request) a Kubernetes Object is created which flips its `Ready` state to `True` as soon as the `alice.readwrite.bob-shared` IAM policy exists. Since the Kubernetes Resource has changed its state, the `crossplane` controller reconciles the Claim and also attaches `alice.readwrite.bob-shared` to the `User`.

Lastly, the `User` object in `storage-minio` and the `AccessKey` object in `storage-aws` generate the corresponding API Keys.

One big downside of this approach is that the Claim of `alice` has the `Ready: False` state as long as the permission request has not been granted. This is another case where `storage-minio` and `storage-aws` differ from `storage-scaleway`. This will be changed/fixed in a future release of `provider-storage`.

## `storage-scaleway`

As already stated before, the biggest difference between `storage-scaleway` and the other two Configuration Packages is, that we need to work with **Bucket Policies** (since this is how Scaleway handles Object Storage permissions) and that we are not using `Objects` from `provider-kubernetes`. Scaleway has the limitation that we can only apply one Bucket Policy per Bucket so the `owner`, `ReadWrite` and `ReadOnly` statements are all inside one Bucket Policy and only the `Principal` (the user/application that these permissions apply to) are added. Furthermore, `storage-scaleway` does not use `User` objects but `Application` objects.

Let's assume that only the `bob` Claim is applied. Since `storage-scaleway` does not use an `Object` from `provider-kubernetes` but the capabilities of `function-python` the state of the Claim is always `Ready: True`. Each Claim adds the ID of the `User` which is used for connecting to Scaleway and the ID of the `Application` of the owner to the `Principal` field of the corresponding statement. Furthermore, it checks if the `Application`, that is granted permission to a bucket, exists and adds it to the `Principal` of the corresponding permission statement. Since `alice` does not exist, nothing is added to the Bucket Policy. This way we shift the work of `provider-kubernetes` into the creation of the Bucket Policy itself and ensure that the Claim always is in a `Ready: True` state. The following Bucket Policies are created:

- bob
- bob-shared

Let's have a look at `bob-shared`.

```json
{
  "Version": "2023-04-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "SCW": [
          "user_id:55a79491-d8b1-480b-8b36-f15cea9db176",
          "application_id:a4e57158-651f-441d-8a3c-141b598ec6e7"
        ]
      },
      "Action": [
        "s3:*"
      ],
      "Resource": [
        "bob-bob-shared-a97a5bcb-62d7896f",
        "bob-bob-shared-a97a5bcb-62d7896f/*"
      ]
    },
    {
      "Effect": "Allow",
      "Principal": {
        "SCW": []
      },
      "Action": [
        "s3:ListBucket",
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject"
      ],
      "Resource": [
        "bob-bob-shared-a97a5bcb-62d7896f",
        "bob-bob-shared-a97a5bcb-62d7896f/*"
      ]
    },
    {
      "Effect": "Allow",
      "Principal": {
        "SCW": []
      },
      "Action": [
        "s3:ListBucket",
        "s3:GetObject"
      ],
      "Resource": [
        "bob-bob-shared-a97a5bcb-62d7896f",
        "bob-bob-shared-a97a5bcb-62d7896f/*"
      ]
    }
  ]
}
```

As you can see, `bob` wanted to grant `alice` permissions to `ReadWrite` the `bob-shared` Bucket but the `Application` does not exist so nothing is added to the `Principal` in the second Statement.

Now the question is: How does the the `crossplane` controller now know that it needs to reconcile to check if the `Application` named `alice` exists? This is done by `function-python` since we added `alice` as a required resource, i.e. as long as `alice` does not exist the `crossplane` controller will reconcile. If `alice` is found, the Bucket Policy is updated and looks something like this:

```json
{
  ...
    {
      "Effect": "Allow",
      "Principal": {
        "SCW": [
          "application_id:b3d29169-0bb5-4c54-b7d1-b1570a81ef56"
        ]
      },
      "Action": [
        "s3:ListBucket",
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject"
      ],
      "Resource": [
        "bob-bob-shared-a97a5bcb-62d7896f",
        "bob-bob-shared-a97a5bcb-62d7896f/*"
      ]
    },
  ...
}
```

One downside is that there is no way to see who requested access to which Buckets yet. This will be implemented in a future release such that it can be used by external systems that want to build off of it.

## Conclusion

In conclusion, the difference between `storage-minio` and `storage-aws` on the one hand and `storage-scaleway`on the other hand, comes down to the difference in Policies. While `storage-minio` and `storage-aws` create IAM Policies, `storage-scaleway` creates Bucket Policies. The permission workflow for the first two Configuration Packages works by creating specific `Objects` with `provider-kubernetes` that observe if an IAM Policy exists. This implies that the Claim always has the state `Ready: False` if it does not. The permission workflow for the last Configuration Package works by checking if the specified `Application`, that permission is granted, exists. The Claim is reconciled as long as the `Application` does not exist. This implies that the Claim always has the `Ready: True` state but there is no way (yet) to see if there is a request to a specific Bucket.
