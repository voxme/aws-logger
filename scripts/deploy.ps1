<#
.SYNOPSIS
    Package and deploy the aws-logger pipeline to a single environment.

.DESCRIPTION
    Runs `aws cloudformation package` to zip each src/* Lambda and upload it to
    the artifact bucket, then `aws cloudformation deploy` with the matching
    params/<env>.json. Produces an isolated stack per environment.

.EXAMPLE
    ./scripts/deploy.ps1 -Environment staging -ArtifactBucket my-cfn-artifacts-staging

.EXAMPLE
    ./scripts/deploy.ps1 -Environment prod -ArtifactBucket my-cfn-artifacts-prod -Region us-east-1
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("staging", "prod")]
    [string]$Environment,

    [Parameter(Mandatory = $true)]
    [string]$ArtifactBucket,

    [string]$Region = "us-east-1"
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$template = Join-Path $root "template.yaml"
$paramFile = Join-Path $root "params/$Environment.json"
$packaged = Join-Path $root "packaged.$Environment.yaml"
$stackName = "log-ingest-$Environment"

if (-not (Test-Path $paramFile)) {
    throw "Parameter file not found: $paramFile"
}

Write-Host "==> Packaging Lambda artifacts to s3://$ArtifactBucket ..." -ForegroundColor Cyan
aws cloudformation package `
    --template-file $template `
    --s3-bucket $ArtifactBucket `
    --output-template-file $packaged `
    --region $Region
if ($LASTEXITCODE -ne 0) { throw "cloudformation package failed." }

# Convert the JSON parameter file into the "Key=Value" pairs deploy expects.
$paramOverrides = (Get-Content $paramFile -Raw | ConvertFrom-Json) |
    ForEach-Object { "$($_.ParameterKey)=$($_.ParameterValue)" }

Write-Host "==> Deploying stack '$stackName' ..." -ForegroundColor Cyan
aws cloudformation deploy `
    --template-file $packaged `
    --stack-name $stackName `
    --parameter-overrides $paramOverrides `
    --capabilities CAPABILITY_NAMED_IAM `
    --region $Region
if ($LASTEXITCODE -ne 0) { throw "cloudformation deploy failed." }

Write-Host "==> Stack outputs:" -ForegroundColor Green
aws cloudformation describe-stacks `
    --stack-name $stackName `
    --region $Region `
    --query "Stacks[0].Outputs" `
    --output table
