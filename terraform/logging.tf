# ── CloudWatch Log Group ──────────────────────────────────────────────────────
# Docker on EC2 ships logs here via the awslogs driver (configured in compose)
resource "aws_cloudwatch_log_group" "app" {
  name              = "/${var.project_name}/${var.environment}/app"
  retention_in_days = 30
}

#  Allow EC2 role to write logs 
resource "aws_iam_role_policy" "ec2_cloudwatch" {
  name = "cloudwatch-logs"
  role = aws_iam_role.ec2.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogStreams"
      ]
      Resource = "${aws_cloudwatch_log_group.app.arn}:*"
    }]
  })
}

output "cloudwatch_log_group" { value = aws_cloudwatch_log_group.app.name }
