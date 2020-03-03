# vars for docker build and push
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

# vars for Fargate
variable "az_count" {
  description = "Number of AZs to cover in a given AWS region"
  default     = "2"
}

variable "app_image" {
  description = "Docker image to run in the ECS cluster"
  default     = "827132735448.dkr.ecr.us-west-2.amazonaws.com/notejam-docker-app:latest"
}

variable "app_port" {
  description = "Port exposed by the docker image to redirect traffic to"
  default     = 8000
}

variable "app_count" {
  description = "Number of docker containers to run"
  default     = 2
}

variable "fargate_cpu" {
  description = "Fargate instance CPU units to provision (1 vCPU = 1024 CPU units)"
  default     = "256"
}

variable "fargate_memory" {
  description = "Fargate instance memory to provision (in MiB)"
  default     = "512"
}