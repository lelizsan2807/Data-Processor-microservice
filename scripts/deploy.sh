#!/usr/bin/env bash
set -Eeuo pipefail

#!/usr/bin/env bash
set -Eeuo pipefail

# Resolve repository root from the scripts directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Define paths before referencing them.
TF_DIR="$ROOT_DIR/terraform"
ANSIBLE_DIR="$ROOT_DIR/ansible"
INVENTORY_DIR="$ANSIBLE_DIR/inventory"
INVENTORY_FILE="$INVENTORY_DIR/hosts.ini"
PLAYBOOK="$ANSIBLE_DIR/playbooks/deploy.yml"

ANSIBLE_VENV="${ANSIBLE_VENV:-$HOME/ansible-venv}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/data-processor-key}"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '\n==> %s\n' "$*"; }
confirm() {
  local prompt="$1" answer
  read -r -p "$prompt [y/N] " answer
  [[ "$answer" == "y" || "$answer" == "Y" ]] || die "Cancelled by user."
}

[[ -d "$TF_DIR" ]] || die "Terraform directory not found: $TF_DIR"
[[ -d "$ANSIBLE_DIR" ]] || die "Ansible directory not found: $ANSIBLE_DIR"
[[ -f "$TF_DIR/main.tf" ]] || die "No main.tf found in $TF_DIR"
[[ -f "$TF_DIR/terraform.tfvars" ]] || die "Missing $TF_DIR/terraform.tfvars. Copy terraform.tfvars.example and fill in your own values; do not commit the real file."
[[ -f "$SSH_KEY" ]] || die "SSH private key not found: $SSH_KEY (set SSH_KEY to its path)."
command -v aws >/dev/null 2>&1 || die "AWS CLI is missing. Use AWS CloudShell or install/configure AWS CLI."
aws sts get-caller-identity --output text >/dev/null || die "AWS credentials are not configured or are not valid."
aws configure get region >/dev/null 2>&1 || true

install_terraform() {
  [[ "$TF_AUTO_INSTALL" == "1" ]] || die "Terraform is missing. Install Terraform, or set TF_AUTO_INSTALL=1 on supported Amazon Linux 2023."
  [[ -f /etc/os-release ]] || die "Cannot identify OS for automatic Terraform installation."
  . /etc/os-release
  [[ "${ID:-}" == "amzn" && "${VERSION_ID:-}" == 2023* ]] || die "Automatic install supports Amazon Linux 2023 only. Install Terraform manually on this OS."
  info "Installing Terraform on Amazon Linux 2023"
  sudo dnf install -y dnf-utils
  sudo dnf config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo
  sudo dnf clean all
  sudo dnf makecache
  sudo dnf install -y terraform
  command -v terraform >/dev/null 2>&1 || die "Terraform installation finished but terraform is not on PATH."
}

if ! command -v terraform >/dev/null 2>&1; then install_terraform; fi

if ! command -v ansible-playbook >/dev/null 2>&1; then
  info "Creating an isolated Ansible virtual environment"
  command -v python3 >/dev/null 2>&1 || die "python3 is required to install Ansible."
  python3 -m venv "$VENV_DIR" || die "Could not create $VENV_DIR. On Amazon Linux, install python3 and python3-pip first."
  # shellcheck disable=SC1091
  source "$VENV_DIR/bin/activate"
  python -m pip install --upgrade pip
  python -m pip install ansible
else
  # Keep the user's current Ansible installation.
  :
fi

if [[ -f "$VENV_DIR/bin/activate" && ! -x "$(command -v ansible-playbook || true)" ]]; then
  # no-op; the following activation makes the isolated install available
  :
fi
if [[ -x "$VENV_DIR/bin/ansible-playbook" ]]; then
  # Prefer the isolated environment if this script created it.
  # shellcheck disable=SC1091
  source "$VENV_DIR/bin/activate"
fi
command -v ansible-playbook >/dev/null 2>&1 || die "Ansible is unavailable."
ansible-galaxy collection install community.general

info "Terraform initialization and validation"
terraform -chdir="$TF_DIR" init
terraform -chdir="$TF_DIR" fmt -check
terraform -chdir="$TF_DIR" validate

info "Creating Terraform plan"
rm -f "$PLAN_FILE"
terraform -chdir="$TF_DIR" plan -out="$PLAN_FILE" -var="aws_region=$AWS_REGION"
confirm "Review the plan above. Apply these infrastructure changes?"
terraform -chdir="$TF_DIR" apply "$PLAN_FILE"
rm -f "$PLAN_FILE"

# Discover the public-IP output without hardcoding one exact output label.
PUBLIC_IP="$(terraform -chdir="$TF_DIR" output -json | python3 -c '
import json, sys
outputs=json.load(sys.stdin)
preferred=("instance_public_ip","public_ip","ec2_public_ip","dataproc_public_ip")
for name in preferred:
    if name in outputs:
        value=outputs[name].get("value")
        if isinstance(value, str) and value.strip():
            print(value.strip()); raise SystemExit(0)
for name, item in outputs.items():
    value=item.get("value")
    if isinstance(value, str) and value.strip() and ("ip" in name.lower() or "address" in name.lower()):
        print(value.strip()); raise SystemExit(0)
raise SystemExit("No public IP output found. Add an output in terraform/outputs.tf and rerun.")
')" || die "Could not determine EC2 public IP from Terraform outputs."

info "EC2 public IP: $PUBLIC_IP"
PLAYBOOK="$ANSIBLE_DIR/playbooks/deploy.yml"
[[ -f "$PLAYBOOK" ]] || PLAYBOOK="$ANSIBLE_DIR/playbooks/playbook.yml"
[[ -f "$PLAYBOOK" ]] || die "No deploy.yml or playbook.yml found under $ANSIBLE_DIR/playbooks."

mkdir -p "$(dirname "$INVENTORY_FILE")"
cat > "$INVENTORY_FILE" <<EOF
[dataproc_servers]
dataproc-target ansible_host=$PUBLIC_IP ansible_user=ubuntu ansible_ssh_private_key_file=$SSH_KEY ansible_python_interpreter=/usr/bin/python3
EOF
chmod 600 "$INVENTORY_FILE"

info "Waiting for SSH on $PUBLIC_IP"
ready=0
for attempt in $(seq 1 60); do
  if ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -o IdentitiesOnly=yes "ubuntu@$PUBLIC_IP" true >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 5
done
[[ "$ready" == "1" ]] || die "SSH did not become ready within 5 minutes. Check the security group, key pair, and instance status."

info "Running Ansible deployment"
ansible-playbook -i "$INVENTORY_FILE" "$PLAYBOOK"

info "Checking HTTP endpoint"
if command -v curl >/dev/null 2>&1; then
  curl --fail --silent --show-error --max-time 15 "http://$PUBLIC_IP:8080/" || {
    printf 'WARNING: HTTP check failed. Inspect the Ansible output and remote service logs.\n' >&2
    exit 1
  }
  printf '\n'
fi

printf '\nDeployment completed. Endpoint: http://%s:8080/\n' "$PUBLIC_IP"
