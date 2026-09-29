data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

data "aws_caller_identity" "current" {}

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

# Secreto que CloudFront agrega a cada request al origen: con él el backend confía en
# CloudFront-Viewer-Address para limitar por la IP real del visitante (ver DEPLOY.md, «Secreto de origen»).
data "aws_ssm_parameter" "secreto_origen_cloudfront" {
  name = "/argos/mvp/secreto-origen-cloudfront"
}

# AMI del host de inferencia GPU (inferencia.tf): driver NVIDIA, Docker y NVIDIA Container Toolkit.
data "aws_ssm_parameter" "dlami_gpu_al2023" {
  name = "/aws/service/deeplearning/ami/x86_64/base-oss-nvidia-driver-gpu-amazon-linux-2023/latest/ami-id"
}

resource "aws_ecr_repository" "repos" {
  for_each             = toset(["argos-backend", "argos-frontend", "argos-transcripcion", "argos-emociones"])
  name                 = each.value
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true
  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "repos" {
  for_each   = aws_ecr_repository.repos
  repository = each.value.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Conservar las ultimas 15 imagenes"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 5
      }
      action = {
        type = "expire"
      }
    }]
  })
}

resource "aws_security_group" "ec2" {
  name        = "argos-ec2-sg"
  description = "ARGOS app host"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "HTTP para desafio ACME y redireccion a HTTPS"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "HTTPS publico del MVP"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "app" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = var.instance_type
  subnet_id                   = data.aws_subnets.default.ids[0]
  vpc_security_group_ids      = [aws_security_group.ec2.id]
  iam_instance_profile        = aws_iam_instance_profile.ec2.name
  user_data                   = file("${path.module}/user_data.sh")
  user_data_replace_on_change = false

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    encrypted   = true
    # El disco guarda la base: la política de DLM de abajo lo toma por esta etiqueta.
    tags = {
      Name     = "argos-app-raiz"
      Respaldo = "argos-diario"
    }
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  tags = {
    Name        = "argos-app"
    ComputeMode = "cpu"
  }

  lifecycle {
    # La AMI latest solo se adopta en una recreacion explicitamente revisada; nunca destruir el
    # host por drift diario. La GPU no va en esta instancia sino en el host de inferencia (ADR-037).
    ignore_changes = [ami]
  }

}

# Snapshot diario del disco de la instancia (base incluida), 7 días de retención. Corre aunque la
# instancia esté detenida: el volumen sigue existiendo y el snapshot es incremental.
resource "aws_iam_role" "dlm" {
  name = "argos-dlm-respaldos"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "dlm.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "dlm" {
  role       = aws_iam_role.dlm.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}

resource "aws_dlm_lifecycle_policy" "respaldo_diario" {
  description        = "ARGOS snapshot diario del disco con la base"
  execution_role_arn = aws_iam_role.dlm.arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["VOLUME"]
    target_tags = {
      Respaldo = "argos-diario"
    }

    schedule {
      name      = "diario-7-dias"
      copy_tags = true
      tags_to_add = {
        Proyecto = "argos"
      }
      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = ["07:00"]
      }
      retain_rule {
        count = 7
      }
    }
  }
}

resource "aws_eip" "app" {
  instance = aws_instance.app.id
  domain   = "vpc"
  tags = {
    Name = "argos-eip"
  }
}

locals {
  # Reglas que inspeccionan el cuerpo de la request, prefijadas por grupo administrado.
  prefijo_por_grupo = {
    "AWSManagedRulesAmazonIpReputationList" = "ip:"
    "AWSManagedRulesCommonRuleSet"          = "comun:"
    "AWSManagedRulesKnownBadInputsRuleSet"  = "malos:"
  }
  reglas_que_inspeccionan_cuerpo = [
    "comun:SizeRestrictions_BODY",
    "comun:CrossSiteScripting_BODY",
    "comun:GenericLFI_BODY",
    "comun:GenericRFI_BODY",
    "comun:EC2MetaDataSSRF_BODY",
    "malos:Log4JRCE_BODY",
    "malos:JavaDeserializationRCE_BODY",
  ]

  public_url    = "https://${var.domain_name}"
  www_domain    = "www.${var.domain_name}"
  origin_domain = "origin.${var.domain_name}"
  origin_url    = "https://${local.origin_domain}"
}

data "aws_cloudfront_cache_policy" "sin_cache" {
  name = "Managed-CachingDisabled"
}

data "aws_cloudfront_cache_policy" "optimizada" {
  name = "Managed-CachingOptimized"
}

data "aws_cloudfront_origin_request_policy" "todos_sin_host" {
  name = "Managed-AllViewerExceptHostHeader"
}

# Cabeceras de seguridad en cada respuesta del borde: la SPA, la API, los assets y la página de pausa.
# La CSP permite solo lo que el frontend usa: sus propios scripts más dos inline por hash (el tema de
# Argos-Frontend/index.html y el de pausa/index.html; si cambia alguno, hay que recalcular su hash), las
# URLs firmadas del bucket de grabaciones para escuchar y subir, y las dos APIs de geografía.
locals {
  origenes_grabaciones = "https://${aws_s3_bucket.grabaciones.bucket_regional_domain_name} https://${aws_s3_bucket.grabaciones.bucket_domain_name}"
  csp = join("; ", [
    "default-src 'self'",
    "script-src 'self' 'sha256-ELLtivtgW4M8MKRCNWjB0vPMqMDWxB47pOPne1Coizg=' 'sha256-c12HwDqeIDyjNsk/Ku7ySwTrSZ6dOVMPBM97WIorqo4='",
    "style-src 'self' 'unsafe-inline'",
    "img-src 'self' data: blob:",
    "font-src 'self' data:",
    "media-src 'self' blob: ${local.origenes_grabaciones}",
    "connect-src 'self' ${local.origenes_grabaciones} https://countriesnow.space https://apis.datos.gob.ar",
    "frame-ancestors 'none'",
    "base-uri 'self'",
    "form-action 'self'",
    "object-src 'none'",
  ])
}

resource "aws_cloudfront_response_headers_policy" "seguridad" {
  name = "argos-seguridad"

  security_headers_config {
    strict_transport_security {
      access_control_max_age_sec = 31536000
      include_subdomains         = true
      override                   = true
    }
    content_type_options {
      override = true
    }
    frame_options {
      frame_option = "DENY"
      override     = true
    }
    referrer_policy {
      referrer_policy = "no-referrer"
      override        = true
    }
    content_security_policy {
      content_security_policy = local.csp
      override                = true
    }
  }
}

# La zona y el certificado se crean acá: en una cuenta nueva no existe nada que leer, y
# dejarlos como `data` obligaba a prepararlos a mano antes del primer apply.
resource "aws_route53_zone" "app" {
  name    = var.domain_name
  comment = "ARGOS - zona publica del dominio"
}

resource "aws_acm_certificate" "app" {
  domain_name               = var.domain_name
  subject_alternative_names = ["*.${var.domain_name}"]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "validacion_certificado" {
  for_each = {
    for opcion in aws_acm_certificate.app.domain_validation_options :
    opcion.domain_name => opcion
  }

  zone_id         = aws_route53_zone.app.zone_id
  name            = each.value.resource_record_name
  type            = each.value.resource_record_type
  records         = [each.value.resource_record_value]
  ttl             = 60
  allow_overwrite = true
}

# El apply espera acá hasta que ACM valida por DNS. Sin esto, CloudFront falla al asociar un
# certificado que todavia esta PENDING_VALIDATION.
resource "aws_acm_certificate_validation" "app" {
  certificate_arn         = aws_acm_certificate.app.arn
  validation_record_fqdns = [for registro in aws_route53_record.validacion_certificado : registro.fqdn]
}

resource "aws_route53_record" "origin" {
  zone_id = aws_route53_zone.app.zone_id
  name    = local.origin_domain
  type    = "A"
  ttl     = 60
  records = [aws_eip.app.public_ip]
}

# WAF propio, no el que crea el asistente de CloudFront: aquel queda atado a una suscripcion de
# plan de precios que no admite reglas propias, no se puede desasociar y solo se cancela desde la
# consola (ADR-023). Creando la distribucion por Terraform no existe esa suscripcion.
#
# Apagado por defecto: cuesta del orden de USD 9/mes y la cuenta arranca sin credito. Encenderlo es
# cambiar una variable; el codigo ya contempla las rutas multipart para no repetir el bloqueo
# silencioso de las subidas que documenta el ADR.
resource "aws_wafv2_regex_pattern_set" "subidas" {
  count = var.waf_habilitado ? 1 : 0
  name  = "argos-rutas-multipart"
  scope = "CLOUDFRONT"

  # Las tres unicas rutas cuyo cuerpo supera los 8 KB que inspecciona el CommonRuleSet.
  regular_expression {
    regex_string = "^/api/sessions/[^/]+/transcripcion$"
  }
  regular_expression {
    regex_string = "^/api/sessions/[^/]+/analisis-emocional/video$"
  }
  regular_expression {
    regex_string = "^/api/perfil/foto$"
  }
}

resource "aws_wafv2_web_acl" "app" {
  count = var.waf_habilitado ? 1 : 0
  name  = "argos-web-acl"
  scope = "CLOUDFRONT"

  default_action {
    allow {}
  }

  # Prioridad 0: las subidas multipart se resuelven antes de llegar a los grupos administrados.
  rule {
    name     = "permitir-subidas-multipart"
    priority = 0

    action {
      allow {}
    }

    statement {
      regex_pattern_set_reference_statement {
        arn = aws_wafv2_regex_pattern_set.subidas[0].arn
        field_to_match {
          uri_path {}
        }
        text_transformation {
          priority = 0
          type     = "NONE"
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "argos-subidas-multipart"
      sampled_requests_enabled   = true
    }
  }

  dynamic "rule" {
    for_each = {
      "AWSManagedRulesAmazonIpReputationList" = 1
      "AWSManagedRulesCommonRuleSet"          = 2
      "AWSManagedRulesKnownBadInputsRuleSet"  = 3
    }

    content {
      name     = rule.key
      priority = rule.value

      override_action {
        none {}
      }

      statement {
        managed_rule_group_statement {
          vendor_name = "AWS"
          name        = rule.key

          # Segunda red: las reglas que miran el cuerpo quedan en Count. Aunque una ruta de subida
          # se escape del patron de arriba, no se convierte en un 403 sin explicacion.
          dynamic "rule_action_override" {
            for_each = toset([
              for regla in local.reglas_que_inspeccionan_cuerpo : regla
              if startswith(regla, local.prefijo_por_grupo[rule.key])
            ])
            content {
              name = trimprefix(rule_action_override.value, local.prefijo_por_grupo[rule.key])
              action_to_use {
                count {}
              }
            }
          }
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = rule.key
        sampled_requests_enabled   = true
      }
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "argos-web-acl"
    sampled_requests_enabled   = true
  }
}

# Canonicaliza el host en el borde: `www` responde 301 al dominio raíz. Ver
# functions/redirigir-www.js para el motivo (CORS con un solo origen).
resource "aws_cloudfront_function" "redirigir_www" {
  name    = "argos-redirigir-www"
  runtime = "cloudfront-js-2.0"
  comment = "Redirige www.${var.domain_name} al dominio raiz"
  publish = true
  code    = file("${path.module}/functions/redirigir-www.js")
}

# Página "ARGOS está en pausa": la EC2 pasa la mayor parte del tiempo detenida, y sin esto el
# dominio colgaba 30 s y terminaba en el 504 en inglés de CloudFront. El bucket es público a
# propósito y solo contiene esa página: el endpoint de sitio web de S3 (el único que devuelve un
# documento de error para cualquier ruta) no admite acceso privado desde CloudFront.
resource "aws_s3_bucket" "pausa" {
  bucket        = "argos-mvp-pausa-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "pausa" {
  bucket                  = aws_s3_bucket.pausa.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_policy" "pausa" {
  bucket = aws_s3_bucket.pausa.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "LecturaPublicaDeLaPaginaDePausa"
      Effect    = "Allow"
      Principal = "*"
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.pausa.arn}/*"
    }]
  })
  depends_on = [aws_s3_bucket_public_access_block.pausa]
}

resource "aws_s3_bucket_website_configuration" "pausa" {
  bucket = aws_s3_bucket.pausa.id
  index_document {
    suffix = "index.html"
  }
  error_document {
    key = "index.html"
  }
}

resource "aws_s3_object" "pausa" {
  bucket        = aws_s3_bucket.pausa.id
  key           = "index.html"
  source        = "${path.module}/pausa/index.html"
  etag          = filemd5("${path.module}/pausa/index.html")
  content_type  = "text/html; charset=utf-8"
  cache_control = "no-store"
}

resource "aws_cloudfront_distribution" "app" {
  enabled             = true
  is_ipv6_enabled     = true
  aliases             = [var.domain_name, local.www_domain]
  price_class         = "PriceClass_All"
  wait_for_deployment = true
  http_version        = "http2"
  web_acl_id          = var.waf_habilitado ? aws_wafv2_web_acl.app[0].arn : null

  origin {
    domain_name = aws_route53_record.origin.fqdn
    origin_id   = "argos-ec2-origin"
    # Un intento de 5 s: con la EC2 detenida la navegación cae a la página de pausa en ~5 s y la
    # API responde 504 en el mismo tiempo, en vez de 3 intentos de 10 s.
    connection_attempts = 1
    connection_timeout  = 5

    custom_header {
      name  = "X-Argos-Origen"
      value = data.aws_ssm_parameter.secreto_origen_cloudfront.value
    }

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      # Tope de CloudFront sin pedir cuota: todo lo síncrono del backend debe responder antes
      # (ver «Timeouts» en DEPLOY.md).
      origin_read_timeout  = 60
      origin_ssl_protocols = ["TLSv1.2"]
    }
  }

  origin {
    domain_name = aws_s3_bucket_website_configuration.pausa.website_endpoint
    origin_id   = "argos-pausa"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  origin_group {
    origin_id = "argos-ec2-o-pausa"
    failover_criteria {
      status_codes = [500, 502, 503, 504]
    }
    member {
      origin_id = "argos-ec2-origin"
    }
    member {
      origin_id = "argos-pausa"
    }
  }

  # Navegación (HTML de la SPA): si la EC2 no contesta, la página de pausa. Un origin group solo
  # admite GET/HEAD/OPTIONS, así que todo lo que escribe va por los comportamientos de abajo. Sin
  # política de origen: nginx sirve estáticos y no necesita cookies ni query string, que no llegan
  # al bucket de pausa (se alcanza por HTTP). El path sí: los links de consentimiento llevan el token
  # en el fragmento (#t=), que no sale del navegador, pero los de revocación emitidos antes lo
  # llevan en el path (/consentimiento/revocar/:token) y en un failover viajan hasta el bucket.
  default_cache_behavior {
    target_origin_id           = "argos-ec2-o-pausa"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD", "OPTIONS"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    cache_policy_id            = data.aws_cloudfront_cache_policy.sin_cache.id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.seguridad.id

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.redirigir_www.arn
    }
  }

  # La API va directo a la EC2 y sin caché: sus 502/504 en JSON (IA_ERROR, IA_TIMEOUT) y sus 404
  # llegan tal cual al frontend, nunca reemplazados por la página de pausa.
  dynamic "ordered_cache_behavior" {
    for_each = ["/api/*", "/public/*"]
    content {
      path_pattern               = ordered_cache_behavior.value
      target_origin_id           = "argos-ec2-origin"
      viewer_protocol_policy     = "redirect-to-https"
      allowed_methods            = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
      cached_methods             = ["GET", "HEAD"]
      compress                   = true
      cache_policy_id            = data.aws_cloudfront_cache_policy.sin_cache.id
      origin_request_policy_id   = data.aws_cloudfront_origin_request_policy.todos_sin_host.id
      response_headers_policy_id = aws_cloudfront_response_headers_policy.seguridad.id

      function_association {
        event_type   = "viewer-request"
        function_arn = aws_cloudfront_function.redirigir_www.arn
      }
    }
  }

  # Los assets llevan hash en el nombre y nginx ya los marca immutable: se sirven desde el borde
  # más cercano en vez de ir a us-east-1 en cada visita. El HTML sigue sin caché.
  ordered_cache_behavior {
    path_pattern               = "/assets/*"
    target_origin_id           = "argos-ec2-origin"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    cache_policy_id            = data.aws_cloudfront_cache_policy.optimizada.id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.seguridad.id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.app.certificate_arn
    minimum_protocol_version = "TLSv1.2_2021"
    ssl_support_method       = "sni-only"
  }

  tags = {
    Name = "argos-web"
  }
}

resource "aws_route53_record" "apex" {
  zone_id = aws_route53_zone.app.zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.app.domain_name
    zone_id                = aws_cloudfront_distribution.app.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "www" {
  zone_id = aws_route53_zone.app.zone_id
  name    = local.www_domain
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.app.domain_name
    zone_id                = aws_cloudfront_distribution.app.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_iam_role" "ec2" {
  name = "argos-ec2-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecr_read" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2" {
  name = "argos-ec2-profile"
  role = aws_iam_role.ec2.name
}

resource "aws_s3_bucket" "operacion" {
  bucket        = "argos-mvp-operacion-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "operacion" {
  bucket                  = aws_s3_bucket.operacion.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "operacion" {
  bucket = aws_s3_bucket.operacion.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "operacion" {
  bucket = aws_s3_bucket.operacion.id

  rule {
    id     = "eliminar-backups-antiguos"
    status = "Enabled"
    filter {
      prefix = "backups/"
    }
    expiration {
      days = 14
    }
  }

  # Solo los bundles: los manifiestos (current.json, previous.json) no vencen nunca, porque el
  # rollback los necesita aunque la instancia pase meses detenida sin deploys.
  rule {
    id     = "eliminar-bundles-antiguos"
    status = "Enabled"
    filter {
      prefix = "deploy/releases/"
    }
    expiration {
      days = 365
    }
  }
  # El volcado de la migración es una copia completa de historias clínicas: vive lo que dura el
  # corte y se va solo, aunque el script falle antes de borrarlo.
  rule {
    id     = "respaldo-migracion-7d"
    status = "Enabled"
    filter {
      prefix = "respaldo-migracion/"
    }
    expiration {
      days = 7
    }
  }

}

resource "aws_s3_bucket" "grabaciones" {
  bucket        = "argos-mvp-grabaciones-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "grabaciones" {
  bucket = aws_s3_bucket.grabaciones.id
  versioning_configuration {
    status = "Disabled"
  }
}

resource "aws_s3_bucket_public_access_block" "grabaciones" {
  bucket                  = aws_s3_bucket.grabaciones.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "grabaciones" {
  bucket = aws_s3_bucket.grabaciones.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = "alias/aws/s3"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_cors_configuration" "grabaciones" {
  bucket = aws_s3_bucket.grabaciones.id
  cors_rule {
    allowed_methods = ["PUT", "GET"]
    allowed_origins = distinct(concat([local.public_url], var.origenes_cors_adicionales))
    allowed_headers = ["*"]
    expose_headers  = ["ETag"]
    max_age_seconds = 300
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "grabaciones" {
  bucket = aws_s3_bucket.grabaciones.id
  rule {
    id     = "defensa-eliminacion-31d"
    status = "Enabled"
    filter {}
    expiration {
      days = 31
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

resource "aws_s3_bucket_policy" "grabaciones" {
  bucket = aws_s3_bucket.grabaciones.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.grabaciones.arn, "${aws_s3_bucket.grabaciones.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}

data "archive_file" "eliminador_grabaciones" {
  type        = "zip"
  source_file = "${path.module}/lambda/eliminar_grabaciones.py"
  output_path = "${path.module}/.build/eliminar_grabaciones.zip"
}

resource "aws_iam_role" "lambda_grabaciones" {
  name = "argos-eliminar-grabaciones"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "lambda_grabaciones" {
  name = "argos-eliminar-grabaciones"
  role = aws_iam_role.lambda_grabaciones.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:ListBucketMultipartUploads"]
        Resource = aws_s3_bucket.grabaciones.arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:DeleteObject", "s3:AbortMultipartUpload", "s3:GetObjectTagging"]
        Resource = "${aws_s3_bucket.grabaciones.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:*"
      }
    ]
  })
}

resource "aws_lambda_function" "eliminar_grabaciones" {
  function_name    = "argos-eliminar-grabaciones"
  filename         = data.archive_file.eliminador_grabaciones.output_path
  source_code_hash = data.archive_file.eliminador_grabaciones.output_base64sha256
  role             = aws_iam_role.lambda_grabaciones.arn
  handler          = "eliminar_grabaciones.handler"
  runtime          = "python3.13"
  timeout          = 60
  memory_size      = 128
  environment {
    variables = {
      BUCKET                    = aws_s3_bucket.grabaciones.id
      MAX_RETENTION_HOURS       = "720"
      MULTIPART_RETENTION_HOURS = "24"
    }
  }
  depends_on = [aws_cloudwatch_log_group.eliminar_grabaciones]
}

resource "aws_cloudwatch_log_group" "eliminar_grabaciones" {
  name              = "/aws/lambda/argos-eliminar-grabaciones"
  retention_in_days = 7
}

resource "aws_iam_role" "scheduler_grabaciones" {
  name = "argos-scheduler-grabaciones"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "scheduler_grabaciones" {
  name = "argos-invocar-eliminador-grabaciones"
  role = aws_iam_role.scheduler_grabaciones.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = aws_lambda_function.eliminar_grabaciones.arn
    }]
  })
}

resource "aws_scheduler_schedule" "eliminar_grabaciones" {
  name                = "argos-eliminar-grabaciones-cada-5m"
  schedule_expression = "rate(5 minutes)"
  flexible_time_window { mode = "OFF" }
  target {
    arn      = aws_lambda_function.eliminar_grabaciones.arn
    role_arn = aws_iam_role.scheduler_grabaciones.arn
  }
}

# Logs de los contenedores (driver awslogs de docker-compose.prod.yml). Antes vivían solo en el
# disco y cada deploy los borraba al recrear los contenedores. 14 días alcanzan para investigar un
# incidente entre dos demos sin acumular costo.
resource "aws_cloudwatch_log_group" "mvp" {
  name              = "/argos/mvp"
  retention_in_days = 14
}

resource "aws_iam_role_policy" "ec2_operacion" {
  name = "argos-ec2-operacion"
  role = aws_iam_role.ec2.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:GetParametersByPath"
        ]
        Resource = "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/argos/mvp/*"
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.mvp.arn}:*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject"
        ]
        Resource = "${aws_s3_bucket.operacion.arn}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:ListBucketMultipartUploads"
        ]
        Resource = aws_s3_bucket.grabaciones.arn
      },
      {
        Effect = "Allow"
        Action = [
          "s3:AbortMultipartUpload",
          "s3:DeleteObject",
          "s3:GetObject",
          "s3:PutObjectTagging",
          "s3:ListMultipartUploadParts",
          "s3:PutObject"
        ]
        Resource = "${aws_s3_bucket.grabaciones.arn}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "kms:ViaService" = "s3.${var.region}.amazonaws.com"
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "ec2_bedrock" {
  name = "argos-ec2-bedrock"
  role = aws_iam_role.ec2.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream"
      ]
      # Solo los modelos que usa la nota clínica, por perfil de inferencia y por modelo base: el
      # perfil enruta entre regiones de EE.UU. y hace falta permitir las dos formas del ARN.
      Resource = [
        "arn:aws:bedrock:*::foundation-model/anthropic.claude-*",
        "arn:aws:bedrock:*:${data.aws_caller_identity.current.account_id}:inference-profile/*.anthropic.claude-*"
      ]
    }]
  })
}

resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
  client_id_list = [
    "sts.amazonaws.com"
  ]
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1"
  ]
}

resource "aws_iam_role" "github_actions" {
  name = "argos-github-actions"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.github.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = [
            "repo:Argos-Clinical-PF/Argos-Backend:ref:refs/heads/main",
            "repo:Argos-Clinical-PF/Argos-Frontend:ref:refs/heads/main",
            "repo:Argos-Clinical-PF/Argos-Local:ref:refs/heads/main",
            "repo:Argos-Clinical-PF/Argos-Entrenamiento:ref:refs/heads/main"
          ]
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "github_actions" {
  name = "argos-github-actions"
  role = aws_iam_role.github_actions.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:CompleteLayerUpload",
          "ecr:GetDownloadUrlForLayer",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:UploadLayerPart"
        ]
        Resource = [for repo in aws_ecr_repository.repos : repo.arn]
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeAddresses",
          "ec2:DescribeInstanceStatus",
          "ec2:DescribeInstances",
          "ec2:StartInstances",
          "ec2:StopInstances",
          "ssm:DescribeInstanceInformation",
          "ssm:GetParameter",
          "ssm:GetCommandInvocation",
          "ssm:ListCommandInvocations",
          "ssm:SendCommand",
          "s3:ListAllMyBuckets",
          "autoscaling:DescribeAutoScalingGroups"
        ]
        Resource = "*"
      },
      {
        # Operate MVP enciende y apaga el host de inferencia GPU (inferencia.tf).
        Effect   = "Allow"
        Action   = "autoscaling:SetDesiredCapacity"
        Resource = aws_autoscaling_group.inferencia.arn
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject"
        ]
        Resource = "${aws_s3_bucket.operacion.arn}/deploy/*"
      },
      {
        Effect   = "Allow"
        Action   = "s3:DeleteObject"
        Resource = "${aws_s3_bucket.operacion.arn}/deploy/release.lock"
      }
    ]
  })
}

resource "aws_budgets_budget" "mensual" {
  # Sin esto el presupuesto mide gasto NETO de crédito: marca USD 0,00 hasta que el crédito se
  # agota y recién ahí avisa, que es como se quedó sin nada la cuenta anterior. Con el uso bruto,
  # los avisos llegan mientras todavía hay crédito para reaccionar.
  cost_types {
    include_credit   = false
    include_refund   = false
    include_discount = false
  }

  name         = "argos-mvp-mensual"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 50
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_email]
  }
}
