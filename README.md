# Policy-as-Code Lab — GCP + GitHub + VS Code
## Complete hands-on guide: OPA · Checkov · Regula · Cloud Custodian

---

## Lab Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│  YOUR MACHINE (VS Code)                                          │
│                                                                  │
│  Gate 0: Checkov VS Code Extension  ← instant red underlines    │
│  Gate 0b: Pre-commit hooks          ← blocks git commit         │
└────────────────────┬─────────────────────────────────────────────┘
                     │ git push / pull request
┌────────────────────▼─────────────────────────────────────────────┐
│  GITHUB ACTIONS PIPELINE                                         │
│                                                                  │
│  Gate 1: Checkov Static Scan        ← CIS GCP benchmark         │
│  Gate 2a: Terraform Plan → JSON                                  │
│  Gate 2b: OPA Eval (your Rego)      ← custom rules              │
│  Gate 2c: Regula (150+ CIS rules)   ← framework policies        │
│  Gate 3: terraform apply            ← only if Gates 1+2 pass    │
│  Gate 4: Cloud Custodian scan       ← live resource check       │
└────────────────────┬─────────────────────────────────────────────┘
                     │
┌────────────────────▼─────────────────────────────────────────────┐
│  GCP (Free Tier)                                                 │
│   ├── VPC + Firewall (0.0.0.0/0 — intentional violation)        │
│   ├── GCS Bucket (public, no versioning — intentional)          │
│   └── GCE e2-micro VM (no shielded VM — intentional)            │
└──────────────────────────────────────────────────────────────────┘
```

---

## Repository Structure

```
policy-as-code-lab/
├── terraform/
│   ├── versions.tf              # Provider config
│   ├── variables.tf             # Input variables
│   ├── main.tf                  # 3 resources with intentional violations
│   ├── outputs.tf               # Resource outputs
│   └── terraform.tfvars.example # Copy and fill in your values
│
├── policies/
│   ├── opa/
│   │   └── gcp_security.rego   # Custom OPA Rego policies
│   └── custodian/
│       └── gcp-policies.yml    # Cloud Custodian live scan policies
│
├── .github/
│   └── workflows/
│       └── policy-pipeline.yml  # Full 4-gate CI/CD pipeline
│
├── .checkov.yml                 # Checkov configuration
├── .pre-commit-config.yaml      # Pre-commit hooks
└── README.md                    # This file
```

---

## STEP 1 — Local Machine Setup

### 1.1 Install Required Tools

```bash
# Terraform
wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install terraform

# Verify
terraform --version

# OPA
curl -L -o opa https://github.com/open-policy-agent/opa/releases/download/v0.63.0/opa_linux_amd64_static
chmod +x opa && sudo mv opa /usr/local/bin/
opa version

# Regula
curl -L https://github.com/fugue/regula/releases/download/v3.2.1/regula_3.2.1_Linux_x86_64.tar.gz | tar xz
sudo mv regula /usr/local/bin/
regula --version

# Checkov
pip install checkov
checkov --version

# Cloud Custodian GCP
pip install c7n c7n-gcp
custodian --version

# Pre-commit
pip install pre-commit

# GCP CLI
# https://cloud.google.com/sdk/docs/install
gcloud --version
```

### 1.2 VS Code Extensions to Install

Open VS Code → Extensions (Ctrl+Shift+X) → Search and install:

| Extension | Publisher | Purpose |
|---|---|---|
| **Checkov** | Bridgecrew | Real-time policy violations in editor |
| **HashiCorp Terraform** | HashiCorp | Terraform syntax + validation |
| **OPA** | Open Policy Agent | Rego syntax highlighting |
| **GitLens** | GitKraken | See git diff inline |

After installing Checkov extension:
- Open any `.tf` file — violations show as red/yellow underlines immediately
- Hover over the underline to see the policy ID and fix suggestion

---

## STEP 2 — GCP Setup

### 2.1 Create GCP Project & Enable APIs

```bash
# Login
gcloud auth login
gcloud auth application-default login

# Create project (or use existing)
gcloud projects create policy-lab-$(date +%s) --name="Policy Lab"
gcloud config set project YOUR_PROJECT_ID

# Enable required APIs
gcloud services enable \
  compute.googleapis.com \
  storage.googleapis.com \
  cloudresourcemanager.googleapis.com
```

### 2.2 Create Service Account for GitHub Actions

```bash
# Set your project
export PROJECT_ID=$(gcloud config get-value project)

# Create SA
gcloud iam service-accounts create github-terraform-sa \
  --display-name="GitHub Terraform SA"

# Grant required roles
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:github-terraform-sa@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/compute.admin"

gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:github-terraform-sa@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/storage.admin"

gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:github-terraform-sa@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/iam.serviceAccountUser"

# Create and download key
gcloud iam service-accounts keys create sa-key.json \
  --iam-account=github-terraform-sa@$PROJECT_ID.iam.gserviceaccount.com

# Base64 encode it for GitHub Secrets
base64 -w0 sa-key.json
# Copy the output — you'll need it in Step 3
```

---

## STEP 3 — GitHub Setup

### 3.1 Create Repository and Push Code

```bash
# Clone this lab or init fresh
git init policy-as-code-lab
cd policy-as-code-lab

# Copy all lab files here, then:
git add .
git commit -m "feat: initial policy-as-code lab setup"

# Create repo on GitHub, then:
git remote add origin https://github.com/YOUR_USERNAME/policy-as-code-lab.git
git push -u origin main
```

### 3.2 Add GitHub Secrets

Go to: GitHub Repo → Settings → Secrets and variables → Actions → New secret

| Secret Name | Value |
|---|---|
| `GCP_PROJECT_ID` | Your GCP project ID (e.g., `my-project-123`) |
| `GCP_SA_KEY` | The base64 output from Step 2.2 |

### 3.3 Set Up GitHub Environment (for manual approval on apply)

Go to: GitHub Repo → Settings → Environments → New environment

- Name: `production`
- Enable "Required reviewers" → add yourself
- This means `terraform apply` needs your manual approval

---

## STEP 4 — Configure Pre-commit (Local Gate)

```bash
cd policy-as-code-lab

# Install pre-commit hooks into git
pre-commit install

# Test it manually (runs against all files)
pre-commit run --all-files
```

You'll see Checkov run against your Terraform files and report violations.

---

## STEP 5 — Run the Full Flow

### 5.1 Test Gate 0 — VS Code (Immediate Feedback)

1. Open `terraform/main.tf` in VS Code
2. Look at the firewall resource — you'll see red underlines on `source_ranges = ["0.0.0.0/0"]`
3. Hover to see: `CKV_GCP_88: Ensure that SSH access is restricted from the internet`

### 5.2 Test Gate 0b — Pre-commit Hook

```bash
# Try to commit — pre-commit will run Checkov first
git add terraform/main.tf
git commit -m "test: checking pre-commit gate"
# You'll see Checkov output with violations before commit succeeds
```

### 5.3 Test Checkov Locally (Gate 1 equivalent)

```bash
cd terraform/
checkov --directory . --framework terraform
# Expected: Multiple FAILED checks for our intentional violations
```

### 5.4 Test OPA Locally (Gate 2 equivalent)

```bash
# Generate terraform plan JSON
cd terraform/
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your project ID

terraform init
terraform plan -var="project_id=YOUR_PROJECT_ID" -out=tfplan.binary
terraform show -json tfplan.binary > tfplan.json

# Run OPA evaluation
opa eval \
  --data ../policies/opa/gcp_security.rego \
  --input tfplan.json \
  --format pretty \
  "data.rules.gcp_security.deny"

# Expected output: List of violation messages for all 6 deny rules
```

### 5.5 Test Regula Locally

```bash
cd terraform/
regula run tfplan.json --input-type tf-plan --format table
# Expected: Multiple HIGH severity violations from CIS GCP benchmark
```

### 5.6 Test GitHub Actions Pipeline

```bash
# Create a feature branch
git checkout -b feature/test-policy-pipeline

# Make a small change (add a comment)
echo "# test" >> terraform/main.tf

# Push and create a Pull Request
git add . && git commit -m "test: trigger policy pipeline"
git push origin feature/test-policy-pipeline
```

Then go to GitHub → Pull Requests → Open new PR
Watch the Actions tab — Gates 1 and 2 will run and report violations.
Gate 3 (apply) only runs when you merge to main.

### 5.7 Test Cloud Custodian (After Apply)

```bash
# After terraform apply creates the resources:
export GOOGLE_PROJECT=YOUR_PROJECT_ID

custodian run \
  --configs policies/custodian/gcp-policies.yml \
  --output-dir ./custodian-output

# See what was flagged
ls custodian-output/
cat custodian-output/gcp-firewall-open-ssh/resources.json | python3 -m json.tool
```

---

## STEP 6 — Observe the Violations

### Expected Violations Per Tool

| # | Resource | Violation | Checkov | OPA | Regula | Custodian |
|---|---|---|---|---|---|---|
| 1 | Firewall | 0.0.0.0/0 on SSH port 22 | CKV_GCP_88 | deny[1] | FG_R00379 | gcp-firewall-open-ssh |
| 2 | Firewall | No logging | CKV2_GCP_12 | warn | — | — |
| 3 | GCS Bucket | Public access (allUsers) | CKV_GCP_28 | deny[3] | FG_R00357 | gcp-bucket-public-access |
| 4 | GCS Bucket | No versioning | CKV_GCP_29 | deny[4] | FG_R00358 | gcp-bucket-no-versioning |
| 5 | GCE VM | No Shielded VM | CKV_GCP_39 | deny[5] | FG_R00410 | gcp-vm-no-shielded |
| 6 | GCE VM | Public IP assigned | CKV_GCP_40 | — | FG_R00411 | gcp-vm-public-ip |
| 7 | GCE VM | Default SA + full scope | CKV_GCP_30 | deny[6] | — | — |
| 8 | GCE VM | Serial port enabled | CKV_GCP_35 | — | — | — |

---

## STEP 7 — Fix One Violation (See Pipeline Go Green)

To see how a fix flows through the pipeline, fix the firewall rule:

```hcl
# In terraform/main.tf, change:
source_ranges = ["0.0.0.0/0"]   # ← violation

# To your specific IP:
source_ranges = ["YOUR.IP.ADDRESS/32"]  # Get your IP: curl ifconfig.me
```

Commit, push, create PR → Gate 2 OPA check should pass for that specific rule.

---

## Cleanup

```bash
# Destroy all GCP resources when done (avoid any charges)
cd terraform/
terraform destroy -var="project_id=YOUR_PROJECT_ID" -auto-approve

# Remove service account
gcloud iam service-accounts delete github-terraform-sa@YOUR_PROJECT_ID.iam.gserviceaccount.com
rm sa-key.json  # Never commit this file!
```

---

## Key Learning Points

1. **Gate 0 (VS Code + Pre-commit)** — Catches issues before code is even committed. Zero pipeline cost.
2. **Gate 1 (Checkov)** — Scans Terraform HCL statically, no GCP credentials needed.
3. **Gate 2 (OPA + Regula)** — Evaluates the Terraform plan (what WILL be created), not just the code.
4. **Gate 3 (Apply)** — Only reaches here if all previous gates pass.
5. **Gate 4 (Custodian)** — Catches drift — resources that were compliant when created but changed later.

The difference between OPA (Gate 2) and Custodian (Gate 4):
- OPA = **Pre-deploy prevention** (stops bad infra from being created)
- Custodian = **Post-deploy detection** (catches bad infra that already exists)
