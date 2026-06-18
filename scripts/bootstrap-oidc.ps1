<#
.SYNOPSIS
    One-time bootstrap of the GitHub Actions OIDC deploy role for an environment.

.DESCRIPTION
    Deploys bootstrap/github-oidc.yaml, then prints the role ARN and (if gh CLI
    is available and -SetSecrets is passed) sets the GitHub repository secrets.

.EXAMPLE
    ./scripts/bootstrap-oidc.ps1 `
        -Environment staging `
        -ArtifactBucket voxme-cfn-artifacts-staging `
        -GitHubOrg voxme -GitHubRepo aws-logger `
        -Branch staging -SetSecrets

.NOTES
    The GitHub OIDC provider can exist only once per account. If you already
    created it, pass -CreateProvider:$false.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("staging", "prod")]
    [string]$Environment,

    [Parameter(Mandatory = $true)]
    [string]$ArtifactBucket,

    [string]$GitHubOrg = "voxme",
    [string]$GitHubRepo = "aws-logger",
    [string]$Branch = "staging",

    [bool]$CreateProvider = $true,
    [switch]$SetSecrets,
    [string]$Region = "us-east-1"
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$template = Join-Path $root "bootstrap/github-oidc.yaml"
$stackName = "gh-oidc-log-ingest-$Environment"
$roleName = "gh-deploy-log-ingest-$Environment"
$subPattern = "repo:$GitHubOrg/$GitHubRepo`:ref:refs/heads/$Branch"

Write-Host "==> Ensuring artifact bucket s3://$ArtifactBucket exists ..." -ForegroundColor Cyan
$exists = aws s3api head-bucket --bucket $ArtifactBucket --region $Region 2>$null
if ($LASTEXITCODE -ne 0) {
    aws s3 mb "s3://$ArtifactBucket" --region $Region
    if ($LASTEXITCODE -ne 0) { throw "Failed to create artifact bucket." }
}

Write-Host "==> Deploying OIDC bootstrap stack '$stackName' ..." -ForegroundColor Cyan
aws cloudformation deploy `
    --template-file $template `
    --stack-name $stackName `
    --capabilities CAPABILITY_NAMED_IAM `
    --region $Region `
    --parameter-overrides `
    GitHubOrg=$GitHubOrg `
    GitHubRepo=$GitHubRepo `
    GitHubRefPattern=$subPattern `
    ArtifactBucketName=$ArtifactBucket `
    CreateOidcProvider=$($CreateProvider.ToString().ToLower()) `
    RoleName=$roleName
if ($LASTEXITCODE -ne 0) { throw "OIDC bootstrap deploy failed." }

$roleArn = aws cloudformation describe-stacks `
    --stack-name $stackName `
    --region $Region `
    --query "Stacks[0].Outputs[?OutputKey=='RoleArn'].OutputValue" `
    --output text

Write-Host ""
Write-Host "Role ARN: $roleArn" -ForegroundColor Green

$envUpper = $Environment.ToUpper()
if ($SetSecrets) {
    if (Get-Command gh -ErrorAction SilentlyContinue) {
        Write-Host "==> Setting GitHub secrets via gh CLI ..." -ForegroundColor Cyan
        gh secret set "AWS_ROLE_ARN_$envUpper" --body $roleArn
        gh secret set "ARTIFACT_BUCKET_$envUpper" --body $ArtifactBucket
        Write-Host "    Secrets set." -ForegroundColor Green
    }
    else {
        Write-Host "gh CLI not found - set these secrets manually:" -ForegroundColor Yellow
        Write-Host "  AWS_ROLE_ARN_$envUpper    = $roleArn"
        Write-Host "  ARTIFACT_BUCKET_$envUpper = $ArtifactBucket"
    }
}
else {
    Write-Host "Set these GitHub repository secrets:" -ForegroundColor Yellow
    Write-Host "  AWS_ROLE_ARN_$envUpper    = $roleArn"
    Write-Host "  ARTIFACT_BUCKET_$envUpper = $ArtifactBucket"
}
