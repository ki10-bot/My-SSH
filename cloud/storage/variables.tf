variable "yc_cloud_id" { type = string, description = "Yandex Cloud ID" }
variable "yc_folder_id" { type = string, description = "Folder ID" }
variable "yc_zone" { type = string, default = "ru-central1-a" }
variable "bucket_name" { type = string, description = "Bucket for Yandex-hosted Windows installer (must be globally unique). Use e.g. my-remotegate-bucket-uuid" }
variable "make_public" { type = bool, default = false, description = "If true, bucket ACL public-read (password in script would be public via URL — not recommended)" }
