# Terraform Deployment for Linode

This directory contains Terraform configuration for deploying The Greatest to a Linode instance.

## Prerequisites

- [Terraform](https://www.terraform.io/downloads) installed
- Linode API token
- SSH public key for server access

## Setup

1. Copy the example variables file:
   ```bash
   cp terraform.tfvars.example terraform.tfvars
   ```

2. Edit `terraform.tfvars` with your actual values (API token, SSH keys, root password)

3. Initialize Terraform (first time only):
   ```bash
   terraform init
   ```

## Deploying / Upgrading

To see what changes will be made:
```bash
terraform plan
```

To apply changes (deploy or upgrade):
```bash
terraform apply
```

This will prompt for confirmation before making changes. To skip the confirmation prompt:
```bash
terraform apply -auto-approve
```

> **Important**: After `terraform apply` creates a new server, additional steps are required (DNS, SSL certs, app deploy). See **[SERVER-UPGRADE-GUIDE.md](../SERVER-UPGRADE-GUIDE.md)** for the complete checklist.

## Configuration

Instance settings can be customized in `variables.tf`:

| Variable | Description | Default |
|----------|-------------|---------|
| `instance_label` | Name of the Linode instance | `thegreatest-web` |
| `instance_region` | Linode region | `us-central` |
| `instance_type` | Instance size/type | `g6-standard-4` |

## Common Operations

### Upgrade Instance Size
1. Edit `instance_type` in `variables.tf`
2. Run `terraform plan` to preview changes
3. Run `terraform apply` to apply

### View Current State
```bash
terraform show
```

### Destroy Infrastructure
```bash
terraform destroy
```

## Files

- `linode-web.tf` - Main Terraform configuration
- `variables.tf` - Variable definitions
- `terraform.tfvars` - Your local variable values (not committed)
- `terraform.tfvars.example` - Example variable values
- `web-cloud-init.yaml` - Cloud-init configuration for instance setup
