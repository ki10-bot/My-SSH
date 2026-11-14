# RemoteGate — Terraform Infrastructure

## What it creates

- VPC network + subnet (10.10.0.0/24) in chosen zone
- Security group (SSH 22 inbound, all egress)
- Bastion VM (Ubuntu 22.04, `GatewayPorts no`, `tunneluser` restricted)
- Optional: Cloud Function + API Gateway for `/status` + `/health` (only if `hmac_secret` set)

## Usage

```bash
cd cloud/infrastructure
cp terraform.tfvars.example terraform.tfvars
nano terraform.tfvars  # fill in yc_cloud_id, folder_id, keys, secret

export YC_TOKEN=$(yc iam create-token)  # or pass via var
terraform init
terraform plan
terraform apply
terraform output bastion_public_ip
```

## Variables

See `variables.tf` and `terraform.tfvars.example`.

Key decisions:
- `yc_zone`: Default `ru-central1-a`. See `docs/YANDEX-CLOUD-SETUP.md` for availability after Oct 2026 incidents.
- `preemptible`: `true` halves cost but VM can be stopped by Yandex; tunnel will reconnect on restart.
- `hmac_secret`: If empty, function/gateway are not created (SSH-only deploy, cheaper).
- `core_fraction`: 20 = burstable (cheap), 100 = guaranteed.

## Cost

- VM 2 vCPU/2GB/20GB HDD, 20% core: ~ $5–12/mo (non-preemptible) in ru-central1.
- Preemptible: ~50–70% less.
- Cloud Function: first 100k invocations free tier (check current pricing).
- API Gateway: free tier generous, then per-request.
- Lock in budget: Set Yandex Cloud billing budget alert.

## After apply

See `yandex_compute_instance.bastion` outputs and `cloud/vm/README.md` for post-setup.

## Cleanup

```bash
terraform destroy
# Also delete any manually added Objects in bucket if you enabled storage logging
```

## Without Terraform

Follow `docs/YANDEX-CLOUD-SETUP.md` manual console steps.
