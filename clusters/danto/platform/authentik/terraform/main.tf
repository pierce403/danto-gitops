provider "authentik" {
  # Uses AUTHENTIK_URL and AUTHENTIK_TOKEN env vars.
}

locals {
  argo_host = "https://argo.${var.domain}"
  mesh_host = "https://mesh.${var.domain}"
}

data "authentik_outpost" "embedded" {
  name = "authentik Embedded Outpost"
}

data "authentik_flow" "default_authentication" {
  slug = "default-authentication-flow"
}

data "authentik_flow" "default_authorization" {
  slug = "default-provider-authorization-implicit-consent"
}

data "authentik_flow" "default_invalidation" {
  slug = "default-provider-invalidation-flow"
}

resource "authentik_provider_proxy" "argo" {
  name                = "Argo CD"
  external_host       = local.argo_host
  mode                = "forward_single"
  authentication_flow = data.authentik_flow.default_authentication.id
  authorization_flow  = data.authentik_flow.default_authorization.id
  invalidation_flow   = data.authentik_flow.default_invalidation.id
  cookie_domain       = ".${var.domain}"
}

resource "authentik_application" "argo" {
  name              = "Argo CD"
  slug              = "argo"
  protocol_provider = authentik_provider_proxy.argo.id
  meta_launch_url   = local.argo_host
  open_in_new_tab   = true
}

resource "authentik_provider_proxy" "mesh" {
  name                = "MeshCentral"
  external_host       = local.mesh_host
  mode                = "forward_single"
  authentication_flow = data.authentik_flow.default_authentication.id
  authorization_flow  = data.authentik_flow.default_authorization.id
  invalidation_flow   = data.authentik_flow.default_invalidation.id
  cookie_domain       = ".${var.domain}"
}

resource "authentik_application" "mesh" {
  name              = "MeshCentral"
  slug              = "meshcentral"
  protocol_provider = authentik_provider_proxy.mesh.id
  meta_launch_url   = local.mesh_host
  open_in_new_tab   = true
}

resource "authentik_outpost_provider_attachment" "embedded_argo" {
  outpost           = data.authentik_outpost.embedded.id
  protocol_provider = authentik_provider_proxy.argo.id
}

resource "authentik_outpost_provider_attachment" "embedded_mesh" {
  outpost           = data.authentik_outpost.embedded.id
  protocol_provider = authentik_provider_proxy.mesh.id
}
