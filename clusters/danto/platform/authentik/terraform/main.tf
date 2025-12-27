provider "authentik" {
  # Uses AUTHENTIK_URL and AUTHENTIK_TOKEN env vars.
}

locals {
  argo_host = "https://argo.${var.domain}"
  mesh_host = "https://mesh.${var.domain}"
  mesh_oidc_issuer = "https://auth.${var.domain}/application/o/meshcentral-oidc/"
  mesh_oidc_redirect_uri = "https://mesh.${var.domain}/auth-oidc-callback"
  admin_policy_expression = var.admin_domain != "" ? "return request.user and (request.user.email == \\\"${var.admin_email}\\\" or request.user.email.endswith(\\\"@${var.admin_domain}\\\"))" : "return request.user and request.user.email == \\\"${var.admin_email}\\\""
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

data "authentik_flow" "default_source_authentication" {
  slug = "default-source-authentication"
}

data "authentik_flow" "default_source_enrollment" {
  slug = "default-source-enrollment"
}

data "authentik_user" "bootstrap_admin" {
  username = "akadmin"
}

resource "authentik_group" "admins" {
  name         = "admins"
  is_superuser = true
  users        = [data.authentik_user.bootstrap_admin.id]
}

resource "authentik_policy_expression" "admins_only" {
  name       = "admins-only"
  expression = local.admin_policy_expression
}

resource "authentik_source_oauth" "google" {
  name                = "Google"
  slug                = "google"
  provider_type       = "google"
  authentication_flow = data.authentik_flow.default_source_authentication.id
  enrollment_flow     = data.authentik_flow.default_source_enrollment.id
  consumer_key        = var.google_client_id
  consumer_secret     = var.google_client_secret
  user_matching_mode  = "email_link"
}

resource "authentik_stage_source" "google" {
  name   = "google-source"
  source = authentik_source_oauth.google.id
}

resource "authentik_flow_stage_binding" "google_default_auth" {
  target = data.authentik_flow.default_authentication.uuid
  stage  = authentik_stage_source.google.id
  order  = 0
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

resource "authentik_provider_oauth2" "mesh_oidc" {
  name               = "MeshCentral OIDC"
  client_id          = var.meshcentral_oidc_client_id
  client_secret      = var.meshcentral_oidc_client_secret
  authorization_flow = data.authentik_flow.default_authorization.id
  invalidation_flow  = data.authentik_flow.default_invalidation.id
  sub_mode           = "user_email"
  property_mappings  = [
    authentik_property_mapping_provider_scope.mesh_email.id,
    authentik_property_mapping_provider_scope.mesh_profile.id,
    authentik_property_mapping_provider_scope.mesh_groups.id,
  ]

  allowed_redirect_uris = [
    {
      matching_mode = "strict"
      url           = local.mesh_oidc_redirect_uri
    }
  ]
}

resource "authentik_property_mapping_provider_scope" "mesh_email" {
  name       = "meshcentral-email"
  scope_name = "email"
  expression = <<EOF
return {
  "email": request.user.email,
  "email_verified": True,
}
EOF
}

resource "authentik_property_mapping_provider_scope" "mesh_profile" {
  name       = "meshcentral-profile"
  scope_name = "profile"
  expression = <<EOF
return {
  "name": request.user.name,
  "preferred_username": request.user.username,
}
EOF
}

resource "authentik_property_mapping_provider_scope" "mesh_groups" {
  name       = "meshcentral-groups"
  scope_name = "groups"
  expression = <<EOF
return {
  "groups": [g.name for g in request.user.ak_groups.all()],
}
EOF
}

resource "authentik_application" "mesh_oidc" {
  name              = "MeshCentral OIDC"
  slug              = "meshcentral-oidc"
  protocol_provider = authentik_provider_oauth2.mesh_oidc.id
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

resource "authentik_policy_binding" "argo_admins" {
  target = authentik_application.argo.uuid
  policy = authentik_policy_expression.admins_only.id
  order  = 0
}

resource "authentik_policy_binding" "mesh_admins" {
  target = authentik_application.mesh.uuid
  policy = authentik_policy_expression.admins_only.id
  order  = 0
}

resource "authentik_policy_binding" "mesh_oidc_admins" {
  target = authentik_application.mesh_oidc.uuid
  policy = authentik_policy_expression.admins_only.id
  order  = 0
}
