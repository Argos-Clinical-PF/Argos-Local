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

resource "aws_ecr_repository" "repos" {
  for_each             = toset(["argos-backend", "argos-frontend", "argos-transcripcion"])
  name                 = each.value
  image_tag_mutability = "MUTABLE"
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
        countNumber = 15
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
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  tags = {
    Name = "argos-app"
  }
}

resource "aws_eip" "app" {
  instance = aws_instance.app.id
  domain   = "vpc"
  tags = {
    Name = "argos-eip"
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

  rule {
    id     = "eliminar-bundles-antiguos"
    status = "Enabled"
    filter {
      prefix = "deploy/"
    }
    expiration {
      days = 30
    }
  }
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
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject"
        ]
        Resource = "${aws_s3_bucket.operacion.arn}/*"
      }
    ]
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
            "repo:Argos-Clinical-PF/Argos-Backend:*",
            "repo:Argos-Clinical-PF/Argos-Frontend:*",
            "repo:Argos-Clinical-PF/Argos-Local:*",
            "repo:Argos-Clinical-PF/Argos-Entrenamiento:*"
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
          "ssm:GetCommandInvocation",
          "ssm:ListCommandInvocations",
          "ssm:SendCommand",
          "s3:ListAllMyBuckets"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject"
        ]
        Resource = "${aws_s3_bucket.operacion.arn}/deploy/*"
      }
    ]
  })
}
