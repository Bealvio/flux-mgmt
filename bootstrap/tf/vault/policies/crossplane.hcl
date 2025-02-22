path "sys/auth" {
  capabilities = ["read", "list"]
}

path "sys/auth/*" {
  capabilities = ["create", "delete", "update", "sudo"]
  allowed_parameters = {
    "*"    = []
    "type" = ["kubernetes"]
  }
}

path "sys/policies/acl/*" {
  capabilities = ["create", "delete", "read", "update", "list"]
}

path "sys/policies/*" {
  capabilities = ["create", "delete", "read", "update", "list"]
}

path "auth/clusters/*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
  allowed_parameters = {
    "*" = []
  }
}

path "auth/clusters/+/config" {
  capabilities = ["create", "delete", "update", "read"]
}

path "auth/clusters/+/role/*" {
  capabilities = ["create"]
}

# Allow creating new tokens
path "auth/token/create" {
  capabilities = ["create", "update", "sudo"]
}

path "sys/mounts/auth/clusters/*" {
  capabilities = ["read", "list"]
}

path "pki-int/roles/*" {
  capabilities = ["create", "update", "delete", "read", "list"]
}

path "auth/token/*" {
  capabilities = ["update", "create", "read", "list", "delete"]
}

path "pki-int/sign/*" {
  capabilities = ["update", "create", "update"]
}

path "pki-int/issue/*" {
  capabilities = ["update", "create", "update"]
}
