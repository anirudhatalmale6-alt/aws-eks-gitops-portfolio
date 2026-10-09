# 02 Remote state, and why there is no DynamoDB table

## The short version

```sh
make bootstrap
cp terraform/envs/dev/backend.hcl.example      terraform/envs/dev/backend.hcl
cp terraform/envs/dev/terraform.tfvars.example terraform/envs/dev/terraform.tfvars
# fill in the bucket name from the bootstrap output, and your GitHub username
make init
```

## Why state locking changed

Almost every tutorial still says: create a DynamoDB table with a `LockID` hash
key, pass `dynamodb_table` to the backend. That advice is out of date, and
knowing why is worth more in an interview than knowing the old recipe.

| Terraform | What changed |
|---|---|
| 1.10 (Nov 2024) | `use_lockfile` added. The backend writes `<key>.tflock` next to the state file using a conditional `If-None-Match` write, which S3 made atomic in August 2024. Whoever creates the object holds the lock. |
| 1.11 | `dynamodb_table` **deprecated**. |
| 1.12+ | Warns on it. Slated for removal. |

So the supported configuration is now:

```hcl
terraform {
  backend "s3" {
    bucket       = "..."
    key          = "envs/dev/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true      # no dynamodb_table
  }
}
```

That removes a billable resource, and it removes a failure mode: with a
separate lock table, deleting the table does not break anything visibly. Applies
simply stop locking, silently, until two of them race and corrupt state.

## The chicken and egg

The bucket that holds terraform state cannot itself be stored in that bucket
before it exists. So `terraform/bootstrap` runs with **local state**, creates
the bucket, and optionally migrates its own state in afterwards:

```sh
cd terraform/bootstrap
terraform init && terraform apply

cp backend.tf.example backend.tf      # fill in the bucket name
terraform init -migrate-state         # answer yes
rm -f terraform.tfstate terraform.tfstate.backup
```

That last `rm` matters. Two copies of the same state drift, and the local one
wins the next time someone runs terraform without the backend configured.

## What the bucket has, and why

| Setting | Reason |
|---|---|
| Versioning **on** | The only way back from a truncated or corrupted state push. Not optional. |
| Encryption at rest | AES256 by default; pass `kms_key_arn` for a CMK and auditable `Decrypt` calls in CloudTrail. |
| All four public access blocks | State lists every resource ID in your account, and sometimes secrets. |
| `BucketOwnerEnforced` ownership | Turns ACLs off entirely. There is no case for an ACL on a state bucket. |
| Lifecycle: expire old versions | Every apply writes a new version. Without this the bucket grows forever. Keeps the 10 most recent regardless of age. |
| Bucket policy: deny non-TLS | A misconfigured client could otherwise ship state in the clear. |
| Bucket policy: deny unencrypted `PutObject` | The bucket default would encrypt anyway; this rejects an upload that explicitly asks not to be. |
| **No** `force_destroy` | This bucket is the only record of what exists. Emptying it has to be a conscious act. |

## Why the bucket name is not in git

It is `<project>-tfstate-<your account id>`, so it is globally unique without
you inventing anything. It also contains your AWS account number, which is not
a secret but is not something to publish on a portfolio repository either.

So the backend configuration is **partial**. The non-account-specific parts are
in `backend.tf`, committed. The bucket and region are in `backend.hcl`, which
is gitignored:

```sh
terraform init -backend-config=backend.hcl
```

`make init` does that and tells you what to do if the file is missing.

## Verifying the lock actually works

Worth doing once, because a lock that silently is not taken is the kind of thing
you want to find out about deliberately:

```sh
# Terminal 1
terraform -chdir=terraform/envs/dev plan

# Terminal 2, while that is running
terraform -chdir=terraform/envs/dev plan
# Error: Error acquiring the state lock
# ConditionalCheckFailed: ... envs/dev/terraform.tfstate.tflock
```

If a run is killed and leaves a lock behind:

```sh
# The lock ID is in the error message.
terraform -chdir=terraform/envs/dev force-unlock <LOCK_ID>
```

Check that nothing else is genuinely running first. Force-unlocking a live apply
is how two of them end up writing the same state.

Next: [03-cicd.md](03-cicd.md).
