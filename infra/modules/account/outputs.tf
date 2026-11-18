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
  description = "The table holding the account record."
  value       = aws_dynamodb_table.this.name
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
