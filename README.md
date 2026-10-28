# Data Processor Microservice

## 1. Overview

This project provisions an Ubuntu 22.04 EC2 instance on AWS using Terraform and configures it using Ansible. The application runs in Docker containers managed by Docker Compose and is exposed through Nginx on port `8080`.

The goal is to make deployment repeatable, automate server configuration, and apply basic security controls.

## 2. Architecture

The deployment consists of the following components:

- **Terraform:** Provisions the AWS infrastructure, including the EC2 instance and security group.
- **Ansible:** Configures Ubuntu, installs Docker and the Docker Compose plugin, creates the service account, configures UFW, and deploys the application.
- **Docker Compose:** Runs the application and Nginx containers.
- **Nginx:** Acts as a reverse proxy and writes access logs to the host.
- **systemd:** Manages the application stack through a custom `dataproc.service` unit.

Traffic flows through Nginx on port `8080` to the application on port `5000` inside the Docker network.

## 3. Repository Structure

```text
Data-Processor-microservice/
├── app/
│   ├── app.py
│   ├── Dockerfile
│   └── entrypoint.sh
├── ansible/
│   ├── inventory/
    |    └── hosts.ini.example
│   ├── playbooks/
│   │   └── deploy.yml
│   └── roles/
│       └── dataproc/
│           ├── handlers/
│           ├── tasks/
│           └── templates/
│               ├── dataproc.service.j2
│               ├── docker-compose.yml.j2
│               └── nginx.conf.j2
├── terraform/
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   └── terraform.tfvars.example
└── README.md
```

## 4. Deployment Guide

### 4.1 Prerequisites and local system check

The deployment is intended for Ubuntu/Lubuntu or a compatible Debian-based Linux system. You need:

- An AWS account or authorized training/lab account.
- An AWS identity permitted to create the resources declared by the Terraform configuration.
- Internet access and `sudo` privileges on the local machine.
- The repository cloned locally.
- Enough free disk space to install tools.

### 4.2 Install local prerequisites

```bash
sudo apt update
sudo apt install -y git openssh-client python3 python3-venv python3-pip ca-certificates curl gnupg lsb-release wget
```

If the command fails, resolve the APT error before continuing.

#### Install AWS CLI

Try the Ubuntu package:

```bash
sudo apt install -y awscli
aws --version
```

If your package sources do not provide AWS CLI, use the official AWS instructions: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html. Continue only after `aws --version` succeeds.

#### Install Terraform

Use HashiCorp's official Linux install instructions if needed: https://developer.hashicorp.com/terraform/install.

For Ubuntu/Debian, the HashiCorp APT repository can be configured as follows:

```bash
wget -O- https://apt.releases.hashicorp.com/gpg | gpg --dearmor | sudo tee /usr/share/keyrings/hashicorp-archive-keyring.gpg >/dev/null
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(. /etc/os-release && echo "$VERSION_CODENAME") main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update
sudo apt install -y terraform
terraform -version
```

#### Install Ansible

```bash
sudo apt install -y ansible
ansible --version
```

If the package is unavailable, use the official Ansible installation guide: https://docs.ansible.com/ansible/latest/installation_guide/intro_installation.html.

### 4.3 Clone the repository

If you have not cloned it yet:

```bash
git clone https://github.com/lelizsan2807/Data-Processor-microservice.git
cd Data-Processor-microservice
git switch release-v1
```

### 4.4 Create an SSH key pair

Create a dedicated key on the same Lubuntu machine where you will run Terraform and Ansible:

```bash
mkdir -p ~/.ssh
chmod 700 ~/.ssh
ssh-keygen -t ed25519 -a 100 -f ~/.ssh/data-processor-key -C "data-processor"
```

Choose a passphrase if you can manage it securely. The command creates:

- `~/.ssh/data-processor-key`: the **private key**. Keep it secret; never commit or send it.
- `~/.ssh/data-processor-key.pub`: the **public key**. Terraform will register this public key with AWS.

Set file permissions:

```bash
chmod 600 ~/.ssh/data-processor-key
chmod 644 ~/.ssh/data-processor-key.pub
ls -l ~/.ssh/data-processor-key*
```

If the key already exists, do not overwrite it unless you intentionally want to replace it.

### 4.5 Configure AWS authentication

Terraform uses AWS credentials to call AWS APIs. These credentials are separate from the SSH key created in the previous step.

#### Option A: AWS IAM access keys

Use an IAM identity approved by your account administrator. Do **not** create access keys for the AWS root user. If you are permitted to create IAM user access keys, in the AWS Console open **IAM → Users → select your user → Security credentials → Access keys → Create access key**. Store the secret access key securely when AWS shows it; the secret is not shown again later.

Configure the CLI:

```bash
aws configure
```

Enter the Access Key ID, matching Secret Access Key, default region `us-east-1`, and output format `json`.

#### Option B: AWS IAM Identity Center (SSO)

If your organization uses IAM Identity Center, configure and sign in:

```bash
aws configure sso
aws sso login
```

Follow the prompts for your organization's SSO start URL, region, and profile. If you use a named profile rather than the default, use that profile consistently, for example `aws sts get-caller-identity --profile YOUR_PROFILE` and set `AWS_PROFILE=YOUR_PROFILE` in the terminal before running Terraform.

#### Verify AWS credentials

```bash
aws sts get-caller-identity
aws configure list
```

The first command should return the AWS account and authenticated identity. If you use SSO or a named profile, run the command with that profile or set `AWS_PROFILE` first.

### 4.6 Review AWS permissions

The AWS identity needs permission for the EC2 operations used by the Terraform configuration, including applicable instance, key-pair, security-group, tagging, and describe operations, plus `sts:GetCallerIdentity`. The exact permissions depend on the Terraform resources and organization policies.

Terraform planning does not guarantee that every operation will be permitted during `apply`. If AWS returns `AccessDenied`, ask the account administrator to review the permissions. Do not bypass organization policies.

### 4.7 Create Terraform variables

From the repository root, copy the example file:

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
nano terraform/terraform.tfvars
```

Fill in the values. For example:

```hcl
aws_region      = "us-east-1"
instance_type   = "t3.micro"
my_ip_cidr      = "REPLACE_WITH_YOUR_PUBLIC_IPV4/32"
public_key_path = "/home/REPLACE_WITH_YOUR_LINUX_USERNAME/.ssh/data-processor-key.pub"
project_name    = "data-processor"
```
You can check the IP with this command:
```curl -4 https://checkip.amazonaws.com```

Replace `REPLACE_WITH_YOUR_PUBLIC_IPV4` with your current public IPv4 address. Keep `/32` to allow SSH from one IPv4 address. If your IP changes, update this variable and apply the Terraform change after reviewing its plan.

Find your Linux username and home directory:

```bash
whoami
echo "$HOME"
```

Use the actual full path for the public key. For example, if `$HOME` is `/home/student`, set `public_key_path` to `/home/student/.ssh/data-processor-key.pub`.

Save in nano with **Ctrl+O**, Enter, then **Ctrl+X**. Check that the public key exists:

```bash
test -f ~/.ssh/data-processor-key.pub && echo "Public key found"
cat terraform/terraform.tfvars
```

The file should contain configuration values only, not AWS credentials. Keep `terraform/terraform.tfvars` out of Git.

### 4.8 Initialize and validate Terraform

Run from the repository root:

```bash
terraform -chdir=terraform init
terraform -chdir=terraform fmt -check
terraform -chdir=terraform validate
terraform -chdir=terraform plan
```

Read the plan carefully. Confirm the region and instance type, verify SSH ingress is limited to your IP CIDR, verify application port `8080` is configured as intended, and check that there are no unexpected changes or deletions.

If the plan is correct, create the infrastructure:

```bash
terraform -chdir=terraform apply
```

Review the plan shown by Terraform and type `yes` only if you approve it.

Get the outputs and public IP:

```bash
terraform -chdir=terraform output
terraform -chdir=terraform output -raw public_ip
```

For convenience in the current terminal:

```bash
EC2_IP="$(terraform -chdir=terraform output -raw public_ip)"
printf '%s\n' "$EC2_IP"
```

### 4.9 Test SSH connectivity

Wait for the EC2 instance to finish booting, then run:

```bash
EC2_IP="$(terraform -chdir=terraform output -raw public_ip)"
ssh -i ~/.ssh/data-processor-key -o IdentitiesOnly=yes ubuntu@"$EC2_IP"
```

Use the private key without `.pub` and the Ubuntu username `ubuntu`. Review the host-key prompt before accepting it. When connected, run `exit` to return to Lubuntu.

If SSH times out, check that the instance is running, has a public IP, the security group allows TCP port `22` from your current public IP, and your network permits outbound SSH. If the public IP changed, update `my_ip_cidr` and review/apply the Terraform plan.

### 4.10 Create the Ansible inventory

Check whether an inventory file already exists:

```bash
find ansible/inventory -maxdepth 2 -type f -print
```

Create or edit `ansible/inventory/hosts.ini`:

```bash
nano ansible/inventory/hosts.ini
```

Add the following, replacing the placeholders:

```ini
[dataproc_servers]
REPLACE_WITH_EC2_PUBLIC_IP ansible_user=ubuntu ansible_ssh_private_key_file=/home/REPLACE_WITH_YOUR_LINUX_USERNAME/.ssh/data-processor-key
```

Use the EC2 public IP from Terraform and the **private key path** (without `.pub`). Use the full path returned by `echo "$HOME"` if that differs from `/home/USERNAME`.

Test Ansible connectivity:

```bash
ansible -i ansible/inventory/hosts.ini dataproc_servers -m ping
```

### 4.11 Configure Ansible role discovery

The repository root should contain an ansible.cfg file. This tells Ansible where to find the project role and sets the default inventory.

From the project root, create or edit it:

```
nano ansible.cfg
```

Add:
```
[defaults]
roles_path = ./ansible/roles
inventory = ./ansible/inventory/hosts.ini
```

Save the file. Confirm Ansible detects it:

```
ansible --version
```

The output should show the ansible.cfg path in the project root. Run Ansible commands from the project root so the relative role path resolves as expected.

Resolve SSH or inventory errors before running the playbook.

### 4.12 Install required Ansible collections and deploy

Install the general collection used by many Ansible roles, then syntax-check the playbook:

```bash
ansible-galaxy collection install community.general
ansible-playbook -i ansible/inventory/hosts.ini --syntax-check ansible/playbooks/deploy.yml
```

Run the deployment:

```bash
ansible-playbook -i ansible/inventory/hosts.ini ansible/playbooks/deploy.yml
```

Review the output. A successful run should end with `failed=0` and `unreachable=0`. If a task fails, read the first failure and fix its cause before rerunning.

## 5. Verify the deployment

Get the public IP and test Nginx:

```bash
EC2_IP="$(terraform -chdir=terraform output -raw public_ip)"
curl -i --max-time 15 "http://${EC2_IP}:8080/"
```

An HTTP response confirms that something answered the request; it does not prove every expected API operation works. Verify the actual endpoint and response against the behavior implemented in `app/app.py`.

Connect to the instance:

```bash
ssh -i ~/.ssh/data-processor-key ubuntu@"$EC2_IP"
```

Check systemd and the containers:

```bash
sudo systemctl status dataproc.service --no-pager
sudo docker compose -f /opt/dataproc/docker-compose.yml ps
sudo journalctl -u dataproc.service --no-pager -n 100
sudo docker logs --tail 100 dataproc-api
sudo docker logs --tail 100 dataproc-nginx
sudo tail -n 50 /var/log/nginx/custom-access.log
```

Exit with `exit`.

## 6. Troubleshooting

### AWS authentication fails

```bash
aws sts get-caller-identity
aws configure list
```

Reconfigure the appropriate credential source or refresh expired training-lab credentials.

### AWS returns `AccessDenied`

The identity may lack a required permission, or an organization policy may deny the operation. Review the AWS error and contact the account administrator/lab instructor.

### Terraform cannot read the public key

Check that `public_key_path` in `terraform/terraform.tfvars` points to the `.pub` file on the local machine running Terraform.

### SSH access fails

Check the EC2 instance state, public IP, matching key pair, username `ubuntu`, security-group port `22` source CIDR, and local network access.

### Ansible fails

Test SSH manually with the same private key and IP. Verify the inventory host name, username, and key path. Then inspect the first failing Ansible task.

### Port 8080 does not respond

Check the AWS security group, instance UFW rules, systemd status, Docker Compose status, and Nginx/application logs.

### `wget` is missing or GPG says no valid OpenPGP data

Install `wget` through APT if possible. If GPG reports `no valid OpenPGP data found`, the response was not a valid key. Check network access and the complete command output. Do not disable signature checking or use an unverified key.

## 7. Security Controls

The intended deployment controls include:

- A dedicated `dataproc` service account with UID `2048`.
- An application container running as UID `2048`, not root.
- UFW enabled with a default-deny incoming policy, allowing SSH for administration and TCP port `8080` for application traffic.
- AWS security-group SSH ingress restricted to the configured source CIDR.
- Read-only mount for the Nginx configuration.
- Host Nginx access-log file created before the container starts.
- A custom systemd unit managing the Docker Compose lifecycle.
- Container hardening including a read-only application filesystem, dropped Linux capabilities for the API container, and `no-new-privileges`.

Verify these controls against the actual Ansible role and the deployed instance.

## 8. Destroy Infrastructure (manual)

AWS resources may incur charges. When finished, review the destroy plan before removing anything. Run from the repository root:

```bash
terraform -chdir=terraform plan -destroy
```

If the plan lists only the resources you intend to remove and you are authorized to remove them:

```bash
terraform -chdir=terraform destroy
```

Review the plan and type `yes` only when you intend to delete those resources. Resources created outside the current Terraform state may require separate cleanup.


## 9. Summary

This project uses Terraform for infrastructure provisioning, Ansible for server configuration, Docker Compose for container orchestration, and systemd for service lifecycle management. This manual workflow lets each step be reviewed and tested independently without using the deployment scripts.
