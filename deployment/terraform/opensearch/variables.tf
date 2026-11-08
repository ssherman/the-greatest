variable "linode_token" {
  description = "Linode API token"
  type        = string
  sensitive   = true
}

variable "instance_label" {
  description = "Label for the Linode instance"
  type        = string
  default     = "thegreatest-search"
}

variable "instance_region" {
  description = "Region; keep it the same as the app servers"
  type        = string
  default     = "us-central"
}

variable "instance_type" {
  description = "Linode plan. g6-standard-4 is Linode 8 GB (4 cores, 160 GB), the old server's size"
  type        = string
  default     = "g6-standard-4"
}

variable "authorized_keys" {
  description = "SSH public keys; the first also becomes the deploy user's key"
  type        = list(string)
}

variable "root_password" {
  description = "Root password (root SSH login is disabled by cloud-init)"
  type        = string
  sensitive   = true
}
