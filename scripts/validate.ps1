<#
.SYNOPSIS
    Validate the CloudFormation template before deploying.

.DESCRIPTION
    Runs `aws cloudformation validate-template`, and `cfn-lint` if it is
    installed (pip install cfn-lint).

.EXAMPLE
    ./scripts/validate.ps1
#>
[CmdletBinding()]
param(
    [string]$Region = "us-east-1"
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$template = Join-Path $root "template.yaml"

Write-Host "==> aws cloudformation validate-template ..." -ForegroundColor Cyan
aws cloudformation validate-template --template-body "file://$template" --region $Region | Out-Null
if ($LASTEXITCODE -ne 0) { throw "validate-template failed." }
Write-Host "    OK" -ForegroundColor Green

if (Get-Command cfn-lint -ErrorAction SilentlyContinue) {
    Write-Host "==> cfn-lint ..." -ForegroundColor Cyan
    cfn-lint $template
    if ($LASTEXITCODE -ne 0) { throw "cfn-lint reported issues." }
    Write-Host "    OK" -ForegroundColor Green
}
else {
    Write-Host "cfn-lint not installed - skipping (pip install cfn-lint)." -ForegroundColor Yellow
}
