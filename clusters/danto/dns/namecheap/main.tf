provider "namecheap" {
  # Reads NAMECHEAP_USER_NAME, NAMECHEAP_API_USER, NAMECHEAP_API_KEY,
  # NAMECHEAP_CLIENT_IP, and NAMECHEAP_USE_SANDBOX from the environment.
}

locals {
  danto_fqdn = "danto.${var.domain}."
}

resource "namecheap_domain_records" "danto" {
  domain = var.domain
  mode   = "MERGE"

  record {
    hostname = "danto"
    type     = "A"
    address  = var.danto_ipv4
    ttl      = var.ttl
  }

  dynamic "record" {
    for_each = var.service_hosts

    content {
      hostname = record.value
      type     = "CNAME"
      address  = local.danto_fqdn
      ttl      = var.ttl
    }
  }
}
