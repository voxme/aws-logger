# aws-logger

Serverless, multi-environment log ingestion pipeline.

```
Client ──> API Gateway ──> Lambda (api_handler) ──> SQS ──> Lambda (sqs_consumer)
                                                              │
                                                              ▼
                                                       Kinesis Firehose
                                                              │
                                                     Lambda (firehose_processor)
                                                              │
                                                              ▼
                                                       CloudWatch Logs
```

> The Firehose processor returns each record as `Dropped` after writing it to
> CloudWatch Logs, so records are **not** archived to the S3 bucket. The bucket
> still exists because an extended-S3 destination is required by Firehose, and
> it captures processing **errors** under `errors/`.

One CloudFormation template (`template.yaml`) is deployed twice — once per
environment — producing fully isolated **Staging** and **Production** stacks.
Everything that differs between environments lives in `params/<env>.json`.

| Resource                | Staging                      | Production                   |
| ----------------------- | ---------------------------- | ---------------------------- |
| CloudFormation stack    | `log-ingest-staging`         | `log-ingest-prod`            |
| API Gateway             | `LogIngestApi-Staging`       | `LogIngestApi-Prod`          |
| SQS queue               | `LogIngestQueue-Staging`     | `LogIngestQueue-Prod`        |
| Firehose stream         | `PUT-CloudWatch-Staging`     | `PUT-CloudWatch-Prod`        |
| API stage               | `staging`                    | `prod`                       |

## Layout

```
aws-logger/
├── template.yaml                 # Parameterized CloudFormation (all resources)
├── params/
│   ├── staging.json              # Staging parameter values
│   └── prod.json                 # Production parameter values
├── src/
│   ├── api_handler/app.py        # Lambda #1 – validates + pushes to SQS
│   ├── sqs_consumer/app.py       # Lambda #2 – SQS -> Firehose batches
│   └── firehose_processor/app.py # Lambda #3 – Firehose -> CloudWatch Logs
├── bootstrap/
│   └── github-oidc.yaml          # One-time: GitHub OIDC provider + deploy role
├── scripts/
│   ├── deploy.ps1                # package + deploy one environment
│   ├── validate.ps1              # cfn-lint / validate-template
│   ├── bootstrap-oidc.ps1        # one-time OIDC role setup per environment
│   └── get-token.ps1             # fetch a Cognito token for smoke-testing
└── .github/workflows/deploy.yml  # CI/CD: staging on staging branch, prod on main/tag
```

## Prerequisites

- AWS CLI v2, configured with credentials that can create the stack resources.
- An existing S3 bucket for packaged Lambda artifacts (one per env or shared).
- Python 3.12 (only needed if you want to run/lint the Lambdas locally).

## Deploy from your machine

```powershell
# Staging
./scripts/deploy.ps1 -Environment staging -ArtifactBucket my-cfn-artifacts-staging

# Production
./scripts/deploy.ps1 -Environment prod    -ArtifactBucket my-cfn-artifacts-prod
```

`deploy.ps1` runs `aws cloudformation package` (zips each `src/*` function and
uploads it to the artifact bucket) followed by `aws cloudformation deploy` with
the matching `params/<env>.json`.

## Deploy via GitHub Actions

| Branch / event        | Environment deployed |
| --------------------- | -------------------- |
| push to `staging`     | Staging              |
| manual dispatch       | choose `staging`/`prod` |

Production deploys are **manual only** — there is no automatic trigger. Use
**Actions → deploy → Run workflow** and select `prod`.

Configure these repository secrets:

- `AWS_ROLE_ARN_STAGING`, `AWS_ROLE_ARN_PROD` – OIDC roles to assume.
- `ARTIFACT_BUCKET_STAGING`, `ARTIFACT_BUCKET_PROD` – packaging buckets.

### One-time OIDC bootstrap

GitHub Actions authenticates to AWS with **keyless OIDC** (no long-lived
access keys). Run `bootstrap-oidc.ps1` once per environment to create the IAM
deploy role and (optionally) set the repository secrets:

```powershell
# Staging — creates the account-level GitHub OIDC provider on first run.
./scripts/bootstrap-oidc.ps1 `
  -Environment staging `
  -ArtifactBucket my-cfn-artifacts-staging `
  -GitHubOrg <org> -GitHubRepo <repo> `
  -SetSecrets

# Production — the OIDC provider already exists, so skip creating it.
./scripts/bootstrap-oidc.ps1 `
  -Environment prod `
  -ArtifactBucket my-cfn-artifacts-prod `
  -GitHubOrg <org> -GitHubRepo <repo> `
  -CreateProvider:$false -SetSecrets
```

Notes:

- Only **one** GitHub OIDC provider may exist per AWS account. The staging
  stack owns it; pass `-CreateProvider:$false` on every other run (including
  re-running prod) so it isn't duplicated or deleted.
- The role's trust policy is scoped to the **GitHub Environment** subject
  (`repo:<org>/<repo>:environment:<env>`), because the deploy job targets a
  GitHub Environment — not a branch ref.
- `-SetSecrets` uses the `gh` CLI to set `AWS_ROLE_ARN_<ENV>` and
  `ARTIFACT_BUCKET_<ENV>`. Without `gh`, the script prints the values to set
  manually in **Settings → Secrets and variables → Actions**.

## Sending a log

```http
POST https://{api-id}.execute-api.us-east-1.amazonaws.com/{stage}/logging
Content-Type: application/json
Authorization: <Cognito token>

{
  "logGroup": "/LogApi/Test",
  "messages": [
    { "message": "User login",  "timestamp": 1759213720020 },
    { "message": "User logout", "timestamp": 1759213720040 }
  ]
}
```

Response: `202 Accepted`.

## Authentication (Cognito)

The `POST /logging` method is protected by a **Cognito User Pool authorizer**
when `CognitoUserPoolArn` is set in `params/<env>.json`. Leave that value empty
to disable auth (open endpoint) for testing.

| `CognitoUserPoolArn` value | Behavior |
| -------------------------- | --------------------------------------- |
| empty (`""`)               | `AuthorizationType: NONE` — open         |
| a User Pool ARN            | `COGNITO_USER_POOLS` — token required    |

When enabled, every request must include a valid token in the `Authorization`
header (the authorizer's identity source). Missing/invalid tokens get
`401 Unauthorized`.

Get a token for smoke-testing with the helper script (USER_PASSWORD_AUTH must be
enabled on the app client):

```powershell
# Public app client (no client secret):
$token = ./scripts/get-token.ps1 `
  -ClientId <app-client-id> `
  -Username <user> `
  -Password <password>

# App client configured WITH a client secret — pass -ClientSecret and the
# SECRET_HASH is computed automatically:
$token = ./scripts/get-token.ps1 `
  -ClientId <app-client-id> `
  -Username <user> `
  -Password <password> `
  -ClientSecret <app-client-secret>

Invoke-RestMethod -Method Post -Uri $endpoint `
  -Headers @{ Authorization = $token } `
  -ContentType "application/json" -Body $body
```

`get-token.ps1` parameters:

| Parameter        | Required | Default     | Purpose |
| ---------------- | -------- | ----------- | --------------------------------------------- |
| `-ClientId`      | yes      | —           | Cognito app client ID. |
| `-Username`      | yes      | —           | Cognito username. |
| `-Password`      | yes      | —           | User password. |
| `-ClientSecret`  | no       | —           | Required for app clients that have a secret; used to compute `SECRET_HASH`. |
| `-TokenType`     | no       | `Id`        | `Id` (default, for `COGNITO_USER_POOLS`) or `Access` (for scope checks). |
| `-Region`        | no       | `us-east-1` | AWS region of the user pool. |

By default the **Id** token is returned (what a `COGNITO_USER_POOLS` authorizer
expects). Pass `-TokenType Access` if your authorizer validates access-token
scopes.

Optional fine-grained access: set `CognitoAuthScopes` (e.g. `logs/write`) in the
parameter file to require specific OAuth scopes on the access token.

