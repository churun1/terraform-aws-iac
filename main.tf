# main.tf - WordPress + EASY Backend on Docker (EC2 + ASG) - FINAL VERSION

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

# Generate a random string to ensure the S3 bucket name is unique
resource "random_string" "bucket_suffix" {
  length  = 8
  special = false
  upper   = false
  numeric = true
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

  # Allow WordPress traffic (Port 80)
  ingress {
    protocol        = "tcp"
    from_port       = 80
    to_port         = 80
    security_groups = [aws_security_group.alb_sg.id]
  }

  # --- NEW: Allow EASY Backend traffic (Port 8080) ---
  ingress {
    protocol        = "tcp"
    from_port       = 8080
    to_port         = 8080
    security_groups = [aws_security_group.alb_sg.id]
  }
  # --- END NEW ---

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
    
    # Admin Credentials for Script
    WP_ADMIN_USER  = "sysops_deployer"
    WP_ADMIN_PASS  = "P@ssw0rd_Str0ng_2025!"
    WP_ADMIN_EMAIL = "deploy@gmail.com"
    
    # Placeholder for Bitbucket Key (You must add the value manually after apply!)
    BITBUCKET_SSH_KEY = "PLACEHOLDER_UPDATE_MANUALLY_IN_CONSOLE" 
  })
  
  # IMPORTANT: This prevents Terraform from overwriting your manual SSH key update
  lifecycle {
    ignore_changes = [secret_string]
  }
}

# -----------------------------------------------------
# SECTION 7: S3 BUCKET FOR UPLOADS
# -----------------------------------------------------
resource "aws_s3_bucket" "uploads_bucket" {
  bucket = "wp-docker-uploads-${random_string.bucket_suffix.result}"
  tags = {
    Name = "WordPress Uploads Bucket"
  }
}

resource "aws_s3_bucket_public_access_block" "uploads_bucket_block" {
  bucket = aws_s3_bucket.uploads_bucket.id

  block_public_acls       = false
  block_public_policy     = true
  ignore_public_acls      = false
  restrict_public_buckets = true
}

# -----------------------------------------------------
# SECTION 8: IAM ROLE FOR EC2 INSTANCES
# -----------------------------------------------------
# IAM policy to allow reading the secret
resource "aws_iam_policy" "ec2_secrets_policy" {
  name        = "WordPressEC2SecretsPolicy"
  description = "Allows EC2 to read DB secret"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect   = "Allow",
        Action   = "secretsmanager:GetSecretValue",
        Resource = aws_secretsmanager_secret.db_credentials.arn
      }
    ]
  })
}

# IAM policy to allow all S3 plugin actions
resource "aws_iam_policy" "wordpress_s3_policy" {
  name        = "WordPressS3Policy"
  description = "Allows all S3 plugin actions on the uploads bucket"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "s3:ListBucket",
          "s3:GetBucketLocation",
          "s3:PutBucketPublicAccessBlock"
        ],
        Resource = [
          aws_s3_bucket.uploads_bucket.arn
        ]
      },
      {
        Effect = "Allow",
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:PutObjectAcl"
        ],
        Resource = [
          "${aws_s3_bucket.uploads_bucket.arn}/*"
        ]
      }
    ]
  })
}

# --- UPDATED POLICY FOR BACKUP & PLUGIN BUCKETS ---
resource "aws_iam_policy" "backup_s3_read_policy" {
  name        = "WordPressBackupS3ReadPolicy"
  description = "Allows EC2 to read the .wpress backup and plugins from S3"
  
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        # This statement allows finding files in BOTH buckets
        Effect = "Allow",
        Action = "s3:ListBucket",
        Resource = [
          "arn:aws:s3:::saicharan-wp-backup-storage-121125",
          "arn:aws:s3:::wordpress-plugins-0"
        ]
      },
      {
        # This statement allows downloading files from BOTH buckets
        Effect = "Allow",
        Action = "s3:GetObject",
        Resource = [
          "arn:aws:s3:::saicharan-wp-backup-storage-121125/*",
          "arn:aws:s3:::wordpress-plugins-0/*"
        ]
      }
    ]
  })
}
# --- END OF POLICY UPDATE ---


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

# Attach our custom policy for reading secrets
resource "aws_iam_role_policy_attachment" "secrets" {
  role       = aws_iam_role.ec2_instance_role.name
  policy_arn = aws_iam_policy.ec2_secrets_policy.arn
}

# Attach our custom policy for S3
resource "aws_iam_role_policy_attachment" "s3" {
  role       = aws_iam_role.ec2_instance_role.name
  policy_arn = aws_iam_policy.wordpress_s3_policy.arn
}

# Attach backup bucket policy
resource "aws_iam_role_policy_attachment" "backup_s3_read" {
  role       = aws_iam_role.ec2_instance_role.name
  policy_arn = aws_iam_policy.backup_s3_read_policy.arn
}

# Instance Profile to attach role to EC2
resource "aws_iam_instance_profile" "ec2_instance_profile" {
  name = "WordPressEC2InstanceProfile"
  role = aws_iam_role.ec2_instance_role.name
}

# -----------------------------------------------------
# SECTION 9: APPLICATION LOAD BALANCER (ALB)
# -----------------------------------------------------
resource "aws_lb" "app_lb" {
  name               = "wp-docker-lb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = data.aws_subnets.default.ids
}

# --- TARGET GROUP 1: WORDPRESS (Port 80) ---
resource "aws_lb_target_group" "app_tg" {
  name        = "wp-docker-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.default.id
  target_type = "instance"

  health_check {
    enabled             = true
    path                = "/license.txt"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

# --- TARGET GROUP 2: EASY BACKEND (Port 8080) ---
resource "aws_lb_target_group" "easy_tg" {
  name        = "easy-app-tg"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.default.id
  target_type = "instance"

  health_check {
    enabled             = true
    # Health check: looking for the public folder
    path                = "/easy/public/" 
    protocol            = "HTTP"
    matcher             = "200-399" # Accepts 200 OK, 301 Redirect, or 403/404 (proves server is up)
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

# --- LISTENER ---
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app_lb.arn
  port              = "80"
  protocol          = "HTTP"
  
  # Default Action: Send to WordPress
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app_tg.arn
  }
}

# --- LISTENER RULE: ROUTE /easy* TO PORT 8080 ---
resource "aws_lb_listener_rule" "easy_app_rule" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 100

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.easy_tg.arn
  }

  condition {
    path_pattern {
      values = ["/easy*"]
    }
  }
}

# -----------------------------------------------------
# SECTION 10: EC2 LAUNCH TEMPLATE & AUTO SCALING GROUP
# -----------------------------------------------------
resource "aws_launch_template" "web_server_lt" {
  name_prefix   = "wp-docker-lt-"
  image_id      = data.aws_ssm_parameter.standard_al2023_ami.value
  instance_type = "t3.small"

  # Request 30GB disk
  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size = 30
      volume_type = "gp3"
    }
  }

  iam_instance_profile {
    name = aws_iam_instance_profile.ec2_instance_profile.name
  }

  vpc_security_group_ids = [aws_security_group.web_server_sg.id]

  user_data = base64encode(templatefile("setup-docker-wp.sh", {
    db_secret_arn = aws_secretsmanager_secret.db_credentials.arn
    lb_dns_name   = aws_lb.app_lb.dns_name 
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
  health_check_type         = "ELB"
  health_check_grace_period = 300

  # --- UPDATED: Register with BOTH Target Groups ---
  target_group_arns = [
    aws_lb_target_group.app_tg.arn,
    aws_lb_target_group.easy_tg.arn
  ]

  launch_template {
    id      = aws_launch_template.web_server_lt.id
    version = "$Latest"
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
    }
  }

  depends_on = [
    aws_secretsmanager_secret_version.db_credentials_values
  ]
}

# -----------------------------------------------------
# SECTION 11: OUTPUTS
# -----------------------------------------------------
output "load_balancer_dns" {
  description = "The DNS name of the Application Load Balancer"
  value       = aws_lb.app_lb.dns_name
}
