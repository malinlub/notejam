provider "aws" {
  profile = "default"
  region  = var.aws_region
}

resource "local_file" "create_docker_file" {
  filename = "../notejam/Dockerfile"
  
  content = <<EOF
FROM python:2.7-alpine
ENV PYTHONUNBUFFERED 1
ENV DB_HOST=${aws_rds_cluster.notejam_rds_cluster.endpoint}
RUN mkdir /notejam
WORKDIR /notejam
COPY requirements.txt /notejam/
RUN apk update \
    && apk add --no-cache --virtual .build-deps musl-dev gcc mariadb-dev \
    && pip wheel -r requirements.txt --no-cache-dir --no-input \
    && pip install -r requirements.txt \
    && apk del .build-deps musl-dev gcc mariadb-dev \
    && apk add --no-cache mariadb-connector-c-dev
COPY . /notejam/



COPY ./start.sh /notejam/
ENTRYPOINT ["/notejam/start.sh"]
EOF

}



### Build Docker image and push to ECR from folder: 
module "ecr_docker_build" {
  source = "github.com/malinlub/terraform-ecr-docker-build-module"
  dockerfile_folder = dirname(local_file.create_docker_file.filename)
  docker_image_tag = var.docker_image_tag
  aws_region = var.aws_region
  ecr_repository_url = var.ecr_repository_url
  
  custom_depends_on = [local_file.create_docker_file.content]
}

### Create infra based on Fargate ECS
# Fetch AZs in the current region
data "aws_availability_zones" "available" {}

resource "aws_vpc" "main" {
  cidr_block = "172.17.0.0/16"
}

# Create var.az_count private subnets, each in a different AZ
resource "aws_subnet" "private" {
  count             = var.az_count
  cidr_block        = cidrsubnet(aws_vpc.main.cidr_block, 8, count.index)
  availability_zone = data.aws_availability_zones.available.names[count.index]
  vpc_id            = aws_vpc.main.id
}

# Create var.az_count public subnets, each in a different AZ
resource "aws_subnet" "public" {
  count                   = var.az_count
  cidr_block              = cidrsubnet(aws_vpc.main.cidr_block, 8, var.az_count + count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  vpc_id                  = aws_vpc.main.id
  map_public_ip_on_launch = true
}


# IGW for the public subnet
resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id
}

# Route the public subnet traffic through the IGW
resource "aws_route" "internet_access" {
  route_table_id         = aws_vpc.main.main_route_table_id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.gw.id
}

# Create a NAT gateway with an EIP for each private subnet to get internet connectivity
resource "aws_eip" "gw" {
  count      = var.az_count
  vpc        = true
  depends_on = [aws_internet_gateway.gw]
}

resource "aws_nat_gateway" "gw" {
  count         = var.az_count
  subnet_id     = element(aws_subnet.public.*.id, count.index)
  allocation_id = element(aws_eip.gw.*.id, count.index)
}

# Create a new route table for the private subnets
# And make it route non-local traffic through the NAT gateway to the internet
resource "aws_route_table" "private" {
  count  = var.az_count
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    nat_gateway_id = element(aws_nat_gateway.gw.*.id, count.index)
  }
}

# Explicitely associate the newly created route tables to the private subnets (so they don't default to the main route table)
resource "aws_route_table_association" "private" {
  count          = var.az_count
  subnet_id      = element(aws_subnet.private.*.id, count.index)
  route_table_id = element(aws_route_table.private.*.id, count.index)
}

### Security

# ALB Security group
# This is the group you need to edit if you want to restrict access to your application
resource "aws_security_group" "lb" {
  name        = "notejam-ecs-alb"
  description = "controls access to the ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    protocol    = "tcp"
    from_port   = 80
    to_port     = 80
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Traffic to the ECS Cluster should only come from the ALB
resource "aws_security_group" "ecs_tasks" {
  name        = "notejam-ecs-tasks"
  description = "allow inbound access from the ALB only"
  vpc_id      = aws_vpc.main.id

  ingress {
    protocol        = "tcp"
    from_port       = var.app_port
    to_port         = var.app_port
    security_groups = [aws_security_group.lb.id]
  }

  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
}

### ALB conf

# Issue with returning tuple of subnet ids instead of list - conversion
locals {                                                            
  subnet_ids_pub_list = tolist(aws_subnet.public.*.id)
  subnet_ids_pri_list = tolist(aws_subnet.private.*.id)             
} 


resource "aws_alb" "main" {
  name            = "notejam-fargate"
  subnets         = local.subnet_ids_pub_list
  security_groups = ["${aws_security_group.lb.id}"]
}

resource "aws_alb_target_group" "app" {
  name        = "notejam-targetgroup"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"

  depends_on = [
    aws_alb.main
  ]
}

# Redirect all traffic from the ALB to the target group
resource "aws_alb_listener" "front_end" {
  load_balancer_arn = aws_alb.main.id
  port              = "80"
  protocol          = "HTTP"

  default_action {
    target_group_arn = aws_alb_target_group.app.id
    type             = "forward"
  }
}

### RDS Aurora config

# subnet group
resource "aws_db_subnet_group" "aurora_db_subnet" {
  name       = "notejam_db_subnet"
  subnet_ids = local.subnet_ids_pri_list
}

# security group - allow only ECS Fargate task
resource "aws_security_group" "rds_notejam" {
  name   = "rds-notejam-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port = "3306"
    to_port   = "3306"
    protocol  = "tcp"
    self      = true
  }
  ingress {
    from_port = "3306"
    to_port   = "3306"
    protocol  = "tcp"
    security_groups = [
        "${aws_security_group.ecs_tasks.id}"
    ]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [
        "0.0.0.0/0"
        ]
  }
}

resource "aws_rds_cluster" "notejam_rds_cluster" {
  cluster_identifier         = "notejam-db-cluster"
  engine                     = "aurora"
  engine_mode                = "serverless"
  storage_encrypted          = "false"
  master_username            = var.rds_db_user
  master_password            = var.rds_db_pass
  database_name              = "notejam_db"
  backup_retention_period    = "7"
  preferred_backup_window    = "01:00-03:00"
  deletion_protection        = "false"
  enable_http_endpoint        = "true"

  skip_final_snapshot        = true
  db_subnet_group_name       = aws_db_subnet_group.aurora_db_subnet.name
  
  vpc_security_group_ids     = [ "${aws_security_group.rds_notejam.id}" ]

  scaling_configuration {
    min_capacity             = "2"
    max_capacity             = "2"
    auto_pause               = "true"
    seconds_until_auto_pause = "300"
  }
}

### ECS Fargate config

resource "aws_ecs_cluster" "main" {
  name = "notejam-cluster"
}

# IAM role for ecs-task api 
resource "aws_iam_role" "ecs_task_execution_role" {
  name = "ecsTaskExecutionRole"

  assume_role_policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Action": "sts:AssumeRole",
            "Principal": {
            "Service": [
                "ecs-tasks.amazonaws.com"
            ]
            },
            "Effect": "Allow",
            "Sid": ""
        }
    ]
}
EOF
}

#attach IAM policy
resource "aws_iam_role_policy_attachment" "attach-policy" {
    role       = aws_iam_role.ecs_task_execution_role.name
    policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ECS task definition
resource "aws_ecs_task_definition" "app" {
  family                   = "app"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.fargate_cpu
  memory                   = var.fargate_memory
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn

  container_definitions = <<DEFINITION
[
  {
    "cpu": ${var.fargate_cpu},
    "image": "${var.app_image}",
    "memory": ${var.fargate_memory},
    "name": "notejam-app",
    "networkMode": "awsvpc",
    "portMappings": [
      {
        "containerPort": ${var.app_port},
        "hostPort": ${var.app_port}
      }
    ]
  }
]
DEFINITION

  depends_on = [module.ecr_docker_build]
}

#ECS service config
resource "aws_ecs_service" "main" {
  name            = "notejam-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = var.app_count
  launch_type     = "FARGATE"

  network_configuration {
    security_groups = [aws_security_group.ecs_tasks.id]
    subnets         = local.subnet_ids_pri_list
  }

  load_balancer {
    target_group_arn = aws_alb_target_group.app.id
    container_name   = "notejam-app"
    container_port   = var.app_port
  }

  depends_on = [
    aws_ecs_cluster.main,
    aws_alb_listener.front_end,
  ]
}