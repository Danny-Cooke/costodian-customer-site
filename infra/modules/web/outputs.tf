output "bucket_name" {
  description = "Bucket the pipeline syncs the built site into."
  value       = aws_s3_bucket.web.bucket
}

output "distribution_id" {
  description = "Distribution to invalidate after a sync."
  value       = aws_cloudfront_distribution.this.id
}

output "distribution_domain_name" {
  description = "The CloudFront domain the site is served on."
  value       = aws_cloudfront_distribution.this.domain_name
}

output "site_url" {
  description = "Where the site is: its own name when it has one, the CloudFront domain when it does not."
  value       = "https://${var.domain == null ? aws_cloudfront_distribution.this.domain_name : var.domain.name}"
}

output "web_acl_arn" {
  description = "The WAF web ACL in front of the distribution."
  value       = aws_wafv2_web_acl.this.arn
}

output "names" {
  description = "The composed names of this component's resources, for policies that must name them."
  value       = module.naming.names
}
