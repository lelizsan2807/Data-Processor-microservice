variable "aws_region" {
  description = "AWS region where the server will be created"
  type        = string
  default     = "us-east-1"
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.micro"
}

variable "my_ip_cidr" {
  description = "Your public IP address in CIDR notation, for SSH access"
  type        = string

  validation {
    condition     = can(cidrhost(var.my_ip_cidr, 0))
    error_message = "Provide a valid CIDR, such as 203.0.113.10/32."
  }
}

variable "public_key_path" {
  description = "Path to the SSH public key in CloudShell"
  type        = string
}

variable "project_name" {
  description = "Name used to tag AWS resources"
  type        = string
  default     = "data-processor"
}