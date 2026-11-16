locals {
  nombre = "argos-salida-ia"
  cuenta = "616322963974"
  region = "us-east-1"
  ssm    = "arn:aws:ssm:${local.region}:${local.cuenta}:parameter"
  firma  = "${local.ssm}/argos/salida-ia/firma-autorizador"

  alias_produccion = "produccion"
  arn_salida       = "arn:aws:lambda:${local.region}:${local.cuenta}:function:${local.nombre}:${local.alias_produccion}"
  modelos = {
    MODELO_CLINICA = "anthropic.claude-sonnet-4-6"
    MODELO_TEMAS   = "anthropic.claude-sonnet-4-5-20250929-v1:0"
  }
  regiones_destino = ["us-east-1", "us-east-2", "us-west-2"]
  perfiles         = { for perfil, modelo in local.modelos : perfil => "us.${modelo}" }
  modelos_iam = concat(
    [for perfil in values(local.perfiles) : "arn:aws:bedrock:${local.region}:${local.cuenta}:inference-profile/${perfil}"],
    flatten([for modelo in values(local.modelos) : [
      for region in local.regiones_destino : "arn:aws:bedrock:${region}::foundation-model/${modelo}"
    ]])
  )
}

data "archive_file" "salida" {
  type        = "zip"
  source_dir  = "${path.module}/.build/lambda"
  output_path = "${path.module}/.build/salida.zip"
}

resource "aws_cloudwatch_log_group" "salida" {
  name              = "/aws/lambda/${local.nombre}"
  retention_in_days = 14
}

resource "aws_iam_role" "salida" {
  name = local.nombre
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "salida" {
  name = local.nombre
  role = aws_iam_role.salida.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "bedrock:InvokeModel"
        Resource = local.modelos_iam
      },
      {
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = local.firma
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.salida.arn}:*"
      },
    ]
  })
}

resource "aws_lambda_function" "salida" {
  function_name    = local.nombre
  role             = aws_iam_role.salida.arn
  handler          = "salida_ia.handler"
  runtime          = "python3.13"
  filename         = data.archive_file.salida.output_path
  source_code_hash = data.archive_file.salida.output_base64sha256
  publish          = true
  timeout          = 130
  memory_size      = 256

  environment {
    variables = local.perfiles
  }

  depends_on = [aws_iam_role_policy.salida]
}

resource "aws_lambda_alias" "produccion" {
  name             = local.alias_produccion
  function_name    = aws_lambda_function.salida.function_name
  function_version = aws_lambda_function.salida.version
}

resource "aws_iam_role_policy" "aplicacion" {
  name = "argos-salida-ia-aplicacion"
  role = "argos-ec2-role"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Effect   = "Allow"
          Action   = "lambda:InvokeFunction"
          Resource = local.arn_salida
        },
        {
          Effect   = "Deny"
          Action   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParameterHistory"]
          Resource = local.firma
        },
        {
          Effect = "Deny"
          Action = "ssm:GetParametersByPath"
          NotResource = [
            "${local.ssm}/argos/mvp",
            "${local.ssm}/argos/mvp/*",
          ]
        },
      ],
      [for exigir in [var.exigir_salida_aislada] : {
        Effect   = "Deny"
        Action   = ["bedrock:InvokeModel*", "bedrock:StartAsyncInvoke"]
        Resource = ["*"]
      } if exigir]
    )
  })
}
