variable "domain" {
  description = "Base domain for apps"
  type        = string
  default     = "x43.io"
}

variable "admin_email" {
  description = "Default admin email"
  type        = string
  default     = "pierce403@gmail.com"
}

variable "admin_domain" {
  description = "Optional admin domain (empty to disable)"
  type        = string
  default     = ""
}

variable "google_client_id" {
  description = "Google OAuth client ID"
  type        = string
  sensitive   = true
}

variable "google_client_secret" {
  description = "Google OAuth client secret"
  type        = string
  sensitive   = true
}

variable "meshcentral_oidc_client_id" {
  description = "MeshCentral OIDC client ID"
  type        = string
}

variable "meshcentral_oidc_client_secret" {
  description = "MeshCentral OIDC client secret"
  type        = string
  sensitive   = true
}
