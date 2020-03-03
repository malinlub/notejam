variable "dockerfile_folder" {
  type        = string
  description = "This is the folder which contains the Dockerfile"
  default     = "/Users/malinlub/git/notejam/notejam"
}

variable "docker_image_tag" {
  type        = string
  description = "This is the tag which will be used for the image that you created"
  default     = "latest"
}

variable "aws_region" {
  type        = string
  description = "AWS region for ECR"
  default     = "us-west-2"
}

variable "ecr_repository_url" {
  type        = string
  description = "Full url for the ecr repository"
  default     = "827132735448.dkr.ecr.us-west-2.amazonaws.com/notejam-docker-app"
}