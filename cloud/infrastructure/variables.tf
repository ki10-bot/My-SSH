variable "yc_token" {
  description = "Yandex Cloud OAuth token (or use YC_TOKEN env var)"
  type        = string
  sensitive   = true
  default     = null
}

variable "yc_cloud_id" {
  description = "Yandex Cloud ID"
  type        = string
}

variable "yc_folder_id" {
  description = "Yandex Cloud Folder ID"
  type        = string
}

variable "yc_zone" {
  description = "Availability zone (ru-central1-a/b/d preferred; see docs for current status)"
  type        = string
  default     = "ru-central1-a"
  validation {
    condition     = contains(["ru-central1-a", "ru-central1-b", "ru-central1-d", "ru-central1-e", "kz1-a"], var.yc_zone)
    error_message = "Zone must be one of ru-central1-a/b/d/e or kz1-a (see docs for availability after 2026 incidents)."
  }
}

variable "project_name" {
  description = "Project prefix for resource names"
  type        = string
  default     = "remotegate"
}

variable "admin_username" {
  description = "Admin username on bastion VM"
  type        = string
  default     = "rgadmin"
}

variable "admin_ssh_key_path" {
  description = "Path to admin public SSH key (e.g. ~/.ssh/remotegate_mac.pub)"
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "vm_resources" {
  description = "VM sizing (cost-optimized)"
  type = object({
    cores         = number
    memory        = number # GB
    core_fraction = number # 5-100, 20 = burstable
    disk_size     = number # GB
    disk_type     = string
    preemptible   = bool
  })
  default = {
    cores         = 2
    memory        = 2
    core_fraction = 20
    disk_size     = 20
    disk_type     = "network-hdd"
    preemptible   = false # set true to halve cost, but VM may be interrupted
  }
}

variable "hmac_secret" {
  description = "HMAC secret for status endpoint (leave empty to skip status infra)"
  type        = string
  sensitive   = true
  default     = ""
  validation {
    condition     = var.hmac_secret == "" || length(var.hmac_secret) >= 16
    error_message = "HMAC secret must be at least 16 characters."
  }
}

variable "allowed_device_ids" {
  description = "Comma-separated device IDs for allowlist (empty = allow all authenticated)"
  type        = string
  default     = ""
}
