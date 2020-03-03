provider "aws" {
  profile = "default"
  region  = var.region
}

# Build Docker image and push to ECR from folder: ./example-service-directory
module "ecr_docker_build" {
  source = "github.com/onnimonni/terraform-ecr-docker-build-module"

  # Absolute path into the service which needs to be build
  dockerfile_folder = var.dockerfile_folder

  # Tag for the builded Docker image (Defaults to 'latest')
  docker_image_tag = var.docker_image_tag
  
  # The region which we will log into with aws-cli
  aws_region = aws_region

  # ECR repository where we can push
  ecr_repository_url = var.ecr_repository_url
}