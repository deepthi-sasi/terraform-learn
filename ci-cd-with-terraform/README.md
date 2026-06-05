# Complete CI/CD Pipeline with Terraform

## Overview

This project integrates Terraform infrastructure provisioning into a complete CI/CD pipeline. Rather than deploying to a pre-existing server, the pipeline automatically provisions a fresh EC2 instance on each run before deploying the application.

## Technologies

- Terraform
- Jenkins
- Docker & Docker Compose
- Docker Hub
- AWS (EC2, VPC)
- Java / Maven
- Git
- Linux

## Pipeline Stages

| Stage | Type | Description |
|-------|------|-------------|
| Build artifact | CI | Compiles the Java Maven application |
| Build & push Docker image | CI | Builds the image and pushes it to Docker Hub |
| Provision server | CD | Provisions a new EC2 instance using Terraform |
| Deploy application | CD | Deploys the app to the provisioned instance via Docker Compose |

---

## Setup

### 1. Create an SSH Key Pair

**On AWS:**

1. Go to **EC2 → Key Pairs → Create key pair**
2. Name: `myapp-key-pair`, Type: `ED25519`, Format: `.pem`
3. Download the `.pem` file — the public key is stored in AWS automatically

**Store the private key on Jenkins:**

```bash
mv ~/Downloads/myapp-key-pair.pem ~/.ssh/
pbcopy < ~/.ssh/myapp-key-pair.pem
```

In Jenkins, navigate to:
**Dashboard → devops-bootcamp-multibranch-pipeline → Credentials → Global credentials → Add Credentials**

- Kind: `SSH Username with private key`
- ID: `server-ssh-key`
- Username: `ec2-user`
- Private key: paste from clipboard

---

### 2. Install Terraform Inside the Jenkins Container

```bash
# SSH into the Droplet running Jenkins
ssh root@<your-droplet-ip>

# Get the Jenkins container ID
docker ps

# Enter the Jenkins container as root
docker exec -it -u 0 <container-id> bash

# Install prerequisites
apt-get update && apt-get install -y gnupg software-properties-common wget

# Add HashiCorp GPG key
wget -O- https://apt.releases.hashicorp.com/gpg | \
  gpg --dearmor | \
  tee /usr/share/keyrings/hashicorp-archive-keyring.gpg

# Add HashiCorp repository
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
  https://apt.releases.hashicorp.com $(lsb_release -cs) main" | \
  tee /etc/apt/sources.list.d/hashicorp.list

# Install Terraform
apt update && apt-get install terraform

# Verify
terraform -v
```

---

### 3. Terraform Configuration

Create a `terraform/` folder in your project repository containing the following files.

**`terraform/main.tf`** — provisions VPC, subnet, security group, and EC2 instance:

```hcl
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "4.67.0"
    }
  }
}

provider "aws" {
  region = var.region
}

resource "aws_vpc" "myapp-vpc" {
  cidr_block = var.vpc_cidr_block
  tags = { Name = "${var.env_prefix}-vpc" }
}

resource "aws_subnet" "myapp-subnet-1" {
  vpc_id            = aws_vpc.myapp-vpc.id
  cidr_block        = var.subnet_cidr_block
  availability_zone = var.avail_zone
  tags = { Name = "${var.env_prefix}-subnet-1" }
}

resource "aws_internet_gateway" "myapp-igw" {
  vpc_id = aws_vpc.myapp-vpc.id
  tags   = { Name = "${var.env_prefix}-igw" }
}

resource "aws_default_route_table" "main-rtb" {
  default_route_table_id = aws_vpc.myapp-vpc.default_route_table_id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.myapp-igw.id
  }
  tags = { Name = "${var.env_prefix}-main-rtb" }
}

resource "aws_default_security_group" "default-sg" {
  vpc_id = aws_vpc.myapp-vpc.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.my_ip, var.jenkins_ip]
  }

  ingress {
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port       = 0
    to_port         = 0
    protocol        = "-1"
    cidr_blocks     = ["0.0.0.0/0"]
    prefix_list_ids = []
  }

  tags = { Name = "${var.env_prefix}-default-sg" }
}

data "aws_ami" "latest-amazon-linux-image" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["amzn2-ami-kernel-5.10-hvm-*-x86_64-gp2"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_instance" "myapp-server" {
  ami                         = data.aws_ami.latest-amazon-linux-image.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.myapp-subnet-1.id
  vpc_security_group_ids      = [aws_default_security_group.default-sg.id]
  availability_zone           = var.avail_zone
  associate_public_ip_address = true
  key_name                    = "myapp-key-pair"
  user_data                   = file("entry-script.sh")
  tags = { Name = "${var.env_prefix}-server" }
}

output "ec2_public_ip" {
  value = aws_instance.myapp-server.public_ip
}
```

**`terraform/variables.tf`** — default values used when no `tfvars` file is present:

```hcl
variable env_prefix      { default = "dev" }
variable region          { default = "eu-central-1" }
variable avail_zone      { default = "eu-central-1a" }
variable vpc_cidr_block  { default = "10.0.0.0/16" }
variable subnet_cidr_block { default = "10.0.10.0/24" }
variable my_ip           { default = "31.10.152.229/32" }
variable jenkins_ip      { default = "64.225.104.226/32" }
variable instance_type   { default = "t2.micro" }
```

> Jenkins can override any variable by setting an environment variable in the form `TF_VAR_<variable_name>`.

**`terraform/entry-script.sh`** — bootstraps Docker and Docker Compose on the EC2 instance:

```bash
#!/bin/bash
sudo yum update -y && sudo yum install -y docker
sudo systemctl start docker
sudo usermod -aG docker ec2-user

sudo curl -L "https://github.com/docker/compose/releases/download/v2.18.1/docker-compose-$(uname -s)-$(uname -m)" \
  -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose
```

---

### 4. Jenkinsfile Configuration

#### Provision Server stage

Add this stage after the Docker image build step. AWS credentials are injected from Jenkins credentials store; `TF_VAR_env_prefix` overrides the default variable value.

```groovy
stage('Provision Server') {
    environment {
        AWS_ACCESS_KEY_ID     = credentials('jenkins-aws_access_key_id')
        AWS_SECRET_ACCESS_KEY = credentials('jenkins-aws_secret_access_key')
        TF_VAR_env_prefix     = 'test'
    }
    steps {
        script {
            dir('terraform') {
                sh "terraform init"
                sh "terraform apply --auto-approve"
                EC2_PUBLIC_IP = sh(
                    script: "terraform output ec2_public_ip",
                    returnStdout: true
                ).trim()
            }
        }
    }
}
```

The EC2 public IP is captured from `terraform output` and passed to the deploy stage.

#### Deploy Application stage

```groovy
stage('Deploy Application') {
    environment {
        DOCKER_CREDS = credentials('DockerHub')
    }
    steps {
        script {
            echo "waiting for EC2 server to initialize"
            sleep(time: 90, unit: "SECONDS")

            def shellCmd   = "bash ./server-cmds.sh ${IMAGE_TAG} ${DOCKER_CREDS_USR} ${DOCKER_CREDS_PSW}"
            def ec2Instance = "ec2-user@${EC2_PUBLIC_IP}"

            sshagent(['server-ssh-key']) {
                sh "scp -o StrictHostKeyChecking=no server-cmds.sh docker-compose.yaml ${ec2Instance}:/home/ec2-user"
                sh "ssh -o StrictHostKeyChecking=no ${ec2Instance} ${shellCmd}"
            }
        }
    }
}
```

> **Note on the sleep:** The 90-second wait allows `entry-script.sh` to finish installing Docker Compose before the deploy stage runs. This only affects the first pipeline run — subsequent runs find the instance already initialised.

**`server-cmds.sh`** — runs on the EC2 instance to pull and start the container:

```bash
#!/usr/bin/env bash
export IMAGE_TAG=$1
export DOCKER_USER=$2
export DOCKER_PWD=$3
echo $DOCKER_PWD | docker login -u $DOCKER_USER --password-stdin
docker-compose -f docker-compose.yaml up -d
echo "successfully started the containers using docker-compose"
```

---

## Running the Pipeline

Push your changes to the feature branch:

```bash
git add .
git commit -m "Deploy on ec2 instance provisioned using terraform"
git push -u origin feature/sshagent-terraform
```

The Jenkins multibranch pipeline detects the new branch and triggers a build automatically.

After the build completes, verify the deployment:

```bash
chmod 400 ~/.ssh/myapp-key-pair.pem
ssh -i ~/.ssh/myapp-key-pair.pem ec2-user@<ec2-public-ip>
docker ps
```

Then open `http://<ec2-public-ip>:8000` in a browser to confirm the application is running.

---

## Security Notes

- SSH access on port 22 is restricted to your IP and the Jenkins server IP via the security group
- AWS credentials are stored as Jenkins credentials and injected at runtime — never hardcoded
- Docker Hub credentials are handled via Jenkins `credentials()` binding, which automatically creates `_USR` and `_PSW` environment variables
