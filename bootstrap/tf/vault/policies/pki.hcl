# List enabled secrets engine
path "sys/mounts" {
  capabilities = ["read", "list"]
}
path "pki*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
