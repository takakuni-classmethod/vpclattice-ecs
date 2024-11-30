#############################################
# VPC Lattice
#############################################
resource "aws_vpclattice_service_network" "this" {
  name      = "ecs-vpclattice"
  auth_type = "NONE"
}
