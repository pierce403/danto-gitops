terraform {
  required_version = ">= 1.5.0"

  required_providers {
    authentik = {
      source  = "goauthentik/authentik"
      version = ">= 2023.10.0"
    }
  }

  backend "kubernetes" {
    namespace     = "authentik"
    secret_suffix = "authentik-terraform"
  }
}
