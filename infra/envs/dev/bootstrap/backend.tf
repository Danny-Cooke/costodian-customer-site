# Partial backend configuration. A backend block cannot read variables, so the
# bucket, key and Region are supplied at init:
#
#   terraform init \
#     -backend-config="bucket=$TF_STATE_BUCKET" \
#     -backend-config="key=$TF_STATE_KEY" \
#     -backend-config="region=$AWS_REGION"
terraform {
  backend "s3" {
    encrypt      = true
    use_lockfile = true
  }
}
