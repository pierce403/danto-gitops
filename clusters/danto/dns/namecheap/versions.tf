terraform {
  required_version = ">= 1.5.0"

  required_providers {
    namecheap = {
      source  = "namecheap/namecheap"
      version = ">= 2.3.2"
    }
  }
}
