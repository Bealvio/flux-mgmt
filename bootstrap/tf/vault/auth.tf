resource "vault_auth_backend" "kubernetes" {
  type        = "kubernetes"
  description = "Kubernetes Auth MGMT Backend"
}

resource "vault_kubernetes_auth_backend_config" "kubernetes" {
  backend                = vault_auth_backend.kubernetes.path
  disable_iss_validation = "true"
  kubernetes_host        = "https://10.250.0.9:6443"
}

resource "vault_kubernetes_auth_backend_role" "external-secrets" {
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "external-secrets"
  bound_service_account_names      = ["vault-auth"]
  bound_service_account_namespaces = ["external-secrets"]
  token_policies                   = ["external-secrets"]
}

resource "vault_auth_backend" "approle" {
  description = "Approle auth backend dedicated to applications"
  path        = "approle"
  type        = "approle"
}

resource "vault_approle_auth_backend_role" "crossplane" {
  backend        = vault_auth_backend.approle.path
  role_name      = "crossplane"
  secret_id_ttl  = "0"
  token_num_uses = "0"
  token_ttl      = "1200"
  token_max_ttl  = "1200"
  token_policies = ["crossplane"]
}

resource "vault_approle_auth_backend_role_secret_id" "crossplane" {
  backend   = vault_auth_backend.approle.path
  role_name = vault_approle_auth_backend_role.crossplane.role_name
}

resource "vault_kv_secret_v2" "crossplane" {
  mount     = vault_mount.secrets.path
  name      = "vault/crossplane"
  data_json = <<JSON
    {
      "secret-id": "${vault_approle_auth_backend_role_secret_id.crossplane.secret_id}",
      "role-id": "${vault_approle_auth_backend_role.crossplane.role_id}"
    }
  JSON
}

resource "vault_token" "cert-manager" {
  policies = ["cert-manager"]
  ttl      = "0"
}

resource "vault_kv_secret_v2" "cert_manager_secret" {
  mount = vault_mount.secrets.path
  name  = "vault/cert-manager"

  data_json = jsonencode({
    "token" = vault_token.cert-manager.client_token
  })
}
