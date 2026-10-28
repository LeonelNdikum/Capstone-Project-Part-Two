# Capstone: Automating Docker Image Deployment to Amazon ECR

A small Nginx demo image and GitHub Actions pipeline for building environment-specific images and publishing them to a private Amazon ECR repository. The workflow uses GitHub's OIDC identity provider to assume an AWS role; it does not store long-lived AWS access keys in GitHub.

## Pipeline behavior

| Event | Behavior |
| --- | --- |
| Pull request to `dev` | Build and scan a dev image; do not authenticate to AWS or push |
| Pull request to `staging` | Build and scan a staging image; do not authenticate to AWS or push |
| Pull request to `main` | Build and scan a prod image; do not authenticate to AWS or push |
| Push to `dev` / `staging` / `main` | Build, scan with Trivy, and publish to ECR; then run Terraform init, validate, and apply |
| Manual run of the build workflow | Select `dev`, `staging`, or `prod`; scan and publish the image, then apply Terraform |
| Manual run of `Destroy environment images in ECR` | Select `dev`, `staging`, or `prod` to delete only that environment's tags after confirmation and its environment approval |

Published tags include both an immutable commit reference (`dev-<sha>`, `staging-<sha>`, `prod-<sha>`) and a moving convenience tag (`dev-latest`, `staging-latest`, `prod-latest`). `main` maps to `prod`. Configure branch protections and GitHub environment approvals for staging and production.

## 1. Create the ECR repository

The Terraform configuration in `infra/` creates a private ECR repository with AES-256 encryption, scan-on-push, and a lifecycle rule that retains the newest 30 commit-tagged images for each environment. The publish workflow expects this repository to exist before the first image push. Bootstrap it once from `infra/` using an AWS identity authorized to manage ECR:

```sh
terraform init -backend-config='bucket=YOUR_TF_STATE_BUCKET' -backend-config='key=capstone/YOUR_OWNER/YOUR_REPOSITORY/infrastructure.tfstate' -backend-config='region=eu-west-2' -backend-config='encrypt=true' -backend-config='use_lockfile=true'
terraform plan -var='aws_region=eu-west-2' -var='repository_name=capstone-image'
terraform apply -var='aws_region=eu-west-2' -var='repository_name=capstone-image'
```

Create the S3 state bucket before running Terraform, with encryption and versioning enabled. The workflow uses one shared S3 state key for this repository and S3 lock files, so the bootstrap state and all later workflow applies track the same ECR resources.

## 2. Configure AWS OIDC

In AWS IAM, add GitHub's OIDC provider (`https://token.actions.githubusercontent.com`, audience `sts.amazonaws.com`) if it does not already exist. Create an IAM role with a trust policy restricted to this repository and the intended GitHub environments. Example trust condition (replace the owner/repository):

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": { "token.actions.githubusercontent.com:aud": "sts.amazonaws.com" },
      "StringLike": { "token.actions.githubusercontent.com:sub": "repo:YOUR_OWNER/YOUR_REPOSITORY:environment:*" }
    }
  }]
}
```

Attach a least-privilege policy for the single ECR repository. For image publishing, the role needs `ecr:GetAuthorizationToken` on `*`, plus upload/push actions (`ecr:BatchCheckLayerAvailability`, `ecr:BatchGetImage`, `ecr:CompleteLayerUpload`, `ecr:InitiateLayerUpload`, `ecr:PutImage`, `ecr:UploadLayerPart`) scoped to the repository ARN. The `Destroy environment images in ECR` workflow uses the selected GitHub environment role. It also needs `ecr:ListImages` and `ecr:BatchDeleteImage` scoped to the repository ARN. Keep each role trust restricted to this repository and its matching GitHub environment.

## 3. Configure GitHub

Create GitHub environments named `dev`, `staging`, and `prod`. Add these environment variables to each:

- `AWS_ROLE_TO_ASSUME`: IAM role ARN
- `AWS_REGION`: region containing the ECR repository
- `ECR_REPOSITORY`: repository name, for example `capstone-image`
- `TF_STATE_BUCKET`: existing S3 bucket for Terraform state (the role needs `s3:GetObject`, `s3:PutObject`, and `s3:DeleteObject` on its state/lock objects, plus `s3:ListBucket` on the bucket)

Set approval reviewers and deployment branch restrictions on `staging` and `prod`; require approval for destructive runs in every environment. No AWS access key secrets are needed.

## 4. Run and inspect

Push or merge to `dev`, `staging`, or `main`. Pull requests build and scan all environment variants without AWS access. A trusted push builds the image, fails if Trivy finds HIGH or CRITICAL vulnerabilities, publishes it, and only then runs Terraform init, validate, and apply. Configure the IAM role with ECR push permissions and Terraform permissions for the resources in `infra/` (currently ECR), plus access to the configured S3 state and lock objects. Check the Actions run and ECR repository for the commit and `latest` tags. Run locally with:

```sh
docker build --build-arg APP_ENV=dev --build-arg VCS_REF=local --build-arg VCS_URL=https://github.com/YOUR_OWNER/YOUR_REPOSITORY -t capstone:dev .
docker run --rm -p 8080:80 capstone:dev
```

Open <http://localhost:8080>. For a public GitHub repository, publish the source and documentation; ECR remains private.

## Delete images for one environment

In GitHub Actions, run **Destroy environment images in ECR** from the default branch. Select `dev`, `staging`, or `prod`, type that environment again, then enter `DELETE`. The job uses the selected GitHub environment's OIDC role and repository settings, and removes only tags beginning with that environment name (for example, `staging-`). Other environments' tags and the shared ECR repository remain. The choices in this workflow must be updated when adding an environment to the build workflow.

The workflow requires `ecr:ListImages` and `ecr:BatchDeleteImage` on the configured repository. If you manage the ECR repository with Terraform, image deletion does not remove the repository or Terraform state. Use `terraform destroy` separately when you intend to remove the repository itself.

## Reflection prompts

- **Pipeline design:** PRs build all environment variants without AWS credentials. Trusted branch pushes map `dev` → `dev`, `staging` → `staging`, and `main` → `prod`; OIDC grants short-lived AWS credentials only to the publish job. Common setup challenges include matching GitHub's OIDC subject to the IAM trust policy and keeping branch/environment names consistent.
- **Security and resources:** Separate GitHub environments support approval gates and environment-scoped role configuration. ECR scan-on-push and lifecycle retention reduce image risk and storage growth. Avoid broad role trust, long-lived AWS keys, and unbounded image retention.
- **Lessons:** CI can validate images before a merge while withholding deployment credentials from pull-request code. Immutable commit tags improve traceability, while environment `latest` tags are convenient for demos and testing.

## Notes

The workflow publishes images and applies the Terraform currently in `infra/` (the ECR repository and lifecycle policy). It does not yet define a runtime such as ECS, EKS, or App Runner; add those resources to Terraform when ready to deploy containers. Replace the sample OIDC trust policy values and AWS settings for your own GitHub repository and account. Do not commit Terraform state or credentials.
