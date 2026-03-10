# ── Application Load Balancer ─────────────────────────────────────────────────
resource "aws_lb" "main" {
  name               = "${var.project_name}-${var.environment}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  enable_deletion_protection = false

  tags = { Name = "${var.project_name}-${var.environment}-alb" }
}

# ── Target Groups (blue + green for zero-downtime deploys) ────────────────────
resource "aws_lb_target_group" "blue" {
  name        = "${var.project_name}-${var.environment}-blue"
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"

  health_check {
    path                = "/health"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200"
  }

  deregistration_delay = 30

  tags = { Name = "${var.project_name}-${var.environment}-blue-tg" }
}

resource "aws_lb_target_group" "green" {
  name        = "${var.project_name}-${var.environment}-green"
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"

  health_check {
    path                = "/health"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200"
  }

  deregistration_delay = 30

  tags = { Name = "${var.project_name}-${var.environment}-green-tg" }
}

# ── HTTP Listener (port 80 → forwards to blue target group) ──────────────────
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.blue.arn
  }

  lifecycle { ignore_changes = [default_action] }
}

#  Outputs
output "alb_dns_name"  { value = aws_lb.main.dns_name }
output "app_url"       { value = "http://${aws_lb.main.dns_name}" }
output "blue_tg_arn"   { value = aws_lb_target_group.blue.arn }
output "green_tg_arn"  { value = aws_lb_target_group.green.arn }
output "http_listener_arn" { value = aws_lb_listener.http.arn }
