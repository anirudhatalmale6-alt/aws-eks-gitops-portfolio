# tflint configuration
#
# The bundled terraform ruleset catches style and dead-code problems. The AWS
# ruleset is the one that matters: it validates instance types, IAM policy
# shapes and required arguments against the real AWS API surface, so a typo like
# t3.larg is caught in CI instead of at apply time.

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "aws" {
  enabled = true
  version = "0.44.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

config {
  call_module_type = "all"
}

rule "terraform_required_version" {
  enabled = true
}

rule "terraform_required_providers" {
  enabled = true
}

# Every variable and output in this repo is documented, and CI enforces it.
rule "terraform_documented_variables" {
  enabled = true
}

rule "terraform_documented_outputs" {
  enabled = true
}

rule "terraform_naming_convention" {
  enabled = true
  format  = "snake_case"
}
