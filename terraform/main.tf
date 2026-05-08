# ============================================================
# POLICY-AS-CODE LAB — 3 GCP Resources
# These resources have INTENTIONAL policy violations so you
# can see Checkov, OPA/Regula, and Cloud Custodian flag them.
#
# Violations planted:
#   Resource 1 - Firewall : allows 0.0.0.0/0 ingress on port 22 (SSH open to world)
#   Resource 2 - GCS Bucket: public access not explicitly blocked + no versioning
#   Resource 3 - GCE VM   : no shielded VM + missing required labels
# ============================================================


# ── RESOURCE 1: VPC Network ──────────────────────────────────
resource "google_compute_network" "lab_vpc" {
  name                    = "policy-lab-vpc"
  auto_create_subnetworks = false
  description             = "Lab VPC for policy-as-code testing"
}

resource "google_compute_subnetwork" "lab_subnet" {
  name          = "policy-lab-subnet"
  ip_cidr_range = "10.0.1.0/24"
  region        = var.region
  network       = google_compute_network.lab_vpc.id

  # VIOLATION: private_ip_google_access should be true
  private_ip_google_access = false
}

# ── RESOURCE 1b: Firewall Rule (VIOLATION PLANTED) ───────────
resource "google_compute_firewall" "allow_ssh_world" {
  name    = "policy-lab-allow-ssh-world"
  network = google_compute_network.lab_vpc.name

  # ❌ VIOLATION: SSH open to the entire internet — 0.0.0.0/0
  # This will be flagged by:
  #   - Checkov (CKV_GCP_88)
  #   - OPA/Regula (FG_R00379)
  #   - Cloud Custodian (firewall-open-ssh policy)
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"]   # ← intentional violation
  target_tags   = ["lab-vm"]

  # ❌ VIOLATION: No logging enabled (CKV2_GCP_12)
  # log_config { metadata = "INCLUDE_ALL_METADATA" }
}


# ── RESOURCE 2: GCS Bucket (VIOLATION PLANTED) ───────────────
resource "google_storage_bucket" "lab_bucket" {
  name          = "${var.project_id}-policy-lab-bucket"
  location      = "US"
  force_destroy = true

  # ❌ VIOLATION: No versioning enabled (CKV_GCP_29)
  # versioning { enabled = true }

  # ❌ VIOLATION: No uniform bucket-level access (CKV_GCP_28)
  uniform_bucket_level_access = false

  # ❌ VIOLATION: No retention policy (CKV_GCP_78)
  # retention_policy { retention_period = 604800 }

  # Missing labels — flagged by custodian
  labels = {
    environment = var.environment
    # missing: "owner", "data-classification" labels
  }
}

# ❌ VIOLATION: Public bucket IAM — allUsers can read objects (CKV_GCP_28)
resource "google_storage_bucket_iam_member" "public_read" {
  bucket = google_storage_bucket.lab_bucket.name
  role   = "roles/storage.objectViewer"
  member = "allUsers"   # ← intentional violation — makes bucket public
}


# ── RESOURCE 3: GCE VM (VIOLATION PLANTED) ───────────────────
resource "google_compute_instance" "lab_vm" {
  name         = "policy-lab-vm"
  machine_type = "e2-micro"   # free-tier eligible
  zone         = var.zone

  tags = ["lab-vm"]

  # ❌ VIOLATION: No required labels (CKV_GCP_32)
  labels = {
    environment = var.environment
    # missing: "owner", "cost-center" labels
  }

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
      size  = 10

      # ❌ VIOLATION: Boot disk not encrypted with CMEK (CKV_GCP_38)
      # (acceptable for lab — free tier doesn't support CMEK)
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.lab_subnet.id

    # ❌ VIOLATION: Public IP assigned (CKV_GCP_40)
    # Remove this block to fix the violation
    access_config {}
  }

  # ❌ VIOLATION: Shielded VM not enabled (CKV_GCP_39)
  # shielded_instance_config {
  #   enable_secure_boot          = true
  #   enable_vtpm                 = true
  #   enable_integrity_monitoring = true
  # }

  # ❌ VIOLATION: Default service account with full API access (CKV_GCP_30)
  service_account {
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
    # No email = uses default compute SA
  }

  metadata = {
    # ❌ VIOLATION: OS Login not enabled (CKV_GCP_32)
    # enable-oslogin = "TRUE"

    # ❌ VIOLATION: Serial port enabled (CKV_GCP_35)
    serial-port-enable = "true"
  }

  # Ensure VM is deleted before firewall (dependency order)
  depends_on = [google_compute_firewall.allow_ssh_world]
}
