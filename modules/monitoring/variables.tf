variable "env" {
  description = "Environment slug (e.g. dev, prod)."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "retention_in_days" {
  description = "Log Analytics retention. 30 is the free-tier minimum; raise for longer history."
  type        = number
  default     = 30
}

variable "tags" {
  description = "Tags applied to monitoring resources."
  type        = map(string)
  default     = {}
}