@echo off
setlocal

rem One-time, local bootstrap for the whole agent factory:
rem   - S3 bucket + DynamoDB table used as the Terraform remote backend
rem   - GitHub Actions OIDC provider + deploy IAM role/policy
rem
rem Run this by hand from a machine with AWS credentials configured
rem (e.g. `aws configure` or SSO). Every later stack (shared-infra/cognito,
rem agents/*/infra) is deployed by GitHub Actions using the role this
rem script creates, not by this script.

set "SCRIPT_DIR=%~dp0"
set "BOOTSTRAP_DIR=%SCRIPT_DIR%.."

pushd "%BOOTSTRAP_DIR%" || exit /b 1

if not exist "terraform.tfvars" (
    echo terraform.tfvars not found.
    echo Copy terraform.tfvars.example to terraform.tfvars and fill in
    echo github_repository ^(and review the other values^) before running this again.
    popd
    exit /b 1
)

echo === terraform init ===
terraform init
if errorlevel 1 (
    popd
    exit /b 1
)

echo === terraform apply ===
terraform apply
if errorlevel 1 (
    popd
    exit /b 1
)

echo.
echo === Bootstrap complete ===
echo Register these as GitHub Actions repository variables ^(Settings ^> Secrets and variables ^> Actions ^> Variables^):
echo   AWS_REGION            = ^(the region you bootstrapped, e.g. ap-northeast-1^)
echo   AWS_DEPLOY_ROLE_ARN   = terraform output -raw github_actions_role_arn
echo   TF_STATE_BUCKET       = terraform output -raw state_bucket_name
echo   TF_STATE_LOCK_TABLE   = terraform output -raw state_lock_table_name
echo.
terraform output

popd
endlocal
