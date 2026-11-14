terraform {
  required_version = ">= 1.5"
  required_providers {
    yandex = {
      source  = "yandex-cloud/yandex"
      version = "~> 0.110"
    }
  }
}

provider "yandex" {
  # Auth via env var YC_TOKEN or var.yc_token
  token     = var.yc_token
  cloud_id  = var.yc_cloud_id
  folder_id = var.yc_folder_id
  zone      = var.yc_zone
}

# ── Network ──────────────────────────────────────────────────────────────
resource "yandex_vpc_network" "remotegate" {
  name        = "${var.project_name}-net"
  description = "RemoteGate bastion network"
}

resource "yandex_vpc_subnet" "remotegate" {
  name           = "${var.project_name}-subnet-${var.yc_zone}"
  zone           = var.yc_zone
  network_id     = yandex_vpc_network.remotegate.id
  v4_cidr_blocks = ["10.10.0.0/24"]
}

# Security group: only SSH from Internet (bastion); internal is default allow within subnet
resource "yandex_vpc_security_group" "bastion" {
  name        = "${var.project_name}-sg-bastion"
  network_id  = yandex_vpc_network.remotegate.id
  description = "Bastion: allow SSH inbound, deny tunnel port publicly"

  ingress {
    description    = "SSH from Internet (restrict to your IP in production!)"
    protocol       = "TCP"
    port           = 22
    v4_cidr_blocks = ["0.0.0.0/0"] # TODO: restrict to your Mac's IP: ["YOUR_IP/32"]
  }

  egress {
    description    = "Allow all outbound (for updates, etc.)"
    protocol       = "ANY"
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  # Explicitly do NOT open port 2222 publicly — it's loopback only via GatewayPorts no
}

# ── Service Account for Function ───────────────────────────────────────
resource "yandex_iam_service_account" "function_sa" {
  count       = var.hmac_secret != "" ? 1 : 0
  name        = "${var.project_name}-func-sa"
  description = "RemoteGate status function service account"
}

resource "yandex_resourcemanager_folder_iam_member" "function_sa_logging" {
  count     = var.hmac_secret != "" ? 1 : 0
  folder_id = var.yc_folder_id
  role      = "logging.writer"
  member    = "serviceAccount:${yandex_iam_service_account.function_sa[0].id}"
}

# ── Bastion VM ──────────────────────────────────────────────────────────
data "yandex_compute_image" "ubuntu" {
  family = "ubuntu-2204-lts"
}

resource "yandex_compute_instance" "bastion" {
  name        = "${var.project_name}-bastion"
  hostname    = "${var.project_name}-bastion"
  zone        = var.yc_zone
  description = "RemoteGate SSH bastion (GatewayPorts no, tunnel user restricted)"

  resources {
    cores         = var.vm_resources.cores
    memory        = var.vm_resources.memory
    core_fraction = var.vm_resources.core_fraction
  }

  boot_disk {
    initialize_params {
      image_id = data.yandex_compute_image.ubuntu.id
      size     = var.vm_resources.disk_size
      type     = var.vm_resources.disk_type
    }
  }

  network_interface {
    subnet_id = yandex_vpc_subnet.remotegate.id
    nat       = true # public IP for bastion
    security_group_ids = [yandex_vpc_security_group.bastion.id]
  }

  scheduling_policy {
    preemptible = var.vm_resources.preemptible
  }

  metadata = {
    # Yandex injects SSH key via metadata
    ssh-keys = "${var.admin_username}:${file(pathexpand(var.admin_ssh_key_path))}"
    # cloud-init via user-data (optional)
    user-data = file("${path.module}/../vm/cloud-init.yaml")
  }

  allow_stopping_for_update = true

  lifecycle {
    ignore_changes = [metadata["user-data"]] # allow manual key rotation
  }
}

# ── Cloud Function (status endpoint) ───────────────────────────────────
resource "yandex_function" "status" {
  count              = var.hmac_secret != "" ? 1 : 0
  name               = "${var.project_name}-status"
  description        = "RemoteGate authenticated status endpoint"
  user_hash          = sha256(filesha256("${path.module}/../functions/index.js"))
  runtime            = "nodejs20"
  entrypoint         = "index.handler"
  memory             = 128
  execution_timeout  = "10"
  service_account_id = yandex_iam_service_account.function_sa[0].id

  content {
    zip_filename = data.archive_file.function_zip[0].output_path
  }

  environment = {
    HMAC_SECRET        = var.hmac_secret
    ALLOWED_DEVICE_IDS = var.allowed_device_ids
  }
}

data "archive_file" "function_zip" {
  count       = var.hmac_secret != "" ? 1 : 0
  type        = "zip"
  source_file = "${path.module}/../functions/index.js"
  output_path = "${path.module}/.build/function.zip"
}

# ── API Gateway ────────────────────────────────────────────────────────
resource "yandex_api_gateway" "remotegate" {
  count       = var.hmac_secret != "" ? 1 : 0
  name        = "${var.project_name}-gateway"
  description = "RemoteGate status API gateway"

  spec = templatefile("${path.module}/../gateway/spec.yaml", {
    # We use raw spec file with placeholders; terraform replaces function_id via yq/sed in spec
    # Simpler: use local replacement
  })

  # Because templatefile vars would need spec to use ${}, we instead use a local rendered spec
  # See locals block below
}

locals {
  # Render gateway spec with real IDs (if function exists)
  gateway_spec_rendered = var.hmac_secret != "" ? replace(
    replace(
      file("${path.module}/../gateway/spec.yaml"),
      "REPLACE_WITH_FUNCTION_ID", yandex_function.status[0].id
    ),
    "REPLACE_WITH_SERVICE_ACCOUNT_ID", yandex_iam_service_account.function_sa[0].id
  ) : ""
}

# Override spec via separate resource if Terraform Yandex provider supports spec update
# Alternative: use null_resource with yc CLI for gateway (documented as fallback)

# ── Outputs ────────────────────────────────────────────────────────────
output "bastion_public_ip" {
  description = "Bastion public IP (use for tunnel config and ProxyJump)"
  value       = yandex_compute_instance.bastion.network_interface[0].nat_ip_address
}

output "bastion_fqdn" {
  description = "Bastion FQDN (if assigned)"
  value       = yandex_compute_instance.bastion.fqdn
}

output "network_id" {
  value = yandex_vpc_network.remotegate.id
}

output "security_group_id" {
  value = yandex_vpc_security_group.bastion.id
}

output "function_id" {
  description = "Cloud Function ID (for gateway spec replacement)"
  value       = var.hmac_secret != "" ? yandex_function.status[0].id : null
}

output "function_invoke_url" {
  description = "Direct function URL (if gateway not used)"
  value       = var.hmac_secret != "" ? "https://functions.yandexcloud.net/${yandex_function.status[0].id}" : null
}

output "gateway_domain" {
  description = "API Gateway domain (status endpoint = https://<domain>/status)"
  value       = var.hmac_secret != "" ? yandex_api_gateway.remotegate[0].domain : null
}

output "next_steps" {
  description = "Manual steps after apply"
  value = <<-EOT
    1. Get bastion IP: terraform output bastion_public_ip
    2. Add Windows tunnel key to bastion:
       ssh ${var.admin_username}@<BASTION_IP>
       sudo -u tunneluser bash -c "echo 'ssh-ed25519 AAAA... remotegate' >> ~/.ssh/authorized_keys"
    3. If you used placeholder spec, update API Gateway:
       yc serverless api-gateway update --id $(terraform output -raw gateway_domain) --spec=cloud/gateway/spec.yaml
    4. Test status: curl -X POST https://<GATEWAY_DOMAIN>/status -H "X-RemoteGate-..." (or use DryRun)
  EOT
}
