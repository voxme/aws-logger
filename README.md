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
├── scripts/
│   ├── deploy.ps1                # package + deploy one environment
│   └── validate.ps1              # cfn-lint / validate-template
└── .github/workflows/deploy.yml  # CI/CD: staging on develop, prod on main/tag
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
| push to `develop`     | Staging              |
| push to `main` or tag | Production           |
| manual dispatch       | choose `staging`/`prod` |

Configure these repository secrets:

- `AWS_ROLE_ARN_STAGING`, `AWS_ROLE_ARN_PROD` – OIDC roles to assume.
- `ARTIFACT_BUCKET_STAGING`, `ARTIFACT_BUCKET_PROD` – packaging buckets.

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
$token = ./scripts/get-token.ps1 `
  -ClientId <app-client-id> `
  -Username <user> `
  -Password <password>

Invoke-RestMethod -Method Post -Uri $endpoint `
  -Headers @{ Authorization = $token } `
  -ContentType "application/json" -Body $body
```

Optional fine-grained access: set `CognitoAuthScopes` (e.g. `logs/write`) in the
parameter file to require specific OAuth scopes on the access token.

