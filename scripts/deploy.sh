
#!/usr/bin/env bash
set -Eeuo pipefail

# Resolve repository root from scripts/deploy.sh.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TF_DIR="$ROOT_DIR/terraform"
TFVARS="$TF_DIR/terraform.tfvars"
ANSIBLE_DIR="$ROOT_DIR/ansible"
INVENTORY_DIR="$ANSIBLE_DIR/inventory"
INVENTORY_FILE="$INVENTORY_DIR/hosts.ini"
PLAYBOOK="$ANSIBLE_DIR/playbooks/deploy.yml"

ANSIBLE_VENV="${ANSIBLE_VENV:-$HOME/ansible-venv}"

log() {
    printf '\n==> %s\n' "$*"
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

# ------------------------------------------------------------
# 1. Check project files and base dependencies
# ------------------------------------------------------------
for path in \
    "$TF_DIR/main.tf" \
    "$TF_DIR/terraform.tfvars.example" \
    "$ANSIBLE_DIR/roles/dataproc/tasks/main.yml" \
    "$PLAYBOOK"
do
    [[ -f "$path" ]] || die "Required project file not found: $path"
done

for tool in python3 ssh ssh-keygen curl; do
    command -v "$tool" >/dev/null 2>&1 ||
        die "Required command '$tool' is missing."
done

command -v terraform >/dev/null 2>&1 ||
    die "Terraform is not installed or not on PATH."

command -v aws >/dev/null 2>&1 ||
    die "AWS CLI is not installed or not on PATH."

# ------------------------------------------------------------
# 2. Automatically create Terraform variables when missing
# ------------------------------------------------------------
log "Preparing Terraform variables"

TFVARS="$TF_DIR/terraform.tfvars"

if [[ ! -f "$TFVARS" ]]; then
    SETUP_SCRIPT="$SCRIPT_DIR/setup-terraform.sh"

    [[ -f "$SETUP_SCRIPT" ]] ||
        die "Missing $SETUP_SCRIPT"

    chmod +x "$SETUP_SCRIPT"
    "$SETUP_SCRIPT"
fi

[[ -f "$TFVARS" ]] || die "terraform.tfvars was not created."
chmod 600 "$TFVARS"

# Read the public key path from Terraform variables.
PUBLIC_KEY_PATH="$(
    python3 - "$TFVARS" <<'PY'
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
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

# This setup script creates the public key by appending .pub
# to the selected private key path.
SSH_KEY="${SSH_KEY:-${PUBLIC_KEY_PATH%.pub}}"

[[ -f "$PUBLIC_KEY_PATH" ]] ||
    die "SSH public key not found: $PUBLIC_KEY_PATH"

[[ -f "$SSH_KEY" ]] ||
    die "Matching SSH private key not found: $SSH_KEY"

chmod 600 "$SSH_KEY"

# ------------------------------------------------------------
# 3. Validate AWS credentials
# ------------------------------------------------------------
log "Checking AWS credentials"

AWS_REGION="$(
    python3 - "$TFVARS" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r'(?m)^\s*aws_region\s*=\s*"([^"]+)"', text)
print(m.group(1) if m else "us-east-1")
PY
)"

export AWS_REGION
export AWS_DEFAULT_REGION="$AWS_REGION"

aws sts get-caller-identity >/dev/null ||
    die "AWS credentials are unavailable. Configure your AWS CLI or CloudShell session."

# ------------------------------------------------------------
# 4. Initialize and apply Terraform
# ------------------------------------------------------------
log "Initializing Terraform"
terraform -chdir="$TF_DIR" init

log "Validating Terraform"
terraform -chdir="$TF_DIR" validate

log "Planning infrastructure"
terraform -chdir="$TF_DIR" plan -out=deploy.tfplan

log "Applying infrastructure"
terraform -chdir="$TF_DIR" apply deploy.tfplan
rm -f "$TF_DIR/deploy.tfplan"

# ------------------------------------------------------------
# 5. Get the EC2 public IP
# ------------------------------------------------------------
log "Reading EC2 public IP"

EC2_IP="$(terraform -chdir="$TF_DIR" output -raw public_ip)"
[[ -n "$EC2_IP" ]] || die "Terraform returned an empty public IP."

echo "EC2 public IP: $EC2_IP"

# ------------------------------------------------------------
# 6. Prepare Ansible virtual environment
# ------------------------------------------------------------
log "Preparing Ansible"

if [[ ! -x "$ANSIBLE_VENV/bin/ansible-playbook" ]]; then
    python3 -m venv "$ANSIBLE_VENV" ||
        die "Could not create the virtual environment. Install Python venv support for your distribution."
    "$ANSIBLE_VENV/bin/python" -m pip install --upgrade pip
    "$ANSIBLE_VENV/bin/python" -m pip install ansible
fi

export PATH="$ANSIBLE_VENV/bin:$PATH"

command -v ansible-playbook >/dev/null 2>&1 ||
    die "ansible-playbook is unavailable."

ansible-galaxy collection install community.general

# ------------------------------------------------------------
# 7. Generate Ansible inventory automatically
# ------------------------------------------------------------
log "Generating Ansible inventory"

mkdir -p "$INVENTORY_DIR"

cat > "$INVENTORY_FILE" <<INVENTORY
[dataproc_servers]
${EC2_IP} ansible_user=ubuntu ansible_ssh_private_key_file=${SSH_KEY} ansible_python_interpreter=/usr/bin/python3
INVENTORY

chmod 600 "$INVENTORY_FILE"

# ------------------------------------------------------------
# 8. Wait for SSH
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
    die "Could not connect to ubuntu@$EC2_IP. Check the SSH key and security group."

# ------------------------------------------------------------
# 9. Deploy with Ansible
# ------------------------------------------------------------
log "Running Ansible deployment"

export ANSIBLE_ROLES_PATH="$ANSIBLE_DIR/roles"

ansible-playbook \
    -i "$INVENTORY_FILE" \
    "$PLAYBOOK"

# ------------------------------------------------------------
# 10. Print results
# ------------------------------------------------------------
APP_URL="$(terraform -chdir="$TF_DIR" output -raw application_url)"

log "Deployment completed successfully"
echo "Application URL: $APP_URL"
echo "EC2 public IP:   $EC2_IP"
echo "SSH command:     ssh -i \"$SSH_KEY\" ubuntu@$EC2_IP"
