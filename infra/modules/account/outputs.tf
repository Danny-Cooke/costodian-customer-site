output "user_pool_id" {
  description = "The pool the browser signs in against."
  value       = aws_cognito_user_pool.this.id
}

output "user_pool_client_id" {
  description = "The app client the browser uses. Not a secret: the client has none."
  value       = aws_cognito_user_pool_client.this.id
}

output "user_pool_issuer" {
  description = "The issuer the API checks a token against."
  value       = "https://${aws_cognito_user_pool.this.endpoint}"
}

output "api_domain_name" {
  description = "Host of the HTTP API, for CloudFront to use as an origin."
  value       = trimprefix(aws_apigatewayv2_api.this.api_endpoint, "https://")
}

output "api_endpoint" {
  description = "The API's own address. The browser does not use it; it goes through CloudFront."
  value       = aws_apigatewayv2_api.this.api_endpoint
}

output "table_name" {
  description = "The registry of customer UIDs: one entry for every UID ever issued, so that none is issued twice. It holds no customer data."
  value       = aws_dynamodb_table.this.name
}

output "customer_parameter_path" {
  description = "The SSM path holding one label per customer number, one level deep."
  value       = var.customer_parameter_path
}

output "versions_parameter_name" {
  description = "The SSM parameter holding the product's version catalogue as a JSON list."
  value       = aws_ssm_parameter.versions.name
}

output "customer_table_name_template" {
  description = "A customer's table name with the customer number's placeholder where the number goes."
  value       = local.customer_table_name_template
}

output "customer_table_arn_template" {
  description = "A customer's table ARN with the customer number's placeholder where the number goes. What a session policy names."
  value       = local.customer_table_arn_template
}

output "customer_key_alias_template" {
  description = "A customer's key alias with the customer number's placeholder where the number goes, in the form the kms:ResourceAliases condition takes."
  value       = local.customer_key_alias_template
}

output "customer_numbers" {
  description = "Every customer number in the pool, claimed and free, lowest first."
  value       = local.customer_numbers
}

output "customer_free_status" {
  description = "The status word in a label that means nobody has taken that number."
  value       = var.customer_free_status
}

output "customer_attribute" {
  description = "The token claim holding a person's customer number."
  value       = local.customer_attribute
}

output "customer_data_role_arn" {
  description = "The role a function assumes, with a session policy for one customer, to reach that customer's table."
  value       = aws_iam_role.customer_data.arn
}

output "key_arn" {
  description = "The key the table and the log groups are encrypted with."
  value       = aws_kms_key.this.arn
}

output "function_names" {
  description = "Logical name to deployed function name, for smoke tests and log lookups."
  value       = { for name, fn in aws_lambda_function.this : name => fn.function_name }
}

output "names" {
  description = "The composed names of this component's resources, for policies that must name them."
  value       = module.naming.names
}
