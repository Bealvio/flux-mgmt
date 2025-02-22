resource "vault_mount" "pki_root_ca" {
  path                      = "pki-root-ca"
  type                      = "pki"
  description               = "CA root"
  default_lease_ttl_seconds = 315360000
  max_lease_ttl_seconds     = 315360000
}

resource "vault_pki_secret_backend_root_cert" "root" {
  depends_on           = [vault_mount.pki_root_ca]
  backend              = vault_mount.pki_root_ca.path
  type                 = "internal"
  common_name          = "Root CA"
  ttl                  = "315360000"
  format               = "pem"
  private_key_format   = "der"
  key_type             = "rsa"
  key_bits             = 4096
  exclude_cn_from_sans = true
  organization         = "Bealv"
  country              = "France"
  locality             = "Bordeaux"
  province             = "Gironde"
}

resource "vault_kv_secret_v2" "pki_root_ca" {
  mount = vault_mount.secrets.path
  name  = "vault/pki_root_ca"
  data_json = jsonencode({
    certificate = vault_pki_secret_backend_root_cert.root.certificate
  })
}

resource "vault_mount" "int" {
  path                      = "pki-int"
  type                      = vault_mount.pki_root_ca.type
  description               = "CA int"
  default_lease_ttl_seconds = 63072000
  max_lease_ttl_seconds     = 63072000
}

resource "vault_pki_secret_backend_intermediate_cert_request" "int" {
  depends_on   = [vault_mount.int]
  backend      = vault_mount.int.path
  type         = vault_pki_secret_backend_root_cert.root.type
  common_name  = "Intermediate CA"
  organization = "Bealv"
  country      = "France"
  locality     = "Bordeaux"
  province     = "Gironde"
}

resource "vault_pki_secret_backend_root_sign_intermediate" "int" {
  depends_on           = [vault_pki_secret_backend_intermediate_cert_request.int]
  backend              = vault_mount.pki_root_ca.path
  csr                  = vault_pki_secret_backend_intermediate_cert_request.int.csr
  common_name          = "Intermediate CA"
  exclude_cn_from_sans = true
  organization         = "Bealv"
  country              = "France"
  locality             = "Bordeaux"
  province             = "Gironde"
  revoke               = true
}

resource "vault_pki_secret_backend_intermediate_set_signed" "int" {
  backend     = vault_mount.int.path
  certificate = vault_pki_secret_backend_root_sign_intermediate.int.certificate
}

resource "vault_pki_secret_backend_role" "bealv_mgmt_dot_lan" {
  backend          = vault_mount.int.path
  name             = "bealv-mgmt-dot-lan"
  ttl              = 2592000
  allow_ip_sans    = true
  key_type         = "rsa"
  key_bits         = 2048
  allowed_domains  = ["bealv-mgmt.lan"]
  allow_subdomains = true
  organization     = ["Bealv"]
  locality         = ["Bordeaux"]
  province         = ["Gironde"]
  country          = ["FR"]
  postal_code      = ["33000"]
  require_cn       = false
}

resource "vault_pki_secret_backend_crl_config" "int" {
  backend = vault_mount.int.path
  expiry  = "72h"
}
