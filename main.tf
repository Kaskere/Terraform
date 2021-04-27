


terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3.0"
    }
  }
}
provider "aws" {
  profile = "default"
  region  = "us-east-2"
}
#DATA

# Search for latest Ubuntu server image
data "aws_ami" "ubuntu_latest" {
  most_recent = true
  owners      = ["099720109477"] # Canonical Images

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-*-*.*-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Search for instance type
data "aws_ec2_instance_type_offering" "ubuntu_micro" {
  filter {
    name   = "instance-type"
    values = ["t2.micro"]
  }
}


# Availability zones data source to get list of AWS Availability zones
data "aws_availability_zones" "available" {
  state = "available"
}

#NETWORKING


# VPC
resource "aws_vpc" "vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags = {
    Project = "nginx via terraform"
    Department = "CnA"
  }

}

# Internet Gatewway
resource "aws_internet_gateway" "internet_gateway" {
  vpc_id = aws_vpc.vpc.id
  tags = {
    Project = "nginx via terraform"
    Department = "CnA"
  }
}

# Subnet in first available availability zones
resource "aws_subnet" "first_subnet" {
  cidr_block              = aws_vpc.vpc.cidr_block
  vpc_id                  = aws_vpc.vpc.id
  availability_zone       = data.aws_availability_zones.available.names[1]
  map_public_ip_on_launch = true
  tags = {
    Project = "nginx via terraform"
    Department = "CnA"
  }
}

# Route table
resource "aws_route_table" "route_table" {
  vpc_id = aws_vpc.vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.internet_gateway.id
  }
  tags = {
    Project = "nginx via terraform"
    Department = "CnA"
  }
}

# Subnets to route table
resource "aws_route_table_association" "ps_assoc_1" {
  subnet_id      = aws_subnet.first_subnet.id
  route_table_id = aws_route_table.route_table.id
}

#SERVER CONFIGURATION - DO NOT SKIP

# Server configuration template
resource "aws_launch_configuration" "server_configuration" {
  image_id        = data.aws_ami.ubuntu_latest.id
  instance_type   = data.aws_ec2_instance_type_offering.ubuntu_micro.id
  key_name        = "140321"
  security_groups = [aws_security_group.ec2_instance_security_group.id]

  user_data = <<-EOF
                  #!/bin/bash
                  sudo su
                  sudo apt-get install -y apache2
                  sudo systemctl enable apache2
                  sudo systemctl start apache2
                  echo "Server IP is: $(curl http://169.254.169.254/latest/meta-data/public-ipv4)" > /var/www/html/index.html
                  sudo systemctl restart apache2
                  EOF

  lifecycle {
    create_before_destroy = true
  }
}

#SECURITY GROUPS - PORT 22 FOR SSH; 80- LOCALSERVER; THE INSTANCE MUST BE CREATED WITH BOTH IP AND IP DNS;
#cidr_blocks = ["0.0.0.0/0"] - ALLOWING ACCESS

# Security group for ec2 instances
resource "aws_security_group" "ec2_instance_security_group" {
  description = "Allow inbound HTTP traffic"
  vpc_id      = aws_vpc.vpc.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = {
    Project = "nginx via terraform"
    Department = "CnA"
  }
}

# Security group for ELB to allow HTTP traffic
resource "aws_security_group" "load_balancer_http_traffic" {
  name        = "elb_http"
  description = "Allow HTTP traffic to ec2 instances trought ELB"
  vpc_id      = aws_vpc.vpc.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = {
    Project = "nginx via terraform"
    Department = "CnA"
  }
}
#resource name with ami free tier image (this one for Ohio, us-east-2)
resource "aws_instance" "terraform" {
  ami = "ami-089c6f2e3866f0f14"
  instance_type = "t2.micro"
  key_name = "140321"


  tags = {
    Name = "terraform"
    Project = "nginx via terraform"
        Department = "CnA"
  }
}

#Elastic load balancing

# Create Load Balancer
resource "aws_elb" "load_balancer" {
  security_groups = [aws_security_group.load_balancer_http_traffic.id]
  subnets = [
    aws_subnet.first_subnet.id,
  ]
  cross_zone_load_balancing = true

  health_check {
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 2
    target              = "HTTP:80/"
    interval            = 30
  }

  listener {
    instance_port     = "80"
    instance_protocol = "http"
    lb_port           = 80
    lb_protocol       = "http"
  }
  tags = {
    Project = "nginx via terraform"
    Department = "CnA"
  }
}

#Autoscaling

# Green blue autoscaling group
resource "aws_autoscaling_group" "gren_blue_environment_servers" {
  launch_configuration = aws_launch_configuration.server_configuration.name
  vpc_zone_identifier  = [aws_subnet.first_subnet.id]



  min_size         = 1
  desired_capacity = 2
  max_size         = 4

  health_check_type = "ELB"
  load_balancers    = [aws_elb.load_balancer.id]

  tag {
    key                 = "Autoscaling Group 1"
    value               = "Autoscaling Group 1 for training purposes"
    propagate_at_launch = true
  }

  enabled_metrics = [
    "GroupMinSize",
    "GroupMaxSize",
    "GroupDesiredCapacity",
    "GroupInServiceInstances",
    "GroupTotalInstances"
  ]
  metrics_granularity = "1Minute"

  lifecycle {
    create_before_destroy = true
  }
}

#outputs

output "elb_dns_name" {
  value = aws_elb.load_balancer.dns_name
}

output "server_ami" {
  value = data.aws_ami.ubuntu_latest.id
}

output "vpc_id" {
  value = aws_vpc.vpc.id
}


# Generate inventory file for Ansible
resource "local_file" "inventory" {
 filename = "inventory.tmpl"
 content = <<EOF
[webserver]
dns = ${aws_elb.load_balancer.dns_name}
ip = ${aws_instance.terraform.public_ip}
id = ${aws_vpc.vpc.id}
EOF
}
