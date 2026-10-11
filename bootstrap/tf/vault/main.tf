terraform {
  required_version = ">= 1.4.0"
  required_providers {
    vault = "~> 3.25.0"
  }
}

provider "vault" {
  address = "http://localhost:8200"
}
