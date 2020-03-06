# Notejam Django app @AWS

## Getting started

### Spin up the environment
    
1. `cd iac/`
2. `terraform workspace new _name_of_git_branch_` 
3. `terraform init`
4. `terraform apply`

Prerequisites:
- Install [terraform](https://learn.hashicorp.com/terraform/getting-started/install.html) >= v0.13 
- Install [aws cli](https://aws.amazon.com/cli/)
- Configure `notejam` aws profile by running `aws configure --profile notejam`
- Fill `iac/*.tfvars` files with desired values
- Acquire Gitlab token with code pull rights


# Solution

## Basic info
Web site url, e.g. for dev environment: https://dev.notejam.nedim.online

Source code:
- Toptal Gitlab: https://git.toptal.com/eluttner/nedim.laletovic
- Gitlab: https://gitlab.com/nediml/notejam
Note that the CodePipeline triggers are configured to work with the repository at Gitlab.com due to inability of configuring webhooks on Toptal Gitlab.

**Note**: Complete solution is provisioned on AWS, from CI/CD to the hosting of the actual app. Terraform is used as IaC tool. 



## Infrastructure
![](/docs/notejam-infra.png)


**Note**: **All important infrastructural settings are configurable via terraform variables (.tfvars files in iac/ directory)**. This allows customization per environment and enables cost savings due to the fact that provisioning of the resources is being done as per actual need.

### Network setup
- one VPC per environment
- two subnets (different AZ) for every service (ecs, rds, lb etc.)
- all services are in private subnets except public facing services (lb, natgw)
- security groups are configured keeping in mind least privilege concept

### Application hosting

- ECS
    - Django application is running in a containerized environment on AWS ECS in Fargate mode
    - Auto scaling configured (CPU metric)
    - Port 8000 exposed only to ALB
    
- ALB
    - Application load balancer is sitting in front of the ECS 
    - ALB listener expose ports 80 and 443 exposed to the public
    - Valid SSL certificate provisioned and SSL termination configured on ALB
    - HTTP to HTTPS redirect configured on ALB

- RDS
    - RDS Serverless is being used
    - mysql engine
    - 3306 port exposed only to ECS Fargate services
    - Autoscaling, both, of compute and storage configured
    - Backup configured
    - Storage encryption enabled

-  DNS
    - Public DNS zone configured: `nedim.online`
    - Depending on the environment dns records (subdomains) are being created automatically e.g. `dev.notejam.nedim.online`

### Logging and monitoring
- All services (ECS, RDS, CodePipeline, CodeBuild etc.) are pushing their logs to the centralized logging system (CloudWatch)
- Performance and health monitoring can be done via Dashboards of each service (e.g. ECS, ALB, RDS etc.)

    
## CI/CD Pipeline
![](/docs/notejam-cicd.png)

AWS CodePipeline is used as a CI/CD tool.
CI/CD pipeline is configured to run in case of the push event on a specific branch (e.g. dev, qa) of the GitLab repository. 

When new code is pushed to the repo Pipeline will first run Unit tests to perform validation, after which will build, dockerize and push the application to the ECR.

After successful build, database update is being performed.
In case DB update passed without errors application will be deployed to ECS (rolling update).

All build logs are pushed to the centralized logging system (CloudWatch).

Sensitive information is stored in SSM Parameter store as SecureString.

**Note**: Since CodePipeline does not natively support pulling the code from Gitlab, solution recommended by AWS was implemented: https://aws.amazon.com/quickstart/architecture/git-to-s3-using-webhooks/
This solutions is completely automated with Terraform/CloudFormation, no user input, other the token for accessing the Gitlab repository, is required.

## Repository layout
CI/CD related files: `cicd/`

IaC related files: `iac/`

Documentation and diagrams: `docs/`

Django application files that were modified:

- `django/requirements.txt` added gunicorn, mysqlclient etc.
- `django/notejam/notejam/settings.py` modified db config to support mysql
