output "ecr_image_url" {
  value       = "${var.ecr_repository_url}:${var.docker_image_tag}"
  description = "Full URL to image in ecr with tag"
}

output "alb_hostname" {
  value = aws_alb.main.dns_name
}