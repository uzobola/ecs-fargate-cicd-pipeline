
# Phase 4: Jenkins CI/CD Infrastructure

## Purpose

Provision and configure a Jenkins server that can build, scan, publish, and
deploy the frontend and backend containers to the existing ECS Fargate
environment.

The responsibility boundary is:

```text
Terraform
    |
    +--> Jenkins EC2 infrastructure
    +--> security group
    +--> IAM role and instance profile
    +--> SSH public key registration
    +--> Elastic IP

Ansible
    |
    +--> Java
    +--> Jenkins
    +--> Docker
    +--> Git
    +--> AWS CLI
    +--> jq
    +--> Trivy
    +--> Checkov

Jenkinsfile
    |
    +--> checkout
    +--> security checks
    +--> container builds
    +--> ECR publication
    +--> ECS deployment
    +--> live validation
```

This separates infrastructure provisioning, host configuration, and application
deployment into independently repeatable layers.

---

## 4.1 Jenkins infrastructure

Jenkins runs on:

```text
Operating system: Amazon Linux 2023
Architecture:     x86_64
Instance type:    c7i-flex.large
Root volume:      30 GiB gp3, encrypted
Jenkins port:     TCP/8080
SSH port:         TCP/22
```

The instance type is exposed as a Terraform variable and can be changed for
another environment.

Jenkins is placed in a public subnet and receives a stable Elastic IP.

The EC2 instance does not rely on an auto-assigned public address for its
long-lived Jenkins endpoint.

```text
Internet
    |
    v
Elastic IP
    |
    v
Jenkins EC2
```

The Elastic IP keeps the Jenkins URL stable across normal EC2 stop/start
operations.

---

## 4.2 Jenkins security group

The Jenkins security group permits:

```text
Inbound
TCP/22    administrator-public-ip/32
TCP/8080  0.0.0.0/0

Outbound
TCP/443   0.0.0.0/0
TCP/80    0.0.0.0/0
```

SSH is restricted to a supplied administrator `/32` address.

TCP/8080 is public so the Jenkins interface can be accessed for challenge
grading and webhook delivery.

HTTPS egress supports GitHub, AWS APIs, ECR, package repositories, and security
tool downloads.

HTTP egress permits Jenkins to perform post-deployment validation against the
challenge ALB, which currently exposes the application through HTTP/80.

A production implementation would normally place Jenkins behind HTTPS and use
a more restricted administrative access model.

---

## 4.3 Jenkins AWS identity

Jenkins does not store a long-lived AWS access key.

Terraform creates:

```text
ecs-fargate-cicd-challenge-jenkins-role
```

and attaches it to EC2 through an instance profile.

The resulting authentication path is:

```text
Jenkins process
      |
      v
EC2 instance profile
      |
      v
temporary STS credentials
      |
      v
AWS APIs
```

The Jenkins role is scoped to the deployment operations required by the
pipeline:

```text
ECR authentication
push to the project frontend/backend repositories
read/register ECS task definitions
update the project frontend/backend ECS services
pass only the application execution roles
read the project ALB hostname
```

Jenkins cannot use this role to administer the VPC or Terraform state.

Verify the workload identity from the Jenkins host:

```bash
sudo -u jenkins -H aws sts get-caller-identity
```

Expected ARN shape:

```text
arn:aws:sts::<account-id>:assumed-role/
ecs-fargate-cicd-challenge-jenkins-role/<session>
```

---

## 4.4 Create the SSH key

Generate the administrative SSH key on the operator workstation:

```bash
ssh-keygen \
  -t ed25519 \
  -f ~/.ssh/ecs-fargate-cicd-jenkins \
  -C "ecs-fargate-cicd-jenkins"
```

Protect the private key:

```bash
chmod 600 ~/.ssh/ecs-fargate-cicd-jenkins
chmod 644 ~/.ssh/ecs-fargate-cicd-jenkins.pub
```

The private key remains local.

Terraform receives only the public key.

Create local Terraform inputs:

```hcl
jenkins_admin_cidr = "<administrator-public-ip>/32"
jenkins_public_key = "<contents-of-public-key>"
```

Store these values in:

```text
terraform/infrastructure/terraform.tfvars
```

`terraform.tfvars` is ignored by Git.

---

## 4.5 Provision Jenkins with Terraform

From the Terraform execution environment:

```bash
terraform -chdir=terraform/infrastructure fmt -recursive
```

Validate:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure validate
```

Plan:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure plan \
  -out=jenkins.tfplan
```

Review the plan before apply.

A new deployment should create the Jenkins EC2 host, IAM resources, security
group rules, SSH key registration, and Elastic IP.

Apply:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure apply \
  jenkins.tfplan
```

Retrieve the management values:

```bash
aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure output \
  jenkins_public_ip

aws-vault exec terraform -- \
  terraform -chdir=terraform/infrastructure output \
  jenkins_url
```

---

## 4.6 Jenkins EC2 lifecycle handling

The Jenkins EC2 resource selects a current Amazon Linux 2023 AMI when a new
instance is created.

The resource lifecycle ignores later changes to:

```text
ami
associate_public_ip_address
```

The first rule prevents a newly published Amazon Linux AMI from replacing an
already configured Jenkins controller during an unrelated Terraform change.

The second prevents replacement of the existing host solely to change the
launch-time auto-public-IP flag. The Terraform-managed Elastic IP is the
authoritative Jenkins public endpoint.

AMI replacement remains an explicit maintenance operation rather than an
incidental side effect of another change.

---

# Phase 4A.2: Configure Jenkins with Ansible

## 4.7 Configuration-management boundary

The EC2 instance is intentionally created without a large `user_data` bootstrap
script.

Ansible configures the operating system after Terraform creates the host.

This provides a repeatable configuration workflow:

```text
fresh Amazon Linux EC2
       |
       v
Ansible
       |
       +--> Java 21
       +--> Jenkins LTS
       +--> Docker
       +--> Git
       +--> AWS CLI
       +--> jq
       +--> Trivy
       +--> Checkov
```

The committed playbook is:

```text
ansible/jenkins.yml
```

---

## 4.8 Verify SSH access

From the Ansible control machine:

```bash
JENKINS_IP="<terraform-output>"
```

Test SSH:

```bash
ssh \
  -i ~/.ssh/ecs-fargate-cicd-jenkins \
  ec2-user@"$JENKINS_IP"
```

Confirm:

```bash
cat /etc/os-release
```

The host must report Amazon Linux 2023.

Exit:

```bash
exit
```

---

## 4.9 Verify Ansible connectivity

```bash
ansible all \
  -i "${JENKINS_IP}," \
  -u ec2-user \
  --private-key ~/.ssh/ecs-fargate-cicd-jenkins \
  -m ansible.builtin.ping
```

Expected:

```text
SUCCESS
"ping": "pong"
```

The trailing comma after the IP tells Ansible to treat the value as an inline
inventory host.

---

## 4.10 Configure the host

Syntax-check the playbook:

```bash
ansible-playbook \
  --syntax-check \
  ansible/jenkins.yml
```

Apply configuration:

```bash
ansible-playbook \
  -i "${JENKINS_IP}," \
  -u ec2-user \
  --private-key ~/.ssh/ecs-fargate-cicd-jenkins \
  ansible/jenkins.yml
```

The playbook installs and configures:

```text
Java 21
Jenkins LTS
Docker
Git
AWS CLI
jq
Trivy
Checkov
```

It enables both Jenkins and Docker as system services.

It places the `jenkins` service account in the Docker group so the pipeline can
build container images.

### Docker privilege tradeoff

Docker-group membership gives the Jenkins service significant control over the
host.

This is accepted for the temporary single-host challenge environment.

A production Jenkins architecture would normally separate the Jenkins
controller from isolated build agents rather than running builds directly on
the controller.

---

## 4.11 Verify configuration idempotency

Run the same playbook again:

```bash
ansible-playbook \
  -i "${JENKINS_IP}," \
  -u ec2-user \
  --private-key ~/.ssh/ecs-fargate-cicd-jenkins \
  ansible/jenkins.yml
```

Required:

```text
failed=0
```

The managed configuration should converge without repeatedly reconfiguring
resources that already match the playbook.

---

## 4.12 Verify Jenkins Docker access

```bash
ssh \
  -i ~/.ssh/ecs-fargate-cicd-jenkins \
  ec2-user@"$JENKINS_IP" \
  'sudo -u jenkins -H docker ps'
```

The command must return without a Docker permission error.

---

## 4.13 Open Jenkins

Retrieve the initial administrator password:

```bash
ssh \
  -i ~/.ssh/ecs-fargate-cicd-jenkins \
  ec2-user@"$JENKINS_IP" \
  'sudo cat /var/lib/jenkins/secrets/initialAdminPassword'
```

Open:

```text
http://<jenkins-eip>:8080
```

Complete initial setup and install the suggested plugins.

Create a permanent administrator account.

Do not commit the bootstrap password or Jenkins credentials to Git.

---
