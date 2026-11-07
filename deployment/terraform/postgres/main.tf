# The database server. Its own root module and state, so an apply here can never touch the web server or the search server.
# Spec: docs/superpowers/specs/2026-11-06-postgres-server-design.md. Runbook: docs/features/postgres-server.md.
terraform {
  required_providers {
    linode = {
      source  = "linode/linode"
      version = "3.0.0"
    }
  }
}

provider "linode" {
  token = var.linode_token
}

resource "linode_instance" "postgres" {
  image           = "linode/ubuntu26.04"
  label           = var.instance_label
  region          = var.instance_region
  type            = var.instance_type
  authorized_keys = var.authorized_keys
  root_pass       = var.root_password

  metadata {
    user_data = base64encode(
      templatefile("${path.module}/cloud-init.yaml", {
        primary_ssh_key = var.authorized_keys[0]
      })
    )
  }
}

output "ipv4" {
  value = linode_instance.postgres.ip_address
}

output "ipv6" {
  value = linode_instance.postgres.ipv6
}
