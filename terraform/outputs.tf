output "url" {
  description = "URL pública de ARGOS"
  value       = "https://${replace(aws_eip.app.public_ip, ".", "-")}.sslip.io"
}

output "ec2_public_ip" {
  description = "IP elástica de la EC2 (estable al frenar/arrancar)"
  value       = aws_eip.app.public_ip
}

output "instance_id" {
  value = aws_instance.app.id
}

output "ecr_repos" {
  description = "URLs de los repos ECR para GitHub Actions"
  value       = { for k, r in aws_ecr_repository.repos : k => r.repository_url }
}

output "operacion_bucket" {
  value = aws_s3_bucket.operacion.id
}

output "github_actions_role_arn" {
  value = aws_iam_role.github_actions.arn
}
