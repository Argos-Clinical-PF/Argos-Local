output "url" {
  description = "URL pública de ARGOS"
  value       = local.public_url
}

output "origin_url" {
  description = "Origen HTTPS propio usado exclusivamente por CloudFront"
  value       = local.origin_url
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

output "inferencia_asg" {
  description = "ASG del host de inferencia GPU (Operate MVP lo lleva a 1 y a 0)"
  value       = aws_autoscaling_group.inferencia.name
}

output "zona_interna_id" {
  description = "Zona privada argos.internal, donde el host registra inferencia.argos.internal"
  value       = aws_route53_zone.interna.zone_id
}
