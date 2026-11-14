variable "bucket_name" { type = string, description = "Bucket for Cloud.ru-hosted Windows installer (globally unique). Use e.g. my-remotegate-bucket-uuid" }
variable "s3_endpoint" { type = string, default = "https://s3.cloud.ru", description = "S3 endpoint: Cloud.ru https://s3.cloud.ru or Yandex https://storage.yandexcloud.net" }
variable "s3_region" { type = string, default = "ru-moscow-1", description = "S3 region: ru-moscow-1 for Cloud.ru" }
variable "aws_access_key" { type = string, description = "S3 access key (Cloud.ru IAM)" }
variable "aws_secret_key" { type = string, description = "S3 secret key" }
variable "make_public" { type = bool, default = false, description = "If true, bucket ACL public-read (password would be public — not recommended)" }
