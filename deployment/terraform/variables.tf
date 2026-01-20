variable "linode_token" {
  description = "Linode API token"
  type        = string
  sensitive   = true
}

variable "instance_label" {
  description = "Label for the Linode instance"
  type        = string
  default     = "thegreatest-web"
}

variable "instance_region" {
  description = "Region where the instance will be created"
  type        = string
  default     = "us-central"
}

variable "instance_type" {
  description = "Linode instance type"
  type        = string
  default     = "g6-standard-4"
}

variable "authorized_keys" {
  description = "List of SSH public keys for root access"
  type        = list(string)
}

variable "root_password" {
  description = "Root password for the instance"
  type        = string
  sensitive   = true
}

