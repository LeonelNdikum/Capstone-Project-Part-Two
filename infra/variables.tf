variable "aws_region" {
  description = "AWS region for the ECR repository"
  type        = string
  default     = "eu-west-2"
}

variable "repository_name" {
  description = "ECR automation"
  type        = string
  default     = "capstone-image"
}
