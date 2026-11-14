terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# Cloud.ru Evolution Object Storage is S3-compatible (endpoint https://s3.cloud.ru)
# Yandex Storage (https://storage.yandexcloud.net) also works — just change endpoint.
# Default: Cloud.ru Free Tier (15 GB free) — set via variables.

variable "bucket_name" {
  type        = string
  description = "Bucket for Cloud.ru-hosted Windows installer (globally unique). e.g. my-remotegate-bucket-uuid"
}

variable "s3_endpoint" {
  type        = string
  default     = "https://s3.cloud.ru"
  description = "S3 endpoint: Cloud.ru https://s3.cloud.ru (default) or Yandex https://storage.yandexcloud.net"
}

variable "s3_region" {
  type        = string
  default     = "ru-moscow-1"
  description = "S3 region: ru-moscow-1 for Cloud.ru, ru-central1 for Yandex"
}

variable "aws_access_key" {
  type        = string
  description = "S3 access key (Cloud.ru IAM or Yandex SA key)"
  sensitive   = true
}

variable "aws_secret_key" {
  type        = string
  description = "S3 secret key"
  sensitive   = true
}

variable "make_public" {
  type        = bool
  default     = false
  description = "If true, bucket ACL public-read (password in script would be public — not recommended)"
}

provider "aws" {
  region     = var.s3_region
  access_key = var.aws_access_key
  secret_key = var.aws_secret_key

  # Cloud.ru / Yandex are S3-compatible but not AWS — skip validation
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
  s3_use_path_style           = false
  endpoints {
    s3 = var.s3_endpoint
  }
}

resource "aws_s3_bucket" "remotegate_installer" {
  bucket = var.bucket_name
  # Bucket is private by default; use aws_s3_bucket_acl for explicit private/public
}

resource "aws_s3_bucket_acl" "remotegate_acl" {
  bucket = aws_s3_bucket.remotegate_installer.id
  acl    = var.make_public ? "public-read" : "private"
}

resource "aws_s3_bucket_versioning" "remotegate_versioning" {
  bucket = aws_s3_bucket.remotegate_installer.id
  versioning_configuration {
    status = "Disabled"
  }
}

output "bucket_name" {
  value = aws_s3_bucket.remotegate_installer.bucket
}

output "bucket_url" {
  description = "Cloud.ru bucket URL (private by default)"
  value       = var.s3_endpoint == "https://s3.cloud.ru" ? "https://${aws_s3_bucket.remotegate_installer.bucket}.s3.cloud.ru/RemoteGate-Final.ps1" : "https://storage.yandexcloud.net/${aws_s3_bucket.remotegate_installer.bucket}/RemoteGate-Final.ps1"
}

output "s3_endpoint" {
  value = var.s3_endpoint
}

output "next_steps" {
  value = <<-EOT
    1. Upload final installer:
       aws s3 cp dist/RemoteGate-Final.ps1 s3://${aws_s3_bucket.remotegate_installer.bucket}/RemoteGate-Final.ps1 --endpoint-url ${var.s3_endpoint}

    2. Windows install (if private, generate presigned):
       aws s3 presign s3://${aws_s3_bucket.remotegate_installer.bucket}/RemoteGate-Final.ps1 --endpoint-url ${var.s3_endpoint} --expires-in 604800

    3. Or wizard: .\generator\Upload-ToCloud.ps1 -FilePath dist/RemoteGate-Final.ps1 -Bucket ${aws_s3_bucket.remotegate_installer.bucket} -Endpoint ${var.s3_endpoint}
  EOT
}

# Legacy outputs for Yandex compatibility (if endpoint is Yandex)
output "service_account_id" {
  value       = "use aws_access_key for Cloud.ru / yandex_iam_service_account for Yandex"
  description = "Legacy: for Cloud.ru use aws keys; for Yandex see yandex_iam_service_account"
}
