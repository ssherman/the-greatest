terraform {
  required_providers {
    linode = {
      source = "linode/linode"
      version = "3.0.0"
    }
  }
}

provider "linode" {
  token = var.linode_token
}

resource "linode_instance" "thegreatest-web" {
    image = "linode/ubuntu24.04"
    label = var.instance_label
    region = var.instance_region
    type = var.instance_type
    authorized_keys = var.authorized_keys
    root_pass = var.root_password
    
    metadata {
        user_data = base64encode(
            templatefile("${path.module}/web-cloud-init.yaml", {
                primary_ssh_key = var.authorized_keys[0]
            })
        )
    }
}