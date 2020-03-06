provider "aws" {
  profile = "default"
  region  = var.aws_region
}

resource "local_file" "create_docker_file" {
  filename = "../notejam/Dockerfile"
  
  content = <<EOF
FROM python:2.7-alpine
ENV PYTHONUNBUFFERED 1
ENV DB_HOST=${aws_rds_cluster.rds_cluster.endpoint}
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

##########    NETWORK    ###########

# Fetch AZs in the current region
data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "main" {
  cidr_block = "172.17.0.0/16"

  tags = {
    Name = "nj-vpc"
  }
}

# Subnets for ECS Cluster - fargate tasks
resource "aws_subnet" "ecs_subnets" {
  count             = var.az_count
  cidr_block        = cidrsubnet(aws_vpc.main.cidr_block, 8, count.index)
  availability_zone = data.aws_availability_zones.available.names[count.index]
  vpc_id            = aws_vpc.main.id

  tags = {
    Name = "nj-ecs-subnet-${count.index+1}"
  }
}

# Subnets for RDS Cluster - aurora serverless
resource "aws_subnet" "rds_subnets" {
  count                   = var.az_count
  cidr_block              = cidrsubnet(aws_vpc.main.cidr_block, 8, var.az_count + count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  vpc_id                  = aws_vpc.main.id

  tags = {
    Name = "nj-rds-subnet-${count.index+1}"
  }
}

# Subnets for ALB
resource "aws_subnet" "lb_subnets" {
  count                   = var.az_count
  cidr_block              = cidrsubnet(aws_vpc.main.cidr_block, 8, var.az_count*2 + count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  vpc_id                  = aws_vpc.main.id

  tags = {
    Name = "nj-lb-subnet-${count.index+1}"
  }
}

# Subnets for NAT GW
resource "aws_subnet" "natgw_subnets" {
  count                   = var.az_count
  cidr_block              = cidrsubnet(aws_vpc.main.cidr_block, 8, var.az_count*3 + count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  vpc_id                  = aws_vpc.main.id

  tags = {
    Name = "nj-natgw-subnet-${count.index+1}"
  }
}


# IGW for the public subnets
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "nj-igw"
  }
}

# EIP for each private subnet to get internet connectivity
resource "aws_eip" "eip" {
  count      = var.az_count
  vpc        = true

  depends_on = [
    aws_internet_gateway.igw
  ]

  tags = {
    Name = "nj-eip-${count.index+1}"
  }
}

# NAT GW for private subnets where Internet access is needed 
resource "aws_nat_gateway" "natgw" {
  count         = var.az_count
  subnet_id     = element(aws_subnet.natgw_subnets.*.id, count.index)
  allocation_id = element(aws_eip.eip.*.id, count.index)

  tags = {
    Name = "nj-natgw-${count.index}"
  }
}

# Route the public subnet traffic through the IGW
resource "aws_route_table" "internet_access" {
  vpc_id                 = aws_vpc.main.id

  #default route - igw
  route {
    cidr_block    = "0.0.0.0/0"
    gateway_id    = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "nj-rt-internet-access"
  }
}

# Route private subnet traffic through NAT GW
resource "aws_route_table" "private_natgw" {
  count  = var.az_count
  vpc_id = aws_vpc.main.id

  #default via NAT
  route {
    cidr_block = "0.0.0.0/0"
    nat_gateway_id = element(aws_nat_gateway.natgw.*.id, count.index)
  }

  tags = {
    Name = "notejam-rt-natgw-private-${count.index}"
  }
}

# Route table associations - avoid default rtb
# ECS subnets
resource "aws_route_table_association" "ecs_rtb_assoc" {
  count          = var.az_count
  subnet_id      = element(aws_subnet.ecs_subnets.*.id, count.index)
  route_table_id = element(aws_route_table.private_natgw.*.id, count.index)
}

# LB subnets
resource "aws_route_table_association" "lb_rtb_assoc" {
  count          = var.az_count
  subnet_id      = element(aws_subnet.lb_subnets.*.id, count.index)
  route_table_id = aws_route_table.internet_access.id
}

# NAT GW
resource "aws_route_table_association" "natgw_rtb_assoc" {
  count          = var.az_count
  subnet_id      = element(aws_subnet.natgw_subnets.*.id, count.index)
  route_table_id = aws_route_table.internet_access.id
}


#############   ALB configuration   #############

# ALB Security group
resource "aws_security_group" "alb" {
  name        = "nj-alb-sg"
  vpc_id      = aws_vpc.main.id

  ingress {
    protocol    = "tcp"
    from_port   = 80
    to_port     = 80
    cidr_blocks = [
      "0.0.0.0/0"
    ]
  }

  egress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    cidr_blocks = [
      "0.0.0.0/0"
    ]
  }
}


# Issue with returning tuple of subnet ids instead of list - conversion
locals {                                                            
  subnet_ids_ecs_list = tolist(aws_subnet.ecs_subnets.*.id)
  subnet_ids_rds_list = tolist(aws_subnet.rds_subnets.*.id)
  subnet_ids_lb_list = tolist(aws_subnet.lb_subnets.*.id)
  subnet_ids_natgw_list = tolist(aws_subnet.natgw_subnets.*.id)             
} 

# App LB
resource "aws_alb" "main" {
  name                = "nj-lb"
  internal            = false
  load_balancer_type  = "application"
  ip_address_type     = "ipv4"

  subnets             = local.subnet_ids_lb_list

  security_groups = [
    aws_security_group.alb.id
  ]
}

# Target group
resource "aws_alb_target_group" "target_group" {
  name                  = "nj-targetgroup"
  port                  = 80
  protocol              = "HTTP"
  vpc_id                = aws_vpc.main.id
  target_type           = "ip"
  deregistration_delay  = 30

  health_check {
    protocol = "HTTP"
    path     = "/singin/"
  }

  depends_on = [
    aws_alb.main
  ]
}

# Forward all traffic from the ALB to the target group
resource "aws_alb_listener" "front_end" {
  load_balancer_arn = aws_alb.main.id
  port              = "80"
  protocol          = "HTTP"

  default_action {
    target_group_arn = aws_alb_target_group.target_group.id
    type             = "forward"
  }
}

#############   RDS - Aurora config   ############

# Subnet group
resource "aws_db_subnet_group" "aurora_db_subnet" {
  name       = "nj_rdb_subnet"
  subnet_ids = local.subnet_ids_rds_list
}

# RDS Security group - allow only ECS Fargate tasks
resource "aws_security_group" "rds_sg" {
  name   = "nj-rds-sg"
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
        "${aws_security_group.ecs_tasks_sg.id}"
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

resource "aws_rds_cluster" "rds_cluster" {
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
  
  vpc_security_group_ids     = [
    "${aws_security_group.rds_sg.id}" 
  ]

  scaling_configuration {
    min_capacity             = "2"
    max_capacity             = "2"
    auto_pause               = "true"
    seconds_until_auto_pause = "300"
  }
}

########    ECS Cluster - Fargate config   ##########

resource "aws_ecs_cluster" "main" {
  name = "nj-ecs-cluster"
}

# IAM role for ecs-task api 
resource "aws_iam_role" "ecs_task_execution_role" {
  name = "nj-ecs-task-execution-role"

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

# Attach ECS task execution policy to IAM role
resource "aws_iam_role_policy_attachment" "attach-policy" {
    role       = aws_iam_role.ecs_task_execution_role.name
    policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Traffic to the ECS Cluster should only come from the ALB
resource "aws_security_group" "ecs_tasks_sg" {
  name        = "nj-ecs-tasks-sg"
  description = "Allow inbound access from the ALB only"
  vpc_id      = aws_vpc.main.id

  ingress {
    protocol        = "tcp"
    from_port       = var.app_port
    to_port         = var.app_port
    security_groups = [
      aws_security_group.alb.id
    ]
  }

  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = [
      "0.0.0.0/0"
    ]
  }
}

# CloudWatch log for ECS
resource "aws_cloudwatch_log_group" "ecs_log_group" {
  name = "/ecs/nj-ecs-console"
}


# ECS task definition
resource "aws_ecs_task_definition" "ecs_task" {
  family                   = "nj-app"
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
    ],
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-group": "${aws_cloudwatch_log_group.ecs_log_group.name}",
        "awslogs-region": "${var.aws_region}",
        "awslogs-stream-prefix": "ecs"
      }
    }
  }
]
DEFINITION

  depends_on = [module.ecr_docker_build]
}

# ECS service config
resource "aws_ecs_service" "main" {
  name            = "nj-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.ecs_task.id
  desired_count   = var.app_count
  launch_type     = "FARGATE"

  network_configuration {
    security_groups = [
      aws_security_group.ecs_tasks_sg.id
    ]
    subnets         = local.subnet_ids_ecs_list
  }

  load_balancer {
    target_group_arn = aws_alb_target_group.target_group.id
    container_name   = "notejam-app"
    container_port   = var.app_port
  }

  depends_on = [
    aws_ecs_cluster.main
  ]
}