#############################################
# VPC
#############################################
module "vpc_2" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.16.0"

  name               = "${local.prefix}-02"
  azs                = ["ap-northeast-1a", "ap-northeast-1c"]
  public_subnets     = ["10.0.10.0/24", "10.0.20.0/24"]
  private_subnets    = ["10.0.1.0/24", "10.0.2.0/24"]
  enable_nat_gateway = true
  single_nat_gateway = true
}

#############################################
# Security Group
#############################################
module "security_group_02_lattice" {
  source              = "terraform-aws-modules/security-group/aws"
  version             = "5.2.0"
  name                = "${local.prefix}-02-lattice-sg"
  vpc_id              = module.vpc_2.vpc_id
  ingress_rules       = ["all-all"]
  ingress_cidr_blocks = [module.vpc_2.vpc_cidr_block]
}

module "security_group_02_ec2" {
  source             = "terraform-aws-modules/security-group/aws"
  version            = "5.2.0"
  name               = "${local.prefix}-02-ec2-sg"
  vpc_id             = module.vpc_2.vpc_id
  egress_cidr_blocks = ["0.0.0.0/0"]
  egress_rules       = ["all-all"]
}

#############################################
# VPC Lattice
#############################################
resource "aws_vpclattice_service_network_vpc_association" "this_02" {
  vpc_identifier             = module.vpc_2.vpc_id
  service_network_identifier = aws_vpclattice_service_network.this.id
  security_group_ids         = [module.security_group_02_lattice.security_group_id]
}

#############################################
# EC2
#############################################
data "aws_ssm_parameter" "amazonlinux_2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-x86_64" # x86_64
}

#############################################
# IAM Role and Instance Profile
#############################################
resource "aws_iam_role" "this_ec2" {
  name = "${local.prefix}-02-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "this_ec2" {
  role       = aws_iam_role.this_ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "this_ec2" {
  name = aws_iam_role.this_ec2.name
  role = aws_iam_role.this_ec2.name
}

resource "aws_instance" "this" {
  ami           = data.aws_ssm_parameter.amazonlinux_2023.value
  instance_type = "t2.micro"
  subnet_id     = module.vpc_2.private_subnets[0]
  vpc_security_group_ids = [
    module.security_group_02_ec2.security_group_id,
  ]
  iam_instance_profile = aws_iam_instance_profile.this_ec2.name
}
