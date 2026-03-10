# ── Latest Amazon Linux 2023 AMI ─────────────────────────────────────────────
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ── Key Pair ──────────────────────────────────────────────────────────────────
resource "aws_key_pair" "deployer" {
  key_name   = "${var.project_name}-${var.environment}-key"
  public_key = var.ec2_public_key
}

# ── Security Group for EC2 ────────────────────────────────────────────────────
resource "aws_security_group" "ec2" {
  name        = "${var.project_name}-${var.environment}-ec2-sg"
  description = "EC2 app server: ALB + SSH access"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "App port from ALB only"
    from_port       = var.container_port
    to_port         = var.container_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  ingress {
    description = "SSH"
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

  tags = { Name = "${var.project_name}-${var.environment}-ec2-sg" }
}

# IAM Role for EC2 
resource "aws_iam_role" "ec2" {
  name = "${var.project_name}-${var.environment}-ec2-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.project_name}-${var.environment}-ec2-profile"
  role = aws_iam_role.ec2.name
}

# EC2 User Data – installs Docker, runs Redis,app containers
locals {
  user_data = <<-EOF
    #!/bin/bash
    set -euxo pipefail

    #  System updates & Docker 
    dnf update -y
    dnf install -y docker aws-cli jq
    systemctl enable --now docker
    usermod -aG docker ec2-user

    # Docker Compose v2 plugin
    mkdir -p /usr/local/lib/docker/cli-plugins
    curl -SL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64 \
      -o /usr/local/lib/docker/cli-plugins/docker-compose
    chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

    #  Write compose file
    mkdir -p /opt/app
    cat > /opt/app/docker-compose.yml <<COMPOSE
    version: "3.9"

    networks:
      app-net:
        driver: bridge

    volumes:
      redis-data:

    services:
      redis:
        image: redis:7-alpine
        restart: unless-stopped
        command: >
          redis-server
          --appendonly yes
          --appendfsync everysec
          --maxmemory 128mb
          --maxmemory-policy allkeys-lru
        volumes:
          - redis-data:/data
        networks:
          - app-net
        healthcheck:
          test: ["CMD", "redis-cli", "ping"]
          interval: 10s
          timeout: 5s
          retries: 5
          start_period: 5s

      app:
        image: ${var.container_image}
        restart: unless-stopped
        ports:
          - "${var.container_port}:${var.container_port}"
        environment:
          NODE_ENV:    ${var.environment}
          PORT:        ${var.container_port}
          REDIS_URL:   redis://redis:6379
          APP_VERSION: terraform-managed
        depends_on:
          redis:
            condition: service_healthy
        networks:
          - app-net
        healthcheck:
          test: ["CMD-SHELL", "wget -qO- http://localhost:${var.container_port}/health || exit 1"]
          interval: 30s
          timeout: 5s
          retries: 3
          start_period: 15s
    COMPOSE

    # Start the stack 
    cd /opt/app
    docker compose pull
    docker compose up -d

    # Systemd unit so stack restarts after reboot 
    cat > /etc/systemd/system/app-stack.service <<UNIT
    [Unit]
    Description=App Docker Compose Stack
    Requires=docker.service
    After=docker.service network-online.target

    [Service]
    Type=oneshot
    RemainAfterExit=yes
    WorkingDirectory=/opt/app
    ExecStart=/usr/local/lib/docker/cli-plugins/docker-compose up -d
    ExecStop=/usr/local/lib/docker/cli-plugins/docker-compose down
    TimeoutStartSec=120

    [Install]
    WantedBy=multi-user.target
    UNIT

    systemctl daemon-reload
    systemctl enable app-stack
  EOF
}

# EC2 Instance
resource "aws_instance" "app" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.ec2_instance_type
  key_name               = aws_key_pair.deployer.key_name
  subnet_id              = aws_subnet.public[0].id
  vpc_security_group_ids = [aws_security_group.ec2.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2.name

  user_data                   = base64encode(local.user_data)
  user_data_replace_on_change = true

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 30
    encrypted             = true
    delete_on_termination = true
  }

  # IMDSv2 enforced
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  tags = { Name = "${var.project_name}-${var.environment}-server" }
}

# ALB Target Group attachment
resource "aws_lb_target_group_attachment" "app_blue" {
  target_group_arn = aws_lb_target_group.blue.arn
  target_id        = aws_instance.app.id
  port             = var.container_port
}

# Elastic IP 
resource "aws_eip" "app" {
  instance = aws_instance.app.id
  domain   = "vpc"
  tags     = { Name = "${var.project_name}-${var.environment}-eip" }
}
