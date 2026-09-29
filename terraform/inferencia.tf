# Host de inferencia GPU (ADR-037). Los modelos corren en una instancia aparte y sin estado que un ASG
# lanza en cualquier zona con capacidad; la app sigue en CPU en us-east-1a, donde está su disco con la
# base. El 2026-09-29 pasar la app a g6.2xlarge falló 27 minutos seguidos por falta de capacidad en
# esa zona: con la GPU en la misma instancia, el producto entero dependía de esa capacidad.
#
# El enrutador de la app (Caddyfile.modelos) usa este host mientras su /health responde "ok" y su
# propia transcripción en CPU cuando no. Operate MVP lo enciende y apaga (desired 1/0, fuera de
# Terraform) y un vigía en el host lo baja a 0 si la app no está corriendo.

locals {
  nombre_inferencia = "argos-inferencia"
  dns_inferencia    = "inferencia.argos.internal"
  # En orden de prioridad. Todos entran en la cuota de 8 vCPU G, los soporta la DLAMI y cifran el
  # tráfico entre instancias Nitro, como la c7i de la app.
  tipos_inferencia = ["g6.xlarge", "g5.xlarge", "g6.2xlarge", "g4dn.xlarge"]
}

# Solo las subredes de zonas que ofrecen alguno de esos tipos: us-east-1e no ofrece ninguno.
data "aws_ec2_instance_type_offerings" "inferencia" {
  location_type = "availability-zone"
  filter {
    name   = "instance-type"
    values = local.tipos_inferencia
  }
}

data "aws_subnets" "inferencia" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "availability-zone"
    values = distinct(data.aws_ec2_instance_type_offerings.inferencia.locations)
  }
}

# La DLAMI por su id, para cifrar el disco raíz por el nombre de dispositivo que usa esa AMI.
data "aws_ami" "inferencia" {
  owners = ["amazon"]
  filter {
    name   = "image-id"
    values = [data.aws_ssm_parameter.dlami_gpu_al2023.insecure_value]
  }
}

resource "aws_route53_zone" "interna" {
  name    = "argos.internal"
  comment = "ARGOS - zona privada de la VPC por defecto"
  # El registro del host GPU lo escribe la instancia al arrancar, no Terraform.
  force_destroy = true

  vpc {
    vpc_id = data.aws_vpc.default.id
  }
}

resource "aws_security_group" "inferencia" {
  name        = local.nombre_inferencia
  description = "ARGOS host de inferencia GPU"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "Transcripcion solo desde el host de la app"
    from_port       = 9000
    to_port         = 9000
    protocol        = "tcp"
    security_groups = [aws_security_group.ec2.id]
  }
  # ECR, S3, SSM y Hugging Face por la IP pública de la subred por defecto (no hay NAT).
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_iam_role" "inferencia" {
  name = local.nombre_inferencia
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

# Sin SSH: se entra por Session Manager y los deploys llegan por SSM.
resource "aws_iam_role_policy_attachment" "inferencia_ssm" {
  role       = aws_iam_role.inferencia.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "inferencia" {
  name = local.nombre_inferencia
  role = aws_iam_role.inferencia.name
}

resource "aws_iam_role_policy" "inferencia" {
  name = local.nombre_inferencia
  role = aws_iam_role.inferencia.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # GetAuthorizationToken y DescribeInstances no admiten permisos por recurso.
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken", "ec2:DescribeInstances"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer"
        ]
        Resource = aws_ecr_repository.repos["argos-transcripcion"].arn
      },
      {
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.operacion.arn}/deploy/manifests/current.json"
      },
      {
        Effect    = "Allow"
        Action    = "s3:ListBucket"
        Resource  = aws_s3_bucket.operacion.arn
        Condition = { StringLike = { "s3:prefix" = ["modelos/*"] } }
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject"]
        Resource = "${aws_s3_bucket.operacion.arn}/modelos/*"
      },
      {
        # La misma bandera de diarización que el .env de la app (deploy-mvp.sh).
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/argos/mvp/diarizacion-enabled"
      },
      {
        # AmazonSSMManagedInstanceCore da ssm:GetParameter(s) sobre "*": sin esto el host GPU lee
        # todos los secretos de /argos/mvp, incluida la clave que cifra transcripciones y notas.
        Effect      = "Deny"
        Action      = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath", "ssm:GetParameterHistory"]
        NotResource = "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/argos/mvp/diarizacion-enabled"
      },
      {
        # Solo su propio registro A.
        Effect   = "Allow"
        Action   = "route53:ChangeResourceRecordSets"
        Resource = aws_route53_zone.interna.arn
        Condition = {
          "ForAllValues:StringEquals" = {
            "route53:ChangeResourceRecordSetsNormalizedRecordNames" = [local.dns_inferencia]
            "route53:ChangeResourceRecordSetsRecordTypes"           = ["A"]
            "route53:ChangeResourceRecordSetsActions"               = ["UPSERT"]
          }
        }
      },
      {
        # El vigía baja este ASG a 0 cuando la app no está corriendo.
        Effect   = "Allow"
        Action   = "autoscaling:SetDesiredCapacity"
        Resource = aws_autoscaling_group.inferencia.arn
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.mvp.arn}:*"
      }
    ]
  })
}

resource "aws_launch_template" "inferencia" {
  name                   = local.nombre_inferencia
  description            = "ARGOS host de inferencia GPU"
  image_id               = data.aws_ami.inferencia.id
  update_default_version = true

  user_data = base64encode(templatefile("${path.module}/../scripts/inferencia-arranque.sh", {
    region      = var.region
    bucket      = aws_s3_bucket.operacion.id
    repositorio = aws_ecr_repository.repos["argos-transcripcion"].repository_url
    asg         = local.nombre_inferencia
    app         = "argos-app"
    zona        = aws_route53_zone.interna.zone_id
    nombre_dns  = local.dns_inferencia
    grupo_logs  = aws_cloudwatch_log_group.mvp.name
    actualizar  = file("${path.module}/../scripts/inferencia-actualizar.sh")
  }))

  iam_instance_profile {
    arn = aws_iam_instance_profile.inferencia.arn
  }

  network_interfaces {
    associate_public_ip_address = true
    delete_on_termination       = true
    security_groups             = [aws_security_group.inferencia.id]
  }

  # La cuenta no cifra EBS por defecto y la AMI trae el disco sin cifrar: se cifra acá, con la
  # clave administrada aws/ebs (la misma del disco de la app). El tamaño es el de la AMI.
  block_device_mappings {
    device_name = data.aws_ami.inferencia.root_device_name
    ebs {
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  # Los contenedores no consultan IMDS: con un salto no lo alcanzan.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name    = local.nombre_inferencia
      Project = "ARGOS"
    }
  }

  tag_specifications {
    resource_type = "volume"
    tags = {
      Name    = "argos-inferencia-raiz"
      Project = "ARGOS"
    }
  }
}

resource "aws_autoscaling_group" "inferencia" {
  name                = local.nombre_inferencia
  min_size            = 0
  max_size            = 1
  desired_capacity    = 0
  vpc_zone_identifier = data.aws_subnets.inferencia.ids
  health_check_type   = "EC2"

  mixed_instances_policy {
    instances_distribution {
      on_demand_allocation_strategy            = "prioritized"
      on_demand_base_capacity                  = 0
      on_demand_percentage_above_base_capacity = 100
    }

    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.inferencia.id
        version            = "$Latest"
      }

      dynamic "override" {
        for_each = local.tipos_inferencia
        content {
          instance_type = override.value
        }
      }
    }
  }

  lifecycle {
    # El desired lo manejan Operate MVP y el vigía del host; un apply nunca lo pisa.
    ignore_changes = [desired_capacity]
  }
}
