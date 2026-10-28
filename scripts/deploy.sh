
#!/usr/bin/env bash
set -Eeuo pipefail

# Resolve paths relative to scripts/deploy.sh.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TF_DIR="$ROOT_DIR/terraform"
TFVARS="$TF_DIR/terraform.tfvars"
ANSIBLE_DIR="$ROOT_DIR/ansible"
INVENTORY_DIR="$ANSIBLE_DIR/inventory"
INVENTORY_FILE="$INVENTORY_DIR/hosts.ini"
PLAYBOOK="$ANSIBLE_DIR/playbooks/deploy.yml"

ANSIBLE_VENV="${ANSIBLE_VENV:-$HOME/ansible-venv}"
TF_PLAN="$TF_DIR/deploy.tfplan"

log() {
    printf '\n==> %s\n' "$*"
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

cleanup() {
    rm -f "$TF_PLAN"
}
trap cleanup EXIT

# ------------------------------------------------------------
# 1. Verify project files
# ------------------------------------------------------------
for path in \
    "$TF_DIR/main.tf" \
    "$TF_DIR/terraform.tfvars.example" \
    "$ANSIBLE_DIR/roles/dataproc/tasks/main.yml" \
    "$PLAYBOOK" \
    "$SCRIPT_DIR/setup-terraform.sh"
do
    [[ -f "$path" ]] || die "Required project file not found: $path"
done

# ------------------------------------------------------------
# 2. Install prerequisites where possible
# ------------------------------------------------------------
log "Checking system prerequisites"

for tool in sudo apt-get; do
    command -v "$tool" >/dev/null 2>&1 ||
        die "Required command '$tool' is missing."
done

if [[ "$(id -u)" -ne 0 ]]; then
    sudo -v || die "Administrator privileges are required to install dependencies."
fi

if ! command -v terraform >/dev/null 2>&1; then
    log "Installing Terraform"

    sudo apt-get update
    sudo apt-get install -y wget gpg ca-certificates

    sudo install -d -m 0755 /usr/share/keyrings

    wget -qO- https://apt.releases.hashicorp.com/gpg \
        | gpg --dearmor \
        | sudo tee /usr/share/keyrings/hashicorp-archive-keyring.gpg >/dev/null

    sudo chmod 644 /usr/share/keyrings/hashicorp-archive-keyring.gpg

    CODENAME="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")"

    [[ -n "$CODENAME" ]] || die "Could not determine the OS release codename."

    echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com ${CODENAME} main" \
        | sudo tee /etc/apt/sources.list.d/hashicorp.list >/dev/null

    sudo apt-get update
    sudo apt-get install -y terraform
fi

# Install packages that provide the other required commands and
# Python virtual-environment support.
sudo apt-get update
sudo apt-get install -y \
    python3 \
    python3-venv \
    python3-pip \
    openssh-client \
    curl \
    ca-certificates \
    awscli

for tool in python3 ssh ssh-keygen curl aws terraform; do
    command -v "$tool" >/dev/null 2>&1 ||
        die "Required command '$tool' is still missing after installation."
done

terraform -version
aws --version

# ------------------------------------------------------------
# 3. Prepare Terraform variables
# ------------------------------------------------------------
log "Preparing Terraform variables"

if [[ ! -f "$TFVARS" ]]; then
    chmod +x "$SCRIPT_DIR/setup-terraform.sh"
    "$SCRIPT_DIR/setup-terraform.sh"
fi

[[ -f "$TFVARS" ]] || die "terraform.tfvars was not created."
chmod 600 "$TFVARS"

# Read public_key_path from terraform.tfvars.
PUBLIC_KEY_PATH="$(
    python3 - "$TFVARS" <<'PY'
import re
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    text = f.read()

match = re.search(
    r'(?m)^\s*public_key_path\s*=\s*"((?:\\.|[^"\\])*)"\s*$',
    text
)

if not match:
    sys.exit("Could not read public_key_path from terraform.tfvars.")

value = match.group(1)
value = value.replace(r'\"', '"').replace(r'\\', '\\')
print(value)
PY
)" || die "Could not read the public key path."

SSH_KEY="${SSH_KEY:-${PUBLIC_KEY_PATH%.pub}}"

[[ -f "$PUBLIC_KEY_PATH" ]] ||
    die "SSH public key not found: $PUBLIC_KEY_PATH"

[[ -f "$SSH_KEY" ]] ||
    die "Matching SSH private key not found: $SSH_KEY"

chmod 600 "$SSH_KEY"

# ------------------------------------------------------------
# 4. Validate AWS credentials
# ------------------------------------------------------------
log "Checking AWS credentials"

AWS_REGION="$(
    python3 - "$TFVARS" <<'PY'
import re
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    text = f.read()

match = re.search(r'(?m)^\s*aws_region\s*=\s*"([^"]+)"', text)
print(match.group(1) if match else "us-east-1")
PY
)"

export AWS_REGION
export AWS_DEFAULT_REGION="$AWS_REGION"

aws sts get-caller-identity >/dev/null ||
    die "AWS credentials are unavailable or invalid. Configure AWS CLI credentials first."

# ------------------------------------------------------------
# 5. Initialize and validate Terraform
# ------------------------------------------------------------
log "Initializing Terraform"
terraform -chdir="$TF_DIR" init

log "Validating Terraform"
terraform -chdir="$TF_DIR" validate

# ------------------------------------------------------------
# 6. Plan and confirm infrastructure changes
# ------------------------------------------------------------
log "Planning infrastructure"
terraform -chdir="$TF_DIR" plan -out=deploy.tfplan

echo
echo "Review the Terraform plan above."
read -r -p "Apply these infrastructure changes? This may incur AWS charges. [y/N] " CONFIRM

case "$CONFIRM" in
    y|Y|yes|YES)
        log "Applying Terraform plan"
        terraform -chdir="$TF_DIR" apply deploy.tfplan
        ;;
    *)
        die "Deployment cancelled. No Terraform changes were applied."
        ;;
esac

# ------------------------------------------------------------
# 7. Get the EC2 public IP
# ------------------------------------------------------------
log "Reading EC2 public IP"

EC2_IP="$(terraform -chdir="$TF_DIR" output -raw public_ip)"
[[ -n "$EC2_IP" ]] || die "Terraform returned an empty public IP."

echo "EC2 public IP: $EC2_IP"

# ------------------------------------------------------------
# 8. Prepare Ansible virtual environment
# ------------------------------------------------------------
log "Preparing Ansible"

if [[ ! -x "$ANSIBLE_VENV/bin/ansible-playbook" ]]; then
    python3 -m venv "$ANSIBLE_VENV" ||
        die "Could not create the Ansible virtual environment."

    "$ANSIBLE_VENV/bin/python" -m pip install --upgrade pip
    "$ANSIBLE_VENV/bin/python" -m pip install ansible
fi

export PATH="$ANSIBLE_VENV/bin:$PATH"

command -v ansible-playbook >/dev/null 2>&1 ||
    die "ansible-playbook is unavailable."

ansible-galaxy collection install community.general

# ------------------------------------------------------------
# 9. Generate Ansible inventory
# ------------------------------------------------------------
log "Generating Ansible inventory"

mkdir -p "$INVENTORY_DIR"

cat > "$INVENTORY_FILE" <<INVENTORY
[dataproc_servers]
${EC2_IP} ansible_user=ubuntu ansible_ssh_private_key_file=${SSH_KEY} ansible_python_interpreter=/usr/bin/python3
INVENTORY

chmod 600 "$INVENTORY_FILE"

# ------------------------------------------------------------
# 10. Wait for SSH
# ------------------------------------------------------------
log "Waiting for SSH access"

SSH_READY=false

for attempt in $(seq 1 30); do
    if ssh \
        -i "$SSH_KEY" \
        -o BatchMode=yes \
        -o ConnectTimeout=5 \
        -o StrictHostKeyChecking=accept-new \
        "ubuntu@$EC2_IP" true
    then
        SSH_READY=true
        break
    fi

    echo "SSH not ready (attempt $attempt/30)."
    sleep 10
done

[[ "$SSH_READY" == true ]] ||
    die "Could not connect to ubuntu@$EC2_IP. Check the SSH key, security group, and instance status."

# ------------------------------------------------------------
# 11. Deploy with Ansible
# ------------------------------------------------------------
log "Running Ansible deployment"

export ANSIBLE_ROLES_PATH="$ANSIBLE_DIR/roles"

ansible-playbook \
    -i "$INVENTORY_FILE" \
    "$PLAYBOOK"

# ------------------------------------------------------------
# 12. Print results
# ------------------------------------------------------------
APP_URL="$(terraform -chdir="$TF_DIR" output -raw application_url)"

log "Deployment completed successfully"
echo "Application URL: $APP_URL"
echo "EC2 public IP:   $EC2_IP"
echo "SSH command:     ssh -i \"$SSH_KEY\" ubuntu@$EC2_IP"
