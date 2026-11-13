locals {
  nombre  = "argos-boveda-validacion"
  recurso = "https://argosclinical.online/recursos/boveda-validacion"
  permiso = "alias"
  retorno = "http://localhost:5197/oidc/callback"
  dominio = "${local.nombre}-616322963974"
}

resource "aws_cognito_user_pool" "profesionales" {
  name                = local.nombre
  deletion_protection = "ACTIVE"
  mfa_configuration   = "ON"
  user_pool_tier      = "LITE"

  admin_create_user_config {
    allow_admin_create_user_only = true
  }

  software_token_mfa_configuration {
    enabled = true
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "admin_only"
      priority = 1
    }
  }

  password_policy {
    minimum_length                   = 14
    require_lowercase                = true
    require_numbers                  = true
    require_symbols                  = true
    require_uppercase                = true
    temporary_password_validity_days = 1
  }
}

resource "aws_cognito_user_pool_domain" "profesionales" {
  domain                = local.dominio
  user_pool_id          = aws_cognito_user_pool.profesionales.id
  managed_login_version = 1
}

resource "aws_cognito_resource_server" "boveda" {
  name         = local.nombre
  identifier   = local.recurso
  user_pool_id = aws_cognito_user_pool.profesionales.id

  scope {
    scope_name        = local.permiso
    scope_description = "Acceso al alias del expediente propio de validacion"
  }
}

resource "aws_cognito_user_pool_client" "profesionales" {
  name                                 = local.nombre
  user_pool_id                         = aws_cognito_user_pool.profesionales.id
  generate_secret                      = false
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = aws_cognito_resource_server.boveda.scope_identifiers
  callback_urls                        = [local.retorno]
  supported_identity_providers         = ["COGNITO"]
  explicit_auth_flows                  = ["ALLOW_REFRESH_TOKEN_AUTH"]
  enable_token_revocation              = true
  prevent_user_existence_errors        = "ENABLED"
  access_token_validity                = 5
  refresh_token_validity               = 1

  token_validity_units {
    access_token  = "minutes"
    refresh_token = "hours"
  }
}

output "oidc" {
  value = {
    emisor       = "https://cognito-idp.us-east-1.amazonaws.com/${aws_cognito_user_pool.profesionales.id}"
    cliente      = aws_cognito_user_pool_client.profesionales.id
    autorizacion = "https://${local.dominio}.auth.us-east-1.amazoncognito.com/oauth2/authorize"
    token        = "https://${local.dominio}.auth.us-east-1.amazoncognito.com/oauth2/token"
    audiencia    = local.recurso
    alcance      = "${local.recurso}/${local.permiso}"
    retorno      = local.retorno
  }
}
