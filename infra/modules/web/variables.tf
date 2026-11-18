variable "platform" {
  description = "The platform object: the slots and values every module shares."
  type = object({
    prefix        = string
    project       = string
    environment   = string
    postfix       = string
    region        = string
    edge_region   = string
    account_id    = string
    partition     = string
    unique_suffix = string
    tags          = map(string)
  })
}

variable "component" {
  description = "The bounded context for these names."
  type        = string
}

variable "index_document" {
  description = "The file served for a page path, and for the root."
  type        = string
}

variable "not_found_document" {
  description = "Path of the page served when an object does not exist."
  type        = string
}

variable "not_found_error_codes" {
  description = "Origin error codes answered with the not-found page."
  type        = list(number)
}

variable "not_found_response_code" {
  description = "Status code returned with the not-found page."
  type        = number
}

variable "error_caching_min_ttl_seconds" {
  description = "How long CloudFront remembers an error before asking the origin again."
  type        = number
  default     = 60
}

variable "function_runtime" {
  description = "Runtime of the viewer-request function."
  type        = string
  default     = "cloudfront-js-2.0"
}

variable "price_class" {
  description = "CloudFront price class."
  type        = string
}

variable "cache_policy_name" {
  description = "Name of the AWS managed cache policy for the default behaviour."
  type        = string
}

variable "allowed_methods" {
  description = "Methods CloudFront forwards."
  type        = list(string)
}

variable "cached_methods" {
  description = "Methods CloudFront caches."
  type        = list(string)
}

variable "api_origin" {
  description = "A second origin for the sign-up API, so the browser calls it on the site's own origin. Null leaves the distribution static-only."
  type = object({
    domain_name  = string
    path_pattern = string
  })
  default = null
}

variable "api_origin_http_port" {
  description = "Port CloudFront would use for plain HTTP to the API. Unused while the protocol policy is https-only, and required by the provider."
  type        = number
  default     = 80
}

variable "api_origin_https_port" {
  description = "Port CloudFront uses to the API."
  type        = number
  default     = 443
}

variable "api_origin_protocol_policy" {
  description = "How CloudFront talks to the API origin."
  type        = string
  default     = "https-only"
}

variable "api_origin_ssl_protocols" {
  description = "TLS versions CloudFront offers the API origin."
  type        = list(string)
  default     = ["TLSv1.2"]
}

variable "api_allowed_methods" {
  description = "Methods CloudFront forwards to the API. All of them: the API decides what a route accepts."
  type        = list(string)
  default     = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
}

variable "api_cached_methods" {
  description = "Methods CloudFront caches on the API behaviour. Caching is off, so this is the provider's minimum."
  type        = list(string)
  default     = ["GET", "HEAD"]
}

variable "api_viewer_protocol_policy" {
  description = "What CloudFront does with a plain HTTP request for an API path."
  type        = string
  default     = "redirect-to-https"
}

variable "api_cache_policy_name" {
  description = "Name of the AWS managed cache policy for the API behaviour. An API answer is never cached."
  type        = string
  default     = "Managed-CachingDisabled"
}

variable "api_origin_request_policy_name" {
  description = "Name of the AWS managed origin request policy for the API behaviour. It forwards everything the viewer sent, including the Authorization header, but not the Host header, which must stay the API's own."
  type        = string
  default     = "Managed-AllViewerExceptHostHeader"
}

variable "geo_restriction_type" {
  description = "none, whitelist or blacklist."
  type        = string
  default     = "none"
}

variable "geo_restriction_locations" {
  description = "Country codes for the restriction, empty when the type is none."
  type        = list(string)
  default     = []
}

variable "noncurrent_version_expiration_days" {
  description = "Days an overwritten version of a site file is kept."
  type        = number
  default     = 30
}

variable "abort_incomplete_upload_days" {
  description = "Days after which an unfinished multipart upload is removed."
  type        = number
  default     = 1
}

variable "content_security_policy" {
  description = "The Content-Security-Policy header. The site has no inline code, so it can forbid it."
  type        = string
}

variable "permissions_policy" {
  description = "The Permissions-Policy header."
  type        = string
}

variable "frame_option" {
  description = "X-Frame-Options: DENY or SAMEORIGIN."
  type        = string
  default     = "DENY"
}

variable "referrer_policy" {
  description = "The Referrer-Policy header."
  type        = string
  default     = "strict-origin-when-cross-origin"
}

variable "hsts_max_age_seconds" {
  description = "Strict-Transport-Security max-age."
  type        = number
  default     = 31536000
}

variable "hsts_include_subdomains" {
  description = "Whether Strict-Transport-Security covers subdomains."
  type        = bool
  default     = true
}

variable "hsts_preload" {
  description = "Whether Strict-Transport-Security asks for preloading."
  type        = bool
  default     = false
}

variable "waf_managed_rule_groups" {
  description = "AWS managed rule groups to apply, with their priorities."
  type = list(object({
    name     = string
    priority = number
  }))
}

variable "waf_managed_rule_vendor" {
  description = "Vendor name for the managed rule groups."
  type        = string
  default     = "AWS"
}

variable "waf_rate_limit" {
  description = "Requests per five minutes from one IP before the rate rule blocks it."
  type        = number
}

variable "waf_rate_rule_priority" {
  description = "Priority of the rate rule relative to the managed groups."
  type        = number
}

variable "waf_sampled_requests_enabled" {
  description = "Whether WAF keeps sampled requests. Samples include request metadata, so this is off unless it is needed for an investigation."
  type        = bool
  default     = false
}
