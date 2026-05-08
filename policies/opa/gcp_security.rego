# ============================================================
# OPA / Regula Policy — GCP Security Rules
# These Rego policies block Terraform apply when violations
# are found during the CI/CD plan evaluation stage.
# ============================================================

package rules.gcp_security

import future.keywords.if
import future.keywords.in

# ── RULE 1: Block firewall rules that allow 0.0.0.0/0 ────────
#
# Checks both IPv4 (0.0.0.0/0) and IPv6 (::/0) open ranges
# on any protocol or sensitive ports.

deny[msg] {
  resource := input.planned_values.root_module.resources[_]
  resource.type == "google_compute_firewall"

  source_range := resource.values.source_ranges[_]
  open_range(source_range)

  msg := sprintf(
    "POLICY VIOLATION [CRITICAL]: Firewall rule '%s' allows unrestricted ingress from '%s'. Restrict to known IP ranges.",
    [resource.name, source_range]
  )
}

# ── RULE 2: Block firewall rules exposing SSH (22) to world ──
deny[msg] {
  resource := input.planned_values.root_module.resources[_]
  resource.type == "google_compute_firewall"

  source_range := resource.values.source_ranges[_]
  open_range(source_range)

  allow_block := resource.values.allow[_]
  port := allow_block.ports[_]
  sensitive_port(port)

  msg := sprintf(
    "POLICY VIOLATION [CRITICAL]: Firewall '%s' exposes port '%s' to '%s'. SSH/RDP must never be open to 0.0.0.0/0.",
    [resource.name, port, source_range]
  )
}

# ── RULE 3: GCS Bucket must enable uniform bucket-level access ─
deny[msg] {
  resource := input.planned_values.root_module.resources[_]
  resource.type == "google_storage_bucket"

  not resource.values.uniform_bucket_level_access == true

  msg := sprintf(
    "POLICY VIOLATION [HIGH]: GCS bucket '%s' does not have uniform_bucket_level_access enabled. Enable it to prevent ACL-based misconfigurations.",
    [resource.name]
  )
}

# ── RULE 4: GCS Bucket must enable versioning ────────────────
deny[msg] {
  resource := input.planned_values.root_module.resources[_]
  resource.type == "google_storage_bucket"

  not bucket_has_versioning(resource)

  msg := sprintf(
    "POLICY VIOLATION [MEDIUM]: GCS bucket '%s' does not have versioning enabled. Enable versioning for data recovery.",
    [resource.name]
  )
}

# ── RULE 5: GCE VM must enable Shielded VM ───────────────────
deny[msg] {
  resource := input.planned_values.root_module.resources[_]
  resource.type == "google_compute_instance"

  not shielded_vm_enabled(resource)

  msg := sprintf(
    "POLICY VIOLATION [HIGH]: GCE instance '%s' does not have Shielded VM enabled. Enable secure_boot, vtpm, and integrity_monitoring.",
    [resource.name]
  )
}

# ── RULE 6: GCE VM must not use default service account with full scope ──
deny[msg] {
  resource := input.planned_values.root_module.resources[_]
  resource.type == "google_compute_instance"

  sa := resource.values.service_account[_]
  sa.scopes[_] == "https://www.googleapis.com/auth/cloud-platform"
  not sa.email

  msg := sprintf(
    "POLICY VIOLATION [HIGH]: GCE instance '%s' uses the default compute service account with full cloud-platform scope. Use a dedicated SA with minimal permissions.",
    [resource.name]
  )
}

# ── WARN: Resources missing required labels ───────────────────
# Warn (non-blocking) for missing labels — use deny[] to make it blocking
warn[msg] {
  resource := input.planned_values.root_module.resources[_]
  resource.type in ["google_compute_instance", "google_storage_bucket", "google_compute_firewall"]

  required_label := required_labels[_]
  not resource.values.labels[required_label]

  msg := sprintf(
    "POLICY WARNING [LOW]: Resource '%s' (%s) is missing required label '%s'.",
    [resource.name, resource.type, required_label]
  )
}

# ── Helper Functions ──────────────────────────────────────────

open_range(range) if range == "0.0.0.0/0"
open_range(range) if range == "::/0"

sensitive_port(port) if port == "22"
sensitive_port(port) if port == "3389"
sensitive_port(port) if port == "3306"
sensitive_port(port) if port == "5432"

bucket_has_versioning(resource) if {
  versioning := resource.values.versioning[_]
  versioning.enabled == true
}

shielded_vm_enabled(resource) if {
  config := resource.values.shielded_instance_config[_]
  config.enable_secure_boot == true
  config.enable_vtpm == true
  config.enable_integrity_monitoring == true
}

required_labels := ["environment", "owner"]
