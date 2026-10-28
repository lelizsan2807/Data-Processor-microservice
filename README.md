# Data Processor Microservice

## 1. Overview

This project provisions an Ubuntu 22.04 EC2 instance on AWS using Terraform and configures it using Ansible. The application runs in Docker containers managed by Docker Compose and is exposed through Nginx on port `8080`.

The goal is to make the deployment repeatable, automate server configuration, and apply basic security controls.

## 2. Architecture

The deployment consists of the following components:

- **Terraform:** Provisions the AWS infrastructure, including the EC2 instance and security group.
- **Ansible:** Configures the Ubuntu server, installs Docker and the Docker Compose plugin, creates the service account, configures UFW, and deploys the application.
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
├── scripts/
│   ├── deploy.sh
│   ├── deploy.ps1
│   ├── destroy.sh
│   └── destroy.ps1
└── README.md
```

*Note: The exact playbook filename should match the file in the repository. The automation supports `deploy.yml` or `playbook.yml`.*

## 4. Prerequisites

- An AWS account with permissions to create the resources defined in Terraform.
- AWS CLI credentials configured in the environment.
- Terraform.
- Ansible and the `community.general` collection.
- An SSH key pair for connecting to the EC2 instance.
- Git.
- Docker and Docker Compose are installed on the target server by Ansible.

For Windows, the deployment scripts use WSL2 with an Ubuntu distribution because Ansible requires a Linux control environment.

## 5. Configuration

Copy the Terraform example variables file:

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

Edit `terraform/terraform.tfvars` and provide the required values, such as the AWS region, SSH key pair name, and allowed SSH source CIDR, according to the variables defined in `terraform/variables.tf`.

Do not commit the real `terraform.tfvars` file or private SSH keys.

## 6. Deployment

### Option A: Automated deployment

From the repository root in AWS CloudShell or a compatible Linux environment:

```bash
chmod +x scripts/*.sh
./scripts/deploy.sh
```

The script is intended to:

1. Check prerequisites and AWS credentials.
2. Initialize and validate Terraform.
3. Generate and display a Terraform plan.
4. Ask for confirmation before applying infrastructure changes.
5. Retrieve the EC2 public IP from Terraform outputs.
6. Generate the Ansible inventory.
7. Wait for SSH connectivity.
8. Run the Ansible deployment playbook.
9. Check the application endpoint.

Review the Terraform plan before confirming the apply operation.

### Windows PowerShell

With WSL2 and the required tools configured inside the selected Linux distribution:

```powershell
.\scripts\deploy.ps1
```

If your distribution has a different name, specify it:

```powershell
.\scripts\deploy.ps1 -WslDistro "Ubuntu-24.04"
```

### Option B: Manual deployment

Terraform can be run separately:

```bash
cd terraform
terraform init
terraform fmt -check
terraform validate
terraform plan
terraform apply
```

Confirm the plan before applying it.

After provisioning, update the Ansible inventory with the EC2 public IP and the correct SSH key path. Install the required collection:

```bash
ansible-galaxy collection install community.general
```

Run the playbook from the repository root, using the filename present in the repository:

```bash
ansible-playbook -i ansible/inventory/hosts.ini ansible/playbooks/deploy.yml
```

If the playbook is still named `playbook.yml`, use that filename instead.

## 7. Security Controls

The deployment implements the following controls:

- Creates a dedicated `dataproc` service account with UID `2048`.
- Runs the application container as UID `2048`, rather than root.
- Enables UFW with a default-deny incoming policy and allows SSH for administration and TCP port `8080` for application traffic.
- Restricts SSH access through the AWS security group to the configured source CIDR.
- Mounts the Nginx configuration read-only.
- Creates the host Nginx access-log file before starting the container.
- Uses a custom systemd service to manage the Docker Compose lifecycle.
- Applies container hardening settings, including a read-only application filesystem, dropped Linux capabilities for the API container, and `no-new-privileges`.

The AWS security group provides an additional network boundary. Firewall behavior should be verified against the actual Docker and UFW configuration.

## 8. Verification

After deployment, obtain the EC2 public IP from Terraform outputs and test the endpoint:

```bash
curl -i http://<EC2_PUBLIC_IP>:8080/
```

On the EC2 instance, check the service status:

```bash
sudo systemctl status dataproc.service
```

Check the containers:

```bash
sudo docker compose -f /opt/dataproc/docker-compose.yml ps
```

Inspect service logs if something fails:

```bash
sudo journalctl -u dataproc.service
sudo docker logs dataproc-api
sudo docker logs dataproc-nginx
```

The current Python application uses Python's standard-library HTTP server. Confirm the required application behavior separately; a successful HTTP response alone does not establish that a complete business API has been implemented.

## 9. Destroying Infrastructure

When the environment is no longer needed, use the guarded teardown script:

```bash
./scripts/destroy.sh
```

On Windows, use:

```powershell
.\scripts\destroy.ps1
```

The script displays a destruction plan and requires explicit confirmation before deleting Terraform-managed resources.

Alternatively, from the Terraform directory:

```bash
terraform plan -destroy
terraform destroy
```

Review the plan carefully before confirming. Resources created outside the current Terraform state may require separate cleanup.

## 10. Limitations and Future Improvements

- Add automated tests for the application and deployment configuration.
- Implement and document the intended data-processing API behavior.
- Add health checks and improved monitoring.
- Verify the complete deployment and teardown workflow from a clean environment.
- Improve the handling of generated Ansible inventory and Terraform state across environments.

## 11. Summary

This project combines Terraform for infrastructure provisioning, Ansible for server configuration, Docker Compose for container orchestration, and systemd for service lifecycle management. The automation scripts aim to make deployment and cleanup repeatable while preserving explicit confirmation for infrastructure changes.
