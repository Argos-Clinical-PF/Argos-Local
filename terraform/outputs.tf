output "url" {
  description = "URL pública de ARGOS"
  value = (
    var.cloudfront_fallback_enabled
    ? "https://${aws_cloudfront_distribution.app[0].domain_name}"
    : (var.public_base_url != "" ? var.public_base_url : local.direct_ip_url)
  )
}

output "direct_ip_url" {
  description = "URL HTTPS sin dependencia de DNS, respaldada por certificado IP de corta duracion"
  value       = local.direct_ip_url
}

output "origin_url" {
  description = "Origen HTTPS directo usado por CloudFront y para contingencia"
  value       = local.sslip_url
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

output "grabaciones_bucket" {
  value = aws_s3_bucket.grabaciones.id
}

output "github_actions_role_arn" {
  value = aws_iam_role.github_actions.arn
}
