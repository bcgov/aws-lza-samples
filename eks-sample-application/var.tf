variable "region" {
  type    = string
  default = "ca-central-1"
}
variable "cluster_name" {
  type    = string
  default = "eks-bcgov-sample-app"
}


variable "alb_allowed_ingress_cidrs" {
  type        = list(string)
  description = "CIDRs permitted to reach the internal ALB on port 80"
  default     = ["10.0.0.0/8"]
}

variable "tags" {
  type    = map(string)
  default = {}
}