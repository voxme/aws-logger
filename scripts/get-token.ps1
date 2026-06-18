<#
.SYNOPSIS
    Fetch a Cognito token for smoke-testing the protected /logging endpoint.

.DESCRIPTION
    Authenticates a user against a Cognito User Pool app client using the
    USER_PASSWORD_AUTH flow and prints a token to stdout. By default it returns
    the Id token (what a COGNITO_USER_POOLS authorizer expects by default); pass
    -TokenType Access if your authorizer validates access-token scopes.

    The app client must have the ALLOW_USER_PASSWORD_AUTH auth flow enabled and,
    for a public (no-secret) client, no client secret. For app clients WITH a
    secret, pass -ClientSecret and the SECRET_HASH is computed automatically.

.EXAMPLE
    $token = ./scripts/get-token.ps1 -ClientId 1abc... -Username alice -Password 'P@ss'
    Invoke-RestMethod -Method Post -Uri $endpoint -Headers @{ Authorization = $token } `
        -ContentType "application/json" -Body $body

.EXAMPLE
    ./scripts/get-token.ps1 -ClientId 1abc... -Username alice -Password 'P@ss' -TokenType Access
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ClientId,

    [Parameter(Mandatory = $true)]
    [string]$Username,

    [Parameter(Mandatory = $true)]
    [string]$Password,

    [string]$ClientSecret,

    [ValidateSet("Id", "Access")]
    [string]$TokenType = "Id",

    [string]$Region = "us-east-1"
)

$ErrorActionPreference = "Stop"

# Build the auth parameters; add SECRET_HASH when the client has a secret.
$authParams = @{ USERNAME = $Username; PASSWORD = $Password }
if ($ClientSecret) {
    $message = [Text.Encoding]::UTF8.GetBytes($Username + $ClientId)
    $key = [Text.Encoding]::UTF8.GetBytes($ClientSecret)
    $hmac = [System.Security.Cryptography.HMACSHA256]::new($key)
    $authParams.SECRET_HASH = [Convert]::ToBase64String($hmac.ComputeHash($message))
}

# CLI expects auth parameters as a single comma-delimited shorthand argument
# (Name1=Value1,Name2=Value2). Passing them as separate space-delimited tokens
# causes the CLI to treat all but the first as unknown options.
$authParamArgs = ($authParams.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ","

# Capture stdout and stderr. Temporarily relax ErrorActionPreference so the
# AWS CLI's stderr writes don't become terminating NativeCommandError records
# before we can inspect them.
$prevEap = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$raw = & aws cognito-idp initiate-auth `
    --auth-flow USER_PASSWORD_AUTH `
    --client-id $ClientId `
    --auth-parameters $authParamArgs `
    --region $Region `
    --output json 2>&1 | Out-String
$exit = $LASTEXITCODE
$ErrorActionPreference = $prevEap

if ($exit -ne 0) {
    throw "Cognito initiate-auth failed:`n$raw"
}

$resp = $raw | ConvertFrom-Json

# A challenge (e.g. NEW_PASSWORD_REQUIRED) means no tokens were issued yet.
if ($resp.ChallengeName) {
    throw ("Cognito returned challenge '$($resp.ChallengeName)' instead of tokens. " +
        "Set a permanent password with 'aws cognito-idp admin-set-user-password --permanent' and retry.")
}

if (-not $resp.AuthenticationResult) {
    throw "Authentication succeeded but no tokens were returned. Raw response:`n$raw"
}

if ($TokenType -eq "Access") {
    $resp.AuthenticationResult.AccessToken
}
else {
    $resp.AuthenticationResult.IdToken
}
