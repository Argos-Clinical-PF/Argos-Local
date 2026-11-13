locals {
  prefijo = "argos-piloto-boveda"
  modos   = toset(["guardar", "resolver"])
}

resource "aws_dynamodb_table" "boveda" {
  name         = local.prefijo
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "ambito"
  range_key    = "referencia"

  attribute {
    name = "ambito"
    type = "S"
  }

  attribute {
    name = "referencia"
    type = "S"
  }

  server_side_encryption {
    enabled = true
  }

  point_in_time_recovery {
    enabled = true
  }
}

resource "aws_dynamodb_table" "auditoria" {
  name         = "${local.prefijo}-auditoria"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "evento"

  attribute {
    name = "evento"
    type = "S"
  }

  server_side_encryption {
    enabled = true
  }

  point_in_time_recovery {
    enabled = true
  }

  ttl {
    attribute_name = "expira"
    enabled        = true
  }
}

resource "aws_kms_key" "cifrado" {
  description             = "Cifrado de alias sinteticos de ARGOS"
  enable_key_rotation     = true
  deletion_window_in_days = 7
}

resource "aws_kms_key" "huella" {
  description              = "Huellas de alias sinteticos de ARGOS"
  customer_master_key_spec = "HMAC_256"
  key_usage                = "GENERATE_VERIFY_MAC"
  deletion_window_in_days  = 7
}

data "archive_file" "boveda" {
  type        = "zip"
  source_dir  = "${path.module}/.build/lambda"
  output_path = "${path.module}/.build/boveda.zip"
}

resource "aws_cloudwatch_log_group" "boveda" {
  for_each          = local.modos
  name              = "/aws/lambda/${local.prefijo}-${each.key}"
  retention_in_days = 14
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

resource "aws_iam_role_policy" "boveda" {
  for_each = local.modos
  name     = "${local.prefijo}-${each.key}"
  role     = aws_iam_role.boveda[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Effect   = "Allow"
        Action   = each.key == "guardar" ? ["dynamodb:PutItem", "dynamodb:GetItem"] : ["dynamodb:BatchGetItem"]
        Resource = aws_dynamodb_table.boveda.arn
      },
      {
        Effect   = "Allow"
        Action   = "dynamodb:PutItem"
        Resource = aws_dynamodb_table.auditoria.arn
      },
      {
        Effect   = "Allow"
        Action   = each.key == "guardar" ? "kms:Encrypt" : "kms:Decrypt"
        Resource = aws_kms_key.cifrado.arn
        Condition = {
          StringEquals = {
            "kms:EncryptionContext:entorno" = "piloto-tokenizacion"
            "kms:EncryptionContext:dato"    = "alias-paciente"
          }
        }
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.boveda[each.key].arn}:*"
      }
      ], each.key == "guardar" ? [{
        Effect   = "Allow"
        Action   = "kms:GenerateMac"
        Resource = aws_kms_key.huella.arn
    }] : [])
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
    variables = merge({
      OPERACION       = each.key
      PROFESIONALES   = join(",", sort(tolist(var.profesionales)))
      CLAVE_CIFRADO   = aws_kms_key.cifrado.arn
      CLAVE_HUELLA    = aws_kms_key.huella.arn
      TABLA_BOVEDA    = aws_dynamodb_table.boveda.name
      TABLA_AUDITORIA = aws_dynamodb_table.auditoria.name
      }, var.cognito == null ? {
      EMISOR        = "argos-emisor-sintetico"
      CLAVE_PUBLICA = var.clave_publica
      } : {
      COGNITO_EMISOR    = var.cognito.emisor
      COGNITO_CLIENTE   = var.cognito.cliente
      COGNITO_AUDIENCIA = var.cognito.audiencia
      COGNITO_ALCANCE   = var.cognito.alcance
      COGNITO_VINCULOS  = jsonencode(var.cognito.vinculos)
    })
  }

  depends_on = [aws_iam_role_policy.boveda]
}

resource "aws_lambda_alias" "piloto" {
  for_each         = local.modos
  name             = "piloto"
  function_name    = aws_lambda_function.boveda[each.key].function_name
  function_version = aws_lambda_function.boveda[each.key].version
}

resource "aws_iam_role" "cliente" {
  name = "${local.prefijo}-cliente"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = var.principal_de_pruebas }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "cliente" {
  name = "${local.prefijo}-invocar"
  role = aws_iam_role.cliente.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = [for alias in aws_lambda_alias.piloto : alias.arn]
    }]
  })
}

output "invocacion" {
  value = {
    rol      = aws_iam_role.cliente.arn
    guardar  = aws_lambda_alias.piloto["guardar"].arn
    resolver = aws_lambda_alias.piloto["resolver"].arn
  }
}
