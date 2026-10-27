output "instance_id" {
  description = "ID of the EC2 instance"
  value       = aws_instance.data_processor.id
}

output "public_ip" {
  description = "Public IP address of the server"
  value       = aws_instance.data_processor.public_ip
}

output "public_dns" {
  description = "Public DNS name of the server"
  value       = aws_instance.data_processor.public_dns
}

output "application_url" {
  description = "Data Processor application URL"
  value       = "http://${aws_instance.data_processor.public_ip}:8080"
}

output "ssh_command" {
  description = "SSH command template for connecting to the server"
  value       = "ssh -i <PATH_TO_PRIVATE_KEY> ubuntu@${aws_instance.data_processor.public_ip}"
}