resource "aws_security_group" "this" {
  name        = "${var.instance_name_prefix}-sg"
  description = "Security group for the ${var.instance_name_prefix} hostgroup"
  vpc_id      = var.vpc_id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_allowed_cidr]
  }

  ingress {
    description = "Instance port"
    from_port   = var.instance_port
    to_port     = var.instance_port
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
    Name        = "${var.instance_name_prefix}-sg"
    environment = var.environment
  }
}

resource "aws_instance" "this" {
  count = var.instance_amount

  ami                    = var.instance_ami
  instance_type          = var.instance_type
  subnet_id              = var.instance_subnet_id
  key_name               = var.instance_key_name
  vpc_security_group_ids = [aws_security_group.this.id]

  user_data = templatefile("${path.module}/userdata.sh.tpl", var.userdata_vars)

  root_block_device {
    volume_size = var.instance_root_block_device_volume_size
  }

  tags = {
    Name        = "${var.instance_name_prefix}-instance-${count.index}"
    hostgroup   = var.instance_name_prefix
    environment = var.environment
  }
}
