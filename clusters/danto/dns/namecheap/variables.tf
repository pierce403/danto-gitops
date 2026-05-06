variable "domain" {
  description = "Base domain managed in Namecheap."
  type        = string
  default     = "x43.io"
}

variable "danto_ipv4" {
  description = "Public IPv4 address for the danto server."
  type        = string

  validation {
    condition     = can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}$", var.danto_ipv4))
    error_message = "danto_ipv4 must be an IPv4 address."
  }
}

variable "ttl" {
  description = "DNS record TTL in seconds."
  type        = number
  default     = 300
}

variable "service_hosts" {
  description = "Hostnames that should CNAME to danto."
  type        = set(string)
  default = [
    "argo",
    "auth",
    "cloud",
    "grafana",
    "mesh",
    "pad",
    "pad-sandbox",
    "snap",
  ]
}
