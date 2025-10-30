# main.tf - WordPress on Docker (EC2 + ASG)

# 1. CONFIGURE THE AWS PROVIDER
provider "aws" {
  region = "ap-south-1" # Mumbai
}

# Generate a strong random password for the database
resource "random_password" "db_password" {
  length           = 16
  special          = true
  override_special = "!#%&*()-_=+<>:?" # Shell-safe
}

# -----------------------------------------------------
# SECTION 2: NETWORKING DATA SOURCES
# -----------------------------------------------------
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# -----------------------------------------------------
# SECTION 3: AMI DATA SOURCE
# -----------------------------------------------------
# Find the latest STANDARD Amazon Linux 2023 AMI
data "aws_ssm_parameter" "standard_al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# -----------------------------------------------------
# SECTION 4: SECURITY GROUPS (FIREWALLS)
# -----------------------------------------------------
# Security group for the Load Balancer
resource "aws_security_group" "alb_sg" {
  name        = "wp-docker-alb-sg"
  vpc_id      = data.aws_vpc.default.id
  description = "Allow HTTP traffic from anywhere"
  ingress {
    protocol    = "tcp"
    from_port   = 80
    to_port     = 80
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Security group for the EC2 instances
resource "aws_security_group" "web_server_sg" {
  name        = "wp-docker-ec2-sg"
  vpc_id      = data.aws_vpc.default.id
  description = "Allow HTTP from ALB and SSH/SSM"

  # Allow HTTP (port 80) from the Load Balancer
  ingress {
    protocol        = "tcp"
    from_port       = 80
    to_port         = 80
    security_groups = [aws_security_group.alb_sg.id]
  }

  # Allow all outbound traffic (for yum, docker pull, etc.)
  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Security Group for RDS Database
resource "aws_security_group" "db_sg" {
  name        = "wp-docker-db-sg"
  vpc_id      = data.aws_vpc.default.id
  description = "Allow DB connections from EC2 instances"
  ingress {
    protocol        = "tcp"
    from_port       = 3306 # MySQL port
    to_port         = 3306
    security_groups = [aws_security_group.web_server_sg.id] # Allow from our EC2 instances
  }
  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# -----------------------------------------------------
# SECTION 5: RDS DATABASE
# -----------------------------------------------------
# DB Subnet Group
resource "aws_db_subnet_group" "default" {
  name       = "wp-docker-db-subnet-group"
  subnet_ids = data.aws_subnets.default.ids
}

# RDS Database Instance
resource "aws_db_instance" "wordpress_db" {
  allocated_storage      = 20
  engine                 = "mysql"
  engine_version         = "8.0"
  instance_class         = "db.t3.micro"
  db_name                = "wordpressdb"
  username               = "wpadmin"
  password               = random_password.db_password.result
  vpc_security_group_ids = [aws_security_group.db_sg.id]
  db_subnet_group_name   = aws_db_subnet_group.default.name
  multi_az               = false
  skip_final_snapshot    = true
  publicly_accessible    = false
}

# -----------------------------------------------------
# SECTION 6: SECRETS MANAGER
# -----------------------------------------------------
resource "aws_secretsmanager_secret" "db_credentials" {
  name_prefix = "WordPressDockerDBSecrets-"
}

resource "aws_secretsmanager_secret_version" "db_credentials_values" {
  secret_id = aws_secretsmanager_secret.db_credentials.id
  secret_string = jsonencode({
    DB_HOST     = aws_db_instance.wordpress_db.endpoint
    DB_USER     = aws_db_instance.wordpress_db.username
    DB_PASSWORD = random_password.db_password.result
    DB_NAME     = aws_db_instance.wordpress_db.db_name
  })
}

# -----------------------------------------------------
# SECTION 7: IAM ROLE FOR EC2 INSTANCES
# -----------------------------------------------------
# IAM policy to allow reading the specific secret and describing tags
resource "aws_iam_policy" "ec2_policy" {
  name        = "WordPressEC2Policy"
  description = "Allows EC2 to read DB secret and describe its own tags"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect   = "Allow",
        Action   = "secretsmanager:GetSecretValue",
        Resource = aws_secretsmanager_secret.db_credentials.arn
      },
      {
        Effect   = "Allow",
        Action   = "ec2:DescribeTags",
        Resource = "*" # Required to allow instance to read its own tags
      }
    ]
  })
}

# IAM Role for EC2 instances
resource "aws_iam_role" "ec2_instance_role" {
  name = "WordPressEC2InstanceRole"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action    = "sts:AssumeRole",
        Effect    = "Allow",
        Principal = { Service = "ec2.amazonaws.com" }
      }
    ]
  })
}

# Attach policy for SSM (Session Manager debugging)
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2_instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Attach our custom policy for reading secrets and tags
resource "aws_iam_role_policy_attachment" "custom" {
  role       = aws_iam_role.ec2_instance_role.name
  policy_arn = aws_iam_policy.ec2_policy.arn
}

# Instance Profile to attach role to EC2
resource "aws_iam_instance_profile" "ec2_instance_profile" {
  name = "WordPressEC2InstanceProfile"
  role = aws_iam_role.ec2_instance_role.name
}

# -----------------------------------------------------
# SECTION 8: APPLICATION LOAD BALANCER (ALB)
# -----------------------------------------------------
resource "aws_lb" "app_lb" {
  name               = "wp-docker-lb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = data.aws_subnets.default.ids
}

resource "aws_lb_target_group" "app_tg" {
  name        = "wp-docker-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.default.id
  target_type = "instance"

  health_check {
    enabled             = true
    path                = "/license.txt" # Static file from WordPress
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app_lb.arn
  port              = "80"
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app_tg.arn
  }
}

# -----------------------------------------------------
# SECTION 9: EC2 LAUNCH TEMPLATE & AUTO SCALING GROUP
# -----------------------------------------------------
resource "aws_launch_template" "web_server_lt" {
  name_prefix   = "wp-docker-lt-"
  image_id      = data.aws_ssm_parameter.standard_al2023_ami.value
  instance_type = "t3.small"

  iam_instance_profile {
    name = aws_iam_instance_profile.ec2_instance_profile.name
  }

  vpc_security_group_ids = [aws_security_group.web_server_sg.id]

  # This now uses templatefile() to render the script and inject the secret ARN
  user_data = base64encode(templatefile("setup-docker-wp.sh", {
    db_secret_arn_placeholder = aws_secretsmanager_secret.db_credentials.arn
  }))

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "WordPress-Docker-Instance"
    }
  }
}

resource "aws_autoscaling_group" "web_asg" {
  name                = "wp-docker-asg"
  vpc_zone_identifier = data.aws_subnets.default.ids

  desired_capacity          = 1
  max_size                  = 3
  min_size                  = 1
  health_check_type         = "ELB" # Use the ALB's health check
  health_check_grace_period = 300   # Give Docker time to start

  target_group_arns = [aws_lb_target_group.app_tg.arn]

  launch_template {
    id      = aws_launch_template.web_server_lt.id
    version = "$Latest"
  }

  # --- THIS IS THE FIX ---
  # This forces Terraform to wait until the DB is available
  # and the secret is created *before* creating the ASG.
  depends_on = [
    aws_secretsmanager_secret_version.db_credentials_values
  ]
  # --- END OF FIX ---
}

# -----------------------------------------------------
# SECTION 10: OUTPUTS
# -----------------------------------------------------
output "load_balancer_dns" {
  description = "The DNS name of the Application Load Balancer"
  value       = aws_lb.app_lb.dns_name
}
