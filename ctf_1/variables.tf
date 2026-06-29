variable "region" {
  type    = string
  default = "us-east-1"
}

variable "external_ip" {
  type        = string
  description = "Your public IPv4 address only, no /32. Example: 203.0.113.10"
}

variable "cluster_name" {
  type    = string
  default = "snowflakes-k8s-ctf"
}