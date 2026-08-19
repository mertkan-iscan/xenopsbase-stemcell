# tflint catches what `terraform validate` cannot: unused declarations, missing
# descriptions, provider-specific misuse. Run over each root module.

config {
  call_module_type = "local"
  force            = false
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

rule "terraform_naming_convention" {
  enabled = true
  format  = "snake_case"
}

# Every variable and output must say what it is for. This repository is a
# template other projects are forked from, so an undocumented variable is
# inherited confusion rather than a local shortcut.
rule "terraform_documented_variables" {
  enabled = true
}

rule "terraform_documented_outputs" {
  enabled = true
}

rule "terraform_typed_variables" {
  enabled = true
}

# Deliberately off. It requires a version constraint on every provider, but the
# kube-hetzner module declares its own providers and this rule fires on those
# rather than on ours.
rule "terraform_required_providers" {
  enabled = false
}
