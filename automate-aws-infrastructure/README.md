# Automate AWS Infrastructure with Terraform

## Overview

This project uses Terraform to automate provisioning of AWS infrastructure components — VPC, Subnet, Route Table, Internet Gateway, Security Group, and EC2 — and deploys a Docker container to the provisioned EC2 instance via a bootstrap script.

## Technologies

- Terraform
- AWS (VPC, EC2)
- Docker
- Linux
- Git

## Project Structure

```
terraform/
├── main.tf            # All resource definitions, variables, data sources, outputs
├── terraform.tfvars   # Variable values (not committed to version control)
└── entry-script.sh    # EC2 bootstrap script — installs Docker and runs nginx
```

---

## Part 1: Provision AWS Infrastructure

### Step 1 — Initialise the Terraform folder

```bash
mkdir terraform && cd terraform
```

---

### Step 2 — Create VPC and Subnet

**`terraform/main.tf`**

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
  region = "eu-central-1"
}

variable env_prefix {}
variable avail_zone {}
variable vpc_cidr_block {}
variable subnet_cidr_block {}

resource "aws_vpc" "myapp-vpc" {
  cidr_block = var.vpc_cidr_block
  tags = {
    Name = "${var.env_prefix}-vpc"
  }
}

resource "aws_subnet" "myapp-subnet-1" {
  vpc_id            = aws_vpc.myapp-vpc.id
  cidr_block        = var.subnet_cidr_block
  availability_zone = var.avail_zone
  tags = {
    Name = "${var.env_prefix}-subnet-1"
  }
}
```

**`terraform/terraform.tfvars`**

```hcl
env_prefix        = "dev"
avail_zone        = "eu-central-1a"
vpc_cidr_block    = "10.0.0.0/16"
subnet_cidr_block = "10.0.10.0/24"
```

```bash
terraform apply --auto-approve
# aws_vpc.myapp-vpc: Creation complete after 2s [id=vpc-09d8a5e6df029965c]
# aws_subnet.myapp-subnet-1: Creation complete after 0s [id=subnet-049b7bc24b07a9ca7]
# Apply complete! Resources: 2 added, 0 changed, 0 destroyed.
```

---

### Step 3 — Create Route Table and Internet Gateway

Add to **`terraform/main.tf`**:

```hcl
resource "aws_internet_gateway" "myapp-igw" {
  vpc_id = aws_vpc.myapp-vpc.id
  tags = {
    Name = "${var.env_prefix}-igw"
  }
}

resource "aws_default_route_table" "main-rtb" {
  default_route_table_id = aws_vpc.myapp-vpc.default_route_table_id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.myapp-igw.id
  }
  tags = {
    Name = "${var.env_prefix}-main-rtb"
  }
}
```

```bash
terraform apply --auto-approve
# Apply complete! Resources: 2 added, 0 changed, 0 destroyed.
```

---

### Step 4 — Create Security Group

Opens port 22 (SSH, restricted to your IP) and port 8080 (nginx, open to the internet).

Add `variable my_ip {}` to **`main.tf`** and `my_ip = "<your-ip>/32"` to **`terraform.tfvars`**, then add:

```hcl
resource "aws_default_security_group" "default-sg" {
  vpc_id = aws_vpc.myapp-vpc.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.my_ip]
  }

  ingress {
    from_port   = 8080
    to_port     = 8080
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

  tags = {
    Name = "${var.env_prefix}-default-sg"
  }
}
```

```bash
terraform apply --auto-approve
```

---

### Step 5 — Select AMI Dynamically

Rather than hardcoding an AMI ID, use a data source to always fetch the latest Amazon Linux 2 image:

```hcl
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

output "aws_ami_id" {
  value = data.aws_ami.latest-amazon-linux-image.id
}
```

---

### Step 6 — Create EC2 Instance

Add `variable instance_type {}` and `variable public_key_location {}` to **`main.tf`**, and the corresponding values to **`terraform.tfvars`**:

```hcl
instance_type       = "t2.micro"
public_key_location = "/Users/<your-user>/.ssh/id_ed25519.pub"
```

> If you don't have an SSH key pair yet, generate one with: `ssh-keygen -t ed25519`

Add the key pair resource and EC2 instance to **`main.tf`**:

```hcl
resource "aws_key_pair" "ssh-key" {
  key_name   = "server-key"
  public_key = file(var.public_key_location)
}

resource "aws_instance" "myapp-server" {
  ami                         = data.aws_ami.latest-amazon-linux-image.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.myapp-subnet-1.id
  vpc_security_group_ids      = [aws_default_security_group.default-sg.id]
  availability_zone           = var.avail_zone
  associate_public_ip_address = true
  key_name                    = aws_key_pair.ssh-key.key_name

  tags = {
    Name = "${var.env_prefix}-server"
  }
}

output "ec2_public_ip" {
  value = aws_instance.myapp-server.public_ip
}
```

```bash
terraform apply --auto-approve
# aws_instance.myapp-server: Creation complete after 22s [id=i-0b063121922c765b6]
# Outputs:
# aws_ami_id    = "ami-08e415170f52d1657"
# ec2_public_ip = "3.72.36.170"
```

#### SSH into the instance (optional)

Once the instance state shows **Running** in the AWS console:

```bash
ssh ec2-user@<ec2_public_ip>
```

---

## Part 2: Deploy Docker Container to EC2

### Step 1 — Create the bootstrap script

**`terraform/entry-script.sh`**

```bash
#!/bin/bash

# install and start docker
sudo yum update -y && sudo yum install -y docker
sudo systemctl start docker

# add ec2-user to docker group
sudo usermod -aG docker ec2-user

# run nginx container
docker run -p 8080:80 nginx
```

---

### Step 2 — Attach the script as EC2 user data

Add `user_data` inside the `aws_instance` resource in **`main.tf`**:

```hcl
resource "aws_instance" "myapp-server" {
  # ... existing attributes ...
  user_data = file("entry-script.sh")

  tags = {
    Name = "${var.env_prefix}-server"
  }
}
```

```bash
terraform apply --auto-approve
# Outputs:
# ec2_public_ip = "3.67.138.246"
```

Open `http://<ec2_public_ip>:8080` in a browser — you should see the nginx welcome page.

#### Verify the container is running

```bash
ssh ec2-user@<ec2_public_ip>
docker ps
# CONTAINER ID   IMAGE   COMMAND                  CREATED        STATUS        PORTS                                   NAMES
# 30eafbc1406c   nginx   "/docker-entrypoint.…"   4 seconds ago  Up 3 seconds  0.0.0.0:8080->80/tcp, :::8080->80/tcp   laughing_spence
```

---

## Complete Variable Reference

| Variable | Description | Example value |
|---|---|---|
| `env_prefix` | Environment tag prefix | `dev` |
| `avail_zone` | AWS availability zone | `eu-central-1a` |
| `vpc_cidr_block` | CIDR block for the VPC | `10.0.0.0/16` |
| `subnet_cidr_block` | CIDR block for the subnet | `10.0.10.0/24` |
| `my_ip` | Your IP for SSH access | `31.10.152.229/32` |
| `instance_type` | EC2 instance type | `t2.micro` |
| `public_key_location` | Path to your local public key | `/Users/<user>/.ssh/id_ed25519.pub` |

---

## Security Notes

- SSH access on port 22 is restricted to `var.my_ip` — update this whenever your IP changes
- Port 8080 is open to the world (`0.0.0.0/0`) for the nginx demo — restrict this in production
- Do not commit `terraform.tfvars` to version control if it contains sensitive values like your IP address or key paths
