output "application_url" {
  description = "Public HTTPS URL of the application"
  value       = "https://${var.app_subdomain}.${var.domain_name}"
}

output "alb_dns" {
  description = "ALB DNS name — use this to access your app"
  value       = aws_lb.main.dns_name
}

output "server_ip" {
  description = "Elastic IP of the EC2 instance"
  value       = aws_eip.app.public_ip
}

output "ssh_command" {
  description = "SSH command to access the server"
  value       = "ssh -i ~/.ssh/nodejs-app-key ec2-user@${aws_eip.app.public_ip}"
}

output "log_group" {
  description = "CloudWatch log group for application logs"
  value       = aws_cloudwatch_log_group.app.name
}
