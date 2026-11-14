data "aws_caller_identity" "actual" {}

locals {
  cuenta_auditoria = data.aws_caller_identity.actual.account_id
  trail_auditoria  = "${local.prefijo}-invocaciones"
  arn_auditoria    = "arn:aws:cloudtrail:us-east-1:${local.cuenta_auditoria}:trail/${local.trail_auditoria}"
  bucket_auditoria = "${local.prefijo}-auditoria-${local.cuenta_auditoria}"
  arn_bucket       = "arn:aws:s3:::${local.bucket_auditoria}"
}

resource "aws_kms_key" "auditoria" {
  description             = "Clave de cifrado de la auditoria de la boveda de ARGOS"
  enable_key_rotation     = true
  deletion_window_in_days = 30

  lifecycle {
    prevent_destroy = true
  }

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AdministracionDedicada"
        Effect    = "Allow"
        Principal = { AWS = var.administrador_boveda }
        Action = ["kms:DescribeKey", "kms:GetKeyPolicy", "kms:PutKeyPolicy", "kms:GetKeyRotationStatus",
          "kms:EnableKeyRotation", "kms:DisableKeyRotation", "kms:ListResourceTags", "kms:TagResource",
        "kms:UntagResource", "kms:UpdateKeyDescription", "kms:ScheduleKeyDeletion", "kms:CancelKeyDeletion"]
        Resource = "*"
      },
      {
        Sid       = "RecuperacionRaiz"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${local.cuenta_auditoria}:root" }
        Action    = ["kms:GetKeyPolicy", "kms:PutKeyPolicy", "kms:DescribeKey", "kms:CancelKeyDeletion"]
        Resource  = "*"
        Condition = { ArnEquals = { "aws:PrincipalArn" = "arn:aws:iam::${local.cuenta_auditoria}:root" } }
      },
      {
        Sid       = "ConsultarClaveCloudTrail"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "kms:DescribeKey"
        Resource  = "*"
        Condition = { ArnEquals = { "aws:SourceArn" = local.arn_auditoria } }
      },
      {
        Sid       = "CifrarArchivoCloudTrail"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "kms:GenerateDataKey*"
        Resource  = "*"
        Condition = { StringEquals = {
          "aws:SourceArn"                            = local.arn_auditoria
          "kms:EncryptionContext:aws:cloudtrail:arn" = local.arn_auditoria
        } }
      },
      {
        Sid       = "LeerAuditoriaDesdeS3"
        Effect    = "Allow"
        Principal = { AWS = var.administrador_boveda }
        Action    = "kms:Decrypt"
        Resource  = "*"
        Condition = { StringEquals = {
          "kms:ViaService"                           = "s3.us-east-1.amazonaws.com"
          "kms:EncryptionContext:aws:cloudtrail:arn" = local.arn_auditoria
        } }
      }
    ]
  })
}

resource "aws_s3_bucket" "auditoria" {
  bucket = local.bucket_auditoria

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_public_access_block" "auditoria" {
  bucket                  = aws_s3_bucket.auditoria.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "auditoria" {
  bucket = aws_s3_bucket.auditoria.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "auditoria" {
  bucket = aws_s3_bucket.auditoria.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.auditoria.arn
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "auditoria" {
  bucket = aws_s3_bucket.auditoria.id

  rule {
    id     = "expirar-auditoria"
    status = "Enabled"
    filter {
      prefix = "AWSLogs/${local.cuenta_auditoria}/"
    }
    expiration {
      days = 90
    }
  }
}

resource "aws_s3_bucket_policy" "auditoria" {
  bucket = aws_s3_bucket.auditoria.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "PermitirConsultaCloudTrail"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = local.arn_bucket
        Condition = { StringEquals = { "aws:SourceArn" = local.arn_auditoria } }
      },
      {
        Sid       = "PermitirEntregaCloudTrail"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${local.arn_bucket}/AWSLogs/${local.cuenta_auditoria}/*"
        Condition = { StringEquals = {
          "aws:SourceArn" = local.arn_auditoria
          "s3:x-amz-acl"  = "bucket-owner-full-control"
        } }
      },
      {
        Sid       = "RequerirTLS"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [local.arn_bucket, "${local.arn_bucket}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false", "aws:PrincipalIsAWSService" = "false" } }
      }
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.auditoria, aws_s3_bucket_ownership_controls.auditoria]
}

resource "aws_cloudtrail" "auditoria" {
  name                          = local.trail_auditoria
  s3_bucket_name                = aws_s3_bucket.auditoria.id
  kms_key_id                    = aws_kms_key.auditoria.arn
  enable_logging                = true
  enable_log_file_validation    = true
  include_global_service_events = false

  advanced_event_selector {
    name = "Invocaciones de la boveda"

    field_selector {
      field  = "eventCategory"
      equals = ["Data"]
    }

    field_selector {
      field  = "resources.type"
      equals = ["AWS::Lambda::Function"]
    }

    field_selector {
      field       = "resources.ARN"
      equals      = [for funcion in aws_lambda_function.boveda : funcion.arn]
      starts_with = [for funcion in aws_lambda_function.boveda : "${funcion.arn}:"]
    }
  }

  depends_on = [aws_s3_bucket_policy.auditoria, aws_s3_bucket_server_side_encryption_configuration.auditoria]
}
