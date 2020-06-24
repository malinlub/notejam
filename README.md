Assignment
-

![](/docs/notejam-assignment.png)

Business Requirements
-
- The Application must serve variable amount of traffic. Most users are active during business hours. During big
events and conferences the traffic could be 4 times more than typical.
- The Customer takes guarantee to preserve your notes up to 3 years and recover it if needed.
- The Customer ensures continuity in service in case of datacenter failures.
- The Service must be capable of being migrated to any regions supported by the cloud provider in case of
emergency.
- The Customer is planning to have more than 100 developers to work in this project who want to roll out multiple
deployments a day without interruption / downtime.
- The Customer wants to provision separated environments to support their development process for development,
testing, production in the near future.
- The Customer wants to see relevant metrics and logs from the infrastructure for quality assurance and security
purposes.

Architecture decisions:
-
- Split monolith to multi-layer architecture where isolated/decoupled components/tiers can be managed by different teams of specialists and secured from public access and another network parts. ALB(internet facing) -> ECS(private subnet) -> RDS(private subnet)
- Due to variable amount of traffic, chosen serverless components with autoscale options for Web app and DB tier for spreading perf load and dont waste idle resources. ECS(Fargate), RDS Cluster(Aurora serverless)
- Build High available solution for service continuity. Minimum 2 loadbalanced Availability zones. ALB(application lb), Private subnet per each service per AZ.
- Application in CI/CD pipeline dockerized and DB backup for migration DR scenarios.
- IaC configurable to use also for Development environments.
- Central logging of seervices in CloudWatch logs.

Notes: 
- Due to short time, missing CI/CD Pipeline terraform build. 
(Tricky mini CI/CD for Dockerfile generation + local Docker build then Push docker image to ECR executed during building of AWS infrastructure)
- TODO: Generalize variables more in terraform, separate components for better readibility. 

Notejam Django app built on Amazon Web Services
=
Getting started
=
Build AWS infrastructure:
-    
- `cd notejam/terraform` 
- `terraform init`
- `terraform plan` (see building resources)
- `terraform apply`

Prerequisites:
-
- Install [terraform](https://learn.hashicorp.com/terraform/getting-started/install.html) 
- Install [aws cli](https://aws.amazon.com/cli/)
- Configure your aws profile by running `aws configure`
- Change variables.tf file with required values
- Install Docker machine - this PoC use local docker build based on generated Dockerfile

Proof of Concept solution
=
Web URL
==
- Web site url: You will see whole path in terraform output console

- Example: alb_hostname = http://nj-lb-1017956091.us-west-2.elb.amazonaws.com

Source code:
-
- Github: https://github.com/malinlub/notejam

- IaC solution is provisioned on AWS. 
- CI/CD partialy hacked by local Docker build and push to ECR by terraform

- TODO: Create CI/CD solution as described architecture design. Terraform should be used as IaC tool. 



Infrastructure
==
![](/docs/notejam-infrastructure.png)

Network
--
- VPC per environment
- x subnets (configurable in variables - different AZs) for every service (ECS, RDS, ALB, NatGW)
- all services are in private subnets except public facing services (ALB, NatGW)
- security groups

Application
--
- ECS
    - Django application is running in a containerized environment on AWS ECS in Fargate mode
    - Port 8000 exposed only to ALB
    - ECS allows connection only from ALB

    - TODO: Make Autoscaling rules (currently 2 desired Tasks)
    
- ALB
    - Application load balancer in front of the ECS 
    - ALB listener expose port 80 to the public
    - HTTP forward 80 -> configured on ALB

- RDS
    - RDS engine Aurora in Serverless engine mode
    - 3306 port exposed only to ECS Fargate tasks
    - Autoscaling configuration hardcoded (TODO: add to variables for configuration, currently min:2, max:2, autopause:true)
    - Backup disable for PoC
    - Storage encryption disabled for PoC

- Route53
    - for PoC not created (access to Website via exposed ALB DNS)

Logging and monitoring
--
- RDS and ECS stream log into central CloudWatch log groups
    
CI/CD Pipeline
==
![](/docs/notejam-cicd.png)

- AWS CodePipeline is used as a CI/CD tool.
- TODO: create CI/CD by terraform

Suggested CI/CD Pipeline:
--
STAGE "SRC":
---
- When new code is pushed to GitHub/CodeCommit repository CodePipeline trigger next stages

STAGE "BUILD":
---
- Dockerize app, build Docker image and upload to ECR
- If DB needs update, perform DB update
- Deploy Docker image to ECS "BUILD" environment
- Run Unit tests

STAGE "STAGING":
---
- Deploy Docker image to ECS "STAGING" environment
- Run another tests (Integration, UI, Smoke, Performance, ...) 

STAGE "PRODUCTION":
---
- Managed manual trigger of Deployment to "PROD" environment
- Deploy Docker image to ECS "PROD" environment (rolling update)

Folder structure
=
- Infrastructure as Code : `terraform/`
- Django application: `notejam/`

Test sonarcloud
