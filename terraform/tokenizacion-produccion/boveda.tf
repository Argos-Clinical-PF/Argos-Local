locals {
  prefijo = "argos-boveda-produccion"
  modos   = toset(["guardar", "resolver"])
  claves = {
    cifrado = { spec = "SYMMETRIC_DEFAULT", uso = "ENCRYPT_DECRYPT", rotar = true }
    huella  = { spec = "HMAC_256", uso = "GENERATE_VERIFY_MAC", rotar = false }
  }
  tablas = {
    boveda    = { hash = "ambito", rango = "referencia" }
    auditoria = { hash = "evento", rango = null }
    vinculos  = { hash = "sujeto", rango = null }
    permisos  = { hash = "huella", rango = null }
  }
  contexto_kms = {
    "kms:EncryptionContext:entorno" = local.prefijo
    "kms:EncryptionContext:dato"    = "alias-paciente"
  }
}

resource "aws_dynamodb_table" "boveda" {
  for_each                    = local.tablas
  name                        = "${local.prefijo}-${each.key}"
  billing_mode                = "PAY_PER_REQUEST"
  hash_key                    = each.value.hash
  range_key                   = each.value.rango
  deletion_protection_enabled = true

  dynamic "attribute" {
    for_each = compact([each.value.hash, each.value.rango])
    content {
      name = attribute.value
      type = "S"
    }
  }

  server_side_encryption {
    enabled = true
  }

  point_in_time_recovery {
    enabled = true
  }

  dynamic "ttl" {
    for_each = contains(["auditoria", "permisos"], each.key) ? [1] : []
    content {
      attribute_name = "expira"
      enabled        = true
    }
  }
}

resource "aws_iam_role" "boveda" {
  for_each = local.modos
  name     = "${local.prefijo}-${each.key}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_kms_key" "boveda" {
  for_each                 = local.claves
  description              = "Clave de ${each.key} de la boveda de ARGOS"
  customer_master_key_spec = each.value.spec
  key_usage                = each.value.uso
  enable_key_rotation      = each.value.rotar
  deletion_window_in_days  = 30

  lifecycle {
    prevent_destroy = true
  }

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
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
        Principal = { AWS = "arn:aws:iam::616322963974:root" }
        Action    = ["kms:GetKeyPolicy", "kms:PutKeyPolicy", "kms:DescribeKey", "kms:CancelKeyDeletion"]
        Resource  = "*"
        Condition = { ArnEquals = { "aws:PrincipalArn" = "arn:aws:iam::616322963974:root" } }
      }
      ], [for modo in sort(tolist(local.modos)) : {
        Effect    = "Allow"
        Principal = { AWS = aws_iam_role.boveda[modo].arn }
        Action    = modo == "guardar" ? "kms:Encrypt" : "kms:Decrypt"
        Resource  = "*"
        Condition = { StringEquals = local.contexto_kms }
        } if each.key == "cifrado"], [for clave in [each.key] : {
        Effect    = "Allow"
        Principal = { AWS = aws_iam_role.boveda["guardar"].arn }
        Action    = "kms:GenerateMac"
        Resource  = "*"
    } if clave == "huella"])
  })
}

data "archive_file" "boveda" {
  type        = "zip"
  source_dir  = "${path.module}/.build/lambda"
  output_path = "${path.module}/.build/boveda.zip"
}

resource "aws_cloudwatch_log_group" "boveda" {
  for_each          = local.modos
  name              = "/aws/lambda/${local.prefijo}-${each.key}"
  retention_in_days = 30
}

resource "aws_iam_role_policy" "boveda" {
  for_each = local.modos
  name     = "${local.prefijo}-${each.key}"
  role     = aws_iam_role.boveda[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Effect   = "Allow"
        Action   = each.key == "guardar" ? ["dynamodb:PutItem", "dynamodb:GetItem"] : ["dynamodb:BatchGetItem", "dynamodb:GetItem"]
        Resource = aws_dynamodb_table.boveda["boveda"].arn
      },
      {
        Effect   = "Allow"
        Action   = "dynamodb:GetItem"
        Resource = aws_dynamodb_table.boveda["vinculos"].arn
      },
      {
        Effect   = "Allow"
        Action   = "dynamodb:PutItem"
        Resource = aws_dynamodb_table.boveda["auditoria"].arn
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.boveda[each.key].arn}:*"
      }
      ], [for modo in [each.key] : {
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:PutItem"]
        Resource = aws_dynamodb_table.boveda["permisos"].arn
    } if modo == "resolver"])
  })
}

resource "aws_lambda_function" "boveda" {
  for_each         = local.modos
  function_name    = "${local.prefijo}-${each.key}"
  role             = aws_iam_role.boveda[each.key].arn
  runtime          = "python3.13"
  handler          = "boveda_alias.handler"
  filename         = data.archive_file.boveda.output_path
  source_code_hash = data.archive_file.boveda.output_base64sha256
  publish          = true
  timeout          = 10
  memory_size      = 256

  environment {
    variables = {
      OPERACION           = each.key
      ENTORNO_BOVEDA      = local.prefijo
      AUDITORIA_DIAS      = "90"
      COGNITO_EMISOR      = "https://cognito-idp.us-east-1.amazonaws.com/${aws_cognito_user_pool.profesionales.id}"
      COGNITO_CLIENTE     = aws_cognito_user_pool_client.profesionales.id
      COGNITO_AUDIENCIA   = local.audiencia
      COGNITO_ALCANCE     = "${local.audiencia}/alias"
      TABLA_VINCULOS      = aws_dynamodb_table.boveda["vinculos"].name
      TABLA_PERMISOS_NOTA = aws_dynamodb_table.boveda["permisos"].name
      CLAVE_CIFRADO       = aws_kms_key.boveda["cifrado"].arn
      CLAVE_HUELLA        = aws_kms_key.boveda["huella"].arn
      TABLA_BOVEDA        = aws_dynamodb_table.boveda["boveda"].name
      TABLA_AUDITORIA     = aws_dynamodb_table.boveda["auditoria"].name
    }
  }

  depends_on = [aws_iam_role_policy.boveda]
}

resource "aws_lambda_alias" "produccion" {
  for_each         = local.modos
  name             = "produccion"
  function_name    = aws_lambda_function.boveda[each.key].function_name
  function_version = aws_lambda_function.boveda[each.key].version
}

resource "aws_iam_role_policy" "invocacion_app" {
  name = "argos-boveda-produccion-invocar"
  role = "argos-ec2-role"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = [for alias in aws_lambda_alias.produccion : alias.arn]
    }]
  })
}

output "configuracion" {
  value = {
    guardar      = aws_lambda_alias.produccion["guardar"].arn
    resolver     = aws_lambda_alias.produccion["resolver"].arn
    cliente      = aws_cognito_user_pool_client.profesionales.id
    autorizacion = "https://${local.dominio}.auth.us-east-1.amazoncognito.com/oauth2/authorize"
    token        = "https://${local.dominio}.auth.us-east-1.amazoncognito.com/oauth2/token"
    alcance      = "${local.audiencia}/alias"
    retorno      = local.retorno
  }
}
