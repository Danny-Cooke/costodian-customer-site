output "identity_arn" {
  description = "The domain's sending identity, for whatever is told to send as it."
  value       = aws_sesv2_email_identity.domain.arn
}

output "bucket_name" {
  description = "Where received mail is kept."
  value       = aws_s3_bucket.mail.bucket
}

output "topic_arn" {
  description = "The topic received mail is passed to."
  value       = aws_sns_topic.received.arn
}
