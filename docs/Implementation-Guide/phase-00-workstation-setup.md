# Workstation Setup

## Purpose

This document prepares the workstation with the AWS command-line tools
and authentication configuration required to deploy and manage this project.

The project uses:

```text
AWS CLI v2
AWS Vault
Git Bash on Windows
AWS IAM role assumption
MFA
Temporary AWS credentials
```

Terraform and AWS CLI commands in this implementation are executed through
AWS Vault rather than directly with long-lived AWS credentials.

---

## Shell Environment

This project was developed and tested on Windows using **Git Bash** for
Terraform, AWS CLI, and AWS Vault commands. 

( The underlying tools are not dependent on Git Bash and may also be used from
other supported shells, including PowerShell, Linux shells, and macOS Terminal.)

WSL was used for Linux-side tooling and local validation tasks.

Keeping these environments separate avoids differences in:

```text
PATH handling
SSH key paths
credential storage
Windows vs Linux binaries
```


The commands in this guide are written using **Bash syntax**. Engineers using
another shell may need to adjust:

- line-continuation characters
- environment-variable syntax
- file paths
- quoting rules

For example, this guide may show a multi-line Bash command as:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure plan
```
The same command can be executed on one line from most shells:
```bash
aws-vault exec terraform -- terraform -chdir=terraform/infrastructure plan
```

An engineer using another operating system may adapt the commands to their
environment.

---

# 1. Install and Configure the AWS CLI

The AWS CLI is required for:

- validating the active AWS identity
- inspecting deployed AWS resources
- interacting with Amazon ECR
- interacting with Amazon ECS
- validating deployments
- supporting Terraform authentication workflows
- performing environment cleanup

This project uses **AWS CLI version 2**.

---

## 1.1 Windows

AWS CLI v2 can be installed using the official Windows MSI package.

Open PowerShell and run:

```powershell
msiexec.exe /i https://awscli.amazonaws.com/AWSCLIV2.msi
```

Complete the installer.

Close and reopen the terminal after installation.

Verify:

```bash
aws --version
```

Example:

```text
aws-cli/2.x.x ...
```

When using Git Bash on Windows, the Windows AWS CLI installation should also be
available:

```bash
aws --version
```

---

## 1.2 Linux / WSL

Install the required utilities:

```bash
sudo apt update
sudo apt install -y curl unzip
```

Download the AWS CLI v2 installer for x86_64:

```bash
curl \
  "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" \
  -o "awscliv2.zip"
```

Extract it:

```bash
unzip awscliv2.zip
```

Install:

```bash
sudo ./aws/install
```

Verify:

```bash
aws --version
```

Remove the installer files:

```bash
rm -rf aws awscliv2.zip
```

For an ARM64 Linux system, use the ARM64 installer instead:

```bash
curl \
  "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" \
  -o "awscliv2.zip"
```

Then continue with the same extraction and installation steps.

---

## 1.3 macOS

Download the AWS CLI v2 package:

```bash
curl \
  "https://awscli.amazonaws.com/AWSCLIV2.pkg" \
  -o "AWSCLIV2.pkg"
```

Install:

```bash
sudo installer \
  -pkg AWSCLIV2.pkg \
  -target /
```

Verify:

```bash
aws --version
```

Remove the installer:

```bash
rm AWSCLIV2.pkg
```

---

# 2. Choose an AWS Authentication Method

Installing the AWS CLI does not authenticate the workstation to AWS.

AWS supports several authentication mechanisms.

Common approaches include:

```text
AWS IAM Identity Center / SSO
IAM role assumption
temporary credentials
credential-management tools such as AWS Vault
```

The appropriate authentication method depends on the engineer's AWS
environment.

> **This project was implemented using AWS Vault, MFA, a source AWS identity,
> and a dedicated Terraform execution role.**

The AWS Vault workflow is documented later in this guide.

---

## 2.1 Optional: AWS IAM Identity Center / SSO

An engineer whose AWS organization uses IAM Identity Center may configure the
AWS CLI using:

```bash
aws configure sso
```

Follow the prompts for:

```text
SSO start URL
SSO Region
AWS account
permission set / role
profile name
```

Authenticate:

```bash
aws sso login \
  --profile <profile-name>
```

Verify:

```bash
aws sts get-caller-identity \
  --profile <profile-name>
```

This is an alternative authentication model.

It is **not required in addition to AWS Vault** unless the engineer's AWS
environment specifically combines the two approaches.

---

## 2.2 Alternative: Named AWS Credential Profile

If an engineer has been provided credentials through an approved mechanism,
they may create a named profile:

```bash
aws configure \
  --profile <profile-name>
```

The AWS CLI prompts for:

```text
AWS Access Key ID
AWS Secret Access Key
Default Region
Default output format
```

For this project:

```text
Default Region: us-east-1
Default output format: json
```

Prefer temporary credentials or federated authentication where available.

Do not commit AWS credentials to this repository.

---

# 3. Project Authentication Model

This implementation does not execute Terraform directly using the workstation's
base AWS identity.

The authentication flow is:

```text
Engineer
    |
    v
Source AWS identity
    |
    | credentials stored by AWS Vault
    v
AWS Vault
    |
    | STS AssumeRole + MFA
    v
Terraform execution IAM role
    |
    | temporary AWS credentials
    v
AWS CLI / Terraform
```

The engineer authenticates using an approved source AWS identity.

That identity then assumes a dedicated Terraform execution IAM role.

Commands are executed through:

```bash
aws-vault exec terraform -- <command>
```

For example:

```bash
aws-vault exec terraform -- \
  aws sts get-caller-identity
```

Terraform commands use the same pattern:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure plan
```

> **Environment-specific values**
>
> AWS account IDs, source-profile names, IAM role ARNs, usernames, and MFA
> device ARNs must be replaced with values appropriate to the engineer's AWS
> environment.

Do not copy another engineer's AWS identity configuration verbatim.

---

# 4. Install AWS Vault

AWS Vault securely stores source AWS credentials using the operating system's
credential store and obtains temporary AWS credentials for commands executed
through it.

The project uses AWS Vault so long-lived AWS credentials do not need to be
placed directly in:

```text
shell environment variables
Terraform configuration
project source files
scripts
```

AWS Vault is complementary to the AWS CLI and reads AWS profile configuration
from the standard AWS configuration files.

---

## 4.1 Windows

This project executes AWS Vault from Git Bash on Windows.

AWS Vault can be installed using Chocolatey.

Open an elevated PowerShell terminal:

```powershell
choco install aws-vault
```

Close and reopen Git Bash.

Verify:

```bash
aws-vault --version
```

On Windows, AWS Vault can use Windows Credential Manager as its secure
credential backend.

---

## 4.2 macOS

Install using Homebrew:

```bash
brew install aws-vault
```

Verify:

```bash
aws-vault --version
```

On macOS, AWS Vault can use the macOS Keychain as its secure credential
backend.

---

## 4.3 Linux

AWS Vault also supports Linux credential-storage backends.

Engineers running the project entirely from Linux should use an appropriate
supported secure credential backend for their workstation.

This project's tested Terraform/AWS authentication workflow, however, uses
AWS Vault from **Git Bash on Windows**.

---

# 5. Understand the AWS Profiles

The project authentication model uses two logical profiles.

```text
Source profile
    |
    | AssumeRole
    v
Terraform role profile
```

The source profile represents the engineer's initial AWS identity.

The Terraform profile represents the IAM role that performs infrastructure
operations.

Example names:

```text
Source profile: engineer
Role profile:   terraform
```

The names are examples only.

The actual source profile depends on the engineer's AWS environment.

---

# 6. Store Source Credentials in AWS Vault

Add the source AWS credentials to AWS Vault:

```bash
aws-vault add <source-profile>
```

Example:

```bash
aws-vault add engineer
```

AWS Vault prompts for the credentials associated with the source identity.

For example:

```text
Access Key ID
Secret Access Key
```

Depending on the AWS Vault version and configuration, it may also prompt for
MFA information.

The credentials are stored in the workstation's secure credential store rather
than in the project repository.

Verify the credential entry:

```bash
aws-vault list
```

Example:

```text
Profile       Credentials
=======       ===========
engineer      engineer
```

The exact output may vary by AWS Vault version.

---

## Important: Do Not Store Role Credentials

Do not add separate long-lived credentials for the Terraform role.

For example, do **not** create independent credentials with:

```text
aws-vault add terraform
```

when `terraform` is an assumed-role profile.

The intended model is:

```text
Long-lived/source credential
        |
        v
Source profile
        |
        | AssumeRole
        v
terraform profile
        |
        v
Temporary role credentials
```

AWS Vault stores the source credentials.

AWS STS supplies the temporary credentials for the assumed role.

---

# 7. Configure AWS Profiles

AWS CLI profile configuration is stored in the AWS configuration file.

On Linux and macOS:

```text
~/.aws/config
```

On Windows:

```text
%USERPROFILE%\.aws\config
```

From Git Bash on Windows, the same file is normally available through:

```text
~/.aws/config
```

---

## 7.1 Configure the Source Profile

Example:

```ini
[profile engineer]
region = us-east-1
output = json
```

Replace:

```text
engineer
```

with the engineer's actual source-profile name.

---

## 7.2 Configure the Terraform Role Profile

Configure a second profile that assumes the Terraform execution role:

```ini
[profile terraform]
source_profile = engineer
role_arn = arn:aws:iam::<AWS_ACCOUNT_ID>:role/<TERRAFORM_EXECUTION_ROLE>
mfa_serial = arn:aws:iam::<AWS_ACCOUNT_ID>:mfa/<MFA_DEVICE>
region = us-east-1
output = json
```

Replace:

```text
engineer
<AWS_ACCOUNT_ID>
<TERRAFORM_EXECUTION_ROLE>
<MFA_DEVICE>
```

with environment-specific values.

A complete example structure is:

```ini
[profile engineer]
region = us-east-1
output = json

[profile terraform]
source_profile = engineer
role_arn = arn:aws:iam::<AWS_ACCOUNT_ID>:role/<TERRAFORM_EXECUTION_ROLE>
mfa_serial = arn:aws:iam::<AWS_ACCOUNT_ID>:mfa/<MFA_DEVICE>
region = us-east-1
output = json
```

---

# 8. Understand `source_profile`

The following configuration:

```ini
source_profile = engineer
```

means:

```text
Use the credentials stored for "engineer"
        |
        v
Authenticate the source identity
        |
        v
Call AWS STS AssumeRole
        |
        v
Assume the Terraform execution role
```

The source identity must have permission to assume the Terraform execution
role.

The Terraform execution role must also trust the appropriate source identity.

Both sides of that relationship must be configured correctly.

---

# 9. Understand MFA

The role profile may include:

```ini
mfa_serial = arn:aws:iam::<AWS_ACCOUNT_ID>:mfa/<MFA_DEVICE>
```

When MFA is required, AWS Vault prompts the engineer for the current MFA code
before obtaining temporary credentials.

Example workflow:

```text
aws-vault exec terraform -- ...
        |
        v
AWS Vault reads source credentials
        |
        v
Engineer enters MFA code
        |
        v
AWS STS validates identity
        |
        v
Terraform role is assumed
        |
        v
Temporary credentials are returned
```

MFA codes must never be stored in the repository.

---

# 10. Verify the Source Identity

Before testing role assumption, confirm that the source profile works.

Run:

```bash
aws-vault exec <source-profile> -- \
  aws sts get-caller-identity
```

Example:

```bash
aws-vault exec engineer -- \
  aws sts get-caller-identity
```

Example response:

```json
{
  "UserId": "...",
  "Account": "123456789012",
  "Arn": "arn:aws:iam::123456789012:user/engineer"
}
```

Verify that:

```text
Account
ARN
Identity
```

match the expected source AWS environment.

---

# 11. Verify Terraform Role Assumption

Next, verify that AWS Vault can assume the Terraform execution role:

```bash
aws-vault exec terraform -- \
  aws sts get-caller-identity
```

If MFA is configured, AWS Vault prompts for the current MFA code.

A successful response should resemble:

```json
{
  "UserId": "...",
  "Account": "<AWS_ACCOUNT_ID>",
  "Arn": "arn:aws:sts::<AWS_ACCOUNT_ID>:assumed-role/<TERRAFORM_EXECUTION_ROLE>/..."
}
```

The important difference is the ARN.

The expected pattern is:

```text
arn:aws:sts::<account-id>:assumed-role/<role-name>/...
```

rather than the original IAM user identity.

Confirm both:

```text
AWS account
Assumed role name
```

before continuing.

---

# 12. Verify AWS CLI Configuration

Check the installed AWS CLI:

```bash
aws --version
```

Check available AWS Vault profiles:

```bash
aws-vault list
```

Inspect AWS CLI configuration:

```bash
aws configure list \
  --profile terraform
```

Verify the final authenticated identity:

```bash
aws-vault exec terraform -- \
  aws sts get-caller-identity
```

Do not continue with Terraform until the AWS account and assumed role have been
verified.

---

# 13. Execute AWS CLI Commands Through AWS Vault

AWS CLI commands that require project infrastructure permissions should use:

```bash
aws-vault exec terraform -- \
  <aws-command>
```

For example:

```bash
aws-vault exec terraform -- \
  aws sts get-caller-identity
```

List ECS clusters:

```bash
aws-vault exec terraform -- \
  aws ecs list-clusters \
    --region us-east-1
```

List ECR repositories:

```bash
aws-vault exec terraform -- \
  aws ecr describe-repositories \
    --region us-east-1
```

The AWS Vault wrapper provides temporary credentials to the child AWS CLI
process.

---

# 14. Execute Terraform Through AWS Vault

Terraform follows the same authentication model.

Initialize:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure init
```

Validate:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure validate
```

Plan:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure plan
```

Apply:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure apply
```

Destroy operations also use the same authentication wrapper:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure plan \
    -destroy
```

The same pattern is used throughout the Implementation Guide:

```text
aws-vault exec terraform -- <AWS CLI or Terraform command>
```

---

# 15. Why AWS Vault Is Used

The authentication design separates long-lived source credentials from
short-lived infrastructure credentials.

```text
Source credentials
      |
      | stored securely
      v
AWS Vault
      |
      | authentication + MFA
      v
AWS STS
      |
      | temporary role credentials
      v
Terraform execution role
      |
      v
Terraform / AWS CLI
```

Benefits include:

```text
No AWS credentials committed to Git
No static Terraform credentials
Temporary role sessions
Centralized role permissions
MFA support
Clear separation between source identity and infrastructure permissions
```

---

# 16. Credential Safety

Never commit any of the following:

```text
AWS Access Key ID
AWS Secret Access Key
AWS session token
MFA code
AWS Vault credential data
local AWS credentials files
Terraform state containing sensitive values
Terraform plan files containing sensitive values
```

The following files and directories should remain local:

```text
~/.aws/credentials
~/.aws/config
Terraform local state files
Terraform plan files
.terraform/
```

The AWS configuration file may contain non-secret configuration such as role
ARNs and profile names, but the workstation copy should still remain outside
the project repository.

---

# 17. Environment-Specific Values

An engineer reproducing this project must replace all environment-specific
values.

Examples include:

```text
AWS account ID
source-profile name
IAM user or federated identity
Terraform execution role ARN
MFA device ARN
administrator public IP
Terraform state bucket name
GitHub repository identity
```

Do not copy values from the original deployment unless the engineer is
deploying into the same authorized AWS environment.

---

# 18. Authentication Verification Checklist

Before provisioning infrastructure, confirm:

```text
[ ] AWS CLI v2 is installed
[ ] aws --version succeeds
[ ] AWS Vault is installed
[ ] aws-vault --version succeeds
[ ] Source credentials are stored in AWS Vault
[ ] Source AWS profile is configured
[ ] Terraform role profile is configured
[ ] MFA is configured when required
[ ] Source identity can authenticate
[ ] Terraform role can be assumed
[ ] aws sts get-caller-identity returns the expected AWS account
[ ] The returned ARN contains the expected assumed Terraform role
[ ] No AWS credentials are stored in the repository
```

Only continue with Terraform after these checks pass.

---

# 19. Authentication Command Summary

Source identity:

```bash
aws-vault exec <source-profile> -- \
  aws sts get-caller-identity
```

Terraform execution identity:

```bash
aws-vault exec terraform -- \
  aws sts get-caller-identity
```

Terraform validation:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure validate
```

Terraform plan:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure plan
```

The expected project authentication pattern is therefore:

```text
Engineer
    |
    v
AWS Vault
    |
    v
Source AWS identity
    |
    | MFA + AssumeRole
    v
Terraform execution role
    |
    v
Temporary STS credentials
    |
    +----------------------+
    |                      |
    v                      v
AWS CLI                Terraform
```