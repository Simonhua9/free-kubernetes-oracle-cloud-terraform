provider "oci" {
  region = var.region
}

module "vcn" {
  source  = "oracle-terraform-modules/vcn/oci"
  #Latest module version can be found at https://registry.terraform.io/modules/oracle-terraform-modules/vcn/oci/latest 3.5.4 as June 16 2023
  version = "3.5.4"

  compartment_id = var.compartment_id
  region         = var.region

  internet_gateway_route_rules = null
  local_peering_gateways       = null
  nat_gateway_route_rules      = null

  vcn_name      = "free-k8s-vcn"
  vcn_dns_label = "freek8svcn"
  vcn_cidrs     = ["10.0.0.0/16"]

  create_internet_gateway = true
  create_nat_gateway      = true
  create_service_gateway  = true
}

resource "oci_core_security_list" "private_subnet_sl" {
  compartment_id = var.compartment_id
  vcn_id         = module.vcn.vcn_id

  display_name = "free-k8s-private-subnet-sl"

  egress_security_rules {
    stateless        = false
    destination      = "0.0.0.0/0"
    destination_type = "CIDR_BLOCK"
    protocol         = "all"
  }
  
  ingress_security_rules {
    stateless   = false
    source      = "10.0.0.0/16"
    source_type = "CIDR_BLOCK"
    protocol    = "all"
  }

  ingress_security_rules {
    stateless   = false
    source      = "10.0.0.0/24"
    source_type = "CIDR_BLOCK"
    protocol    = "6"
    tcp_options {
      min = 10256
      max = 10256
    }
  }

  ingress_security_rules {
    stateless   = false
    source      = "10.0.0.0/24"
    source_type = "CIDR_BLOCK"
    protocol    = "6"
    tcp_options {
      min = 31600
      max = 31600
    }
  }
}

resource "oci_core_security_list" "public_subnet_sl" {
  compartment_id = var.compartment_id
  vcn_id         = module.vcn.vcn_id

  display_name = "free-k8s-public-subnet-sl"

  egress_security_rules {
    stateless        = false
    destination      = "0.0.0.0/0"
    destination_type = "CIDR_BLOCK"
    protocol         = "all"
  }
  
  egress_security_rules {
    stateless        = false
    destination      = "10.0.1.0/24"
    destination_type = "CIDR_BLOCK"
    protocol         = "6"
    tcp_options {
      min = 31600
      max = 31600
    }
  }

  egress_security_rules {
    stateless        = false
    destination      = "10.0.1.0/24"
    destination_type = "CIDR_BLOCK"
    protocol         = "6"
    tcp_options {
      min = 10256
      max = 10256
    }
  }

  ingress_security_rules {
    protocol    = "6"
    source      = "0.0.0.0/0"
    source_type = "CIDR_BLOCK"
    stateless   = false

    tcp_options {
      max = 80
      min = 80
    }
  } 

  ingress_security_rules {
    stateless   = false
    source      = "10.0.0.0/16"
    source_type = "CIDR_BLOCK"
    protocol    = "all"
  }

  ingress_security_rules {
    stateless   = false
    source      = "0.0.0.0/0"
    source_type = "CIDR_BLOCK"
    protocol    = "6"
    tcp_options {
      min = 6443
      max = 6443
    }
  }
}

resource "oci_core_subnet" "vcn_private_subnet" {
  compartment_id = var.compartment_id
  vcn_id         = module.vcn.vcn_id
  cidr_block     = "10.0.1.0/24"

  route_table_id             = module.vcn.nat_route_id
  security_list_ids          = [oci_core_security_list.private_subnet_sl.id]
  display_name               = "free-k8s-private-subnet"
  prohibit_public_ip_on_vnic = true
}

resource "oci_core_subnet" "vcn_public_subnet" {
  compartment_id = var.compartment_id
  vcn_id         = module.vcn.vcn_id
  cidr_block     = "10.0.0.0/24"

  route_table_id    = module.vcn.ig_route_id
  security_list_ids = [oci_core_security_list.public_subnet_sl.id]
  display_name      = "free-k8s-public-subnet"
}

resource "oci_containerengine_cluster" "k8s_cluster" {
  compartment_id     = var.compartment_id
  # Kubernetes version history https://kubernetes.io/releases/
  # supported version from Oracle can be found from the script running. It is 1.26.2 as June 18 2023. The latest version is 1.27.2 but OCI only supports 1.26.2
  kubernetes_version = "v1.26.2"
  name               = "free-k8s-cluster"
  vcn_id             = module.vcn.vcn_id

  endpoint_config {
    is_public_ip_enabled = true
    subnet_id            = oci_core_subnet.vcn_public_subnet.id
  }

  options {
    add_ons {
      is_kubernetes_dashboard_enabled = false
      is_tiller_enabled               = false
    }
    kubernetes_network_config {
      pods_cidr     = "10.244.0.0/16"
      services_cidr = "10.96.0.0/16"
    }
    service_lb_subnet_ids = [oci_core_subnet.vcn_public_subnet.id]
  }
}

data "oci_identity_availability_domains" "ads" {
  compartment_id = var.compartment_id
}

locals {
  # Gather a list of availability domains for use in configuring placement_configs
  azs = data.oci_identity_availability_domains.ads.availability_domains[*].name
}

data "oci_core_images" "latest_image" {
  compartment_id = var.compartment_id
  operating_system = "Oracle Linux"
  # https://docs.oracle.com/en-us/iaas/images/ Oracle has a OKE worker node, but for this lab, I still use default Oracle Linux.
  operating_system_version = "8.7"
  filter {
    name   = "display_name"
    values = ["^.*aarch64-.*$"]
    regex = true
  }
}

resource "oci_containerengine_node_pool" "k8s_node_pool" {
  cluster_id         = oci_containerengine_cluster.k8s_cluster.id
  compartment_id     = var.compartment_id
  # Kubernetes version history https://kubernetes.io/releases/
  kubernetes_version = "v1.26.2"
  name               = "free-k8s-node-pool"
  node_config_details {
    dynamic placement_configs {
      for_each = local.azs
      content {
        availability_domain = placement_configs.value
        subnet_id           = oci_core_subnet.vcn_private_subnet.id
      }
    }
    size = 2

  }
  node_shape = "VM.Standard.A1.Flex"

# change the RAM to 12G, and cpu to 2. For free tier, the settings can be found at https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm 
  node_shape_config {
    memory_in_gbs = 12
    ocpus         = 2
  }

  node_source_details {
    # data.oci_core_images.latest_image.images got error "data.oci_core_images.latest_image.images is empty list of object", then specify the image_id directly.
    # image_id    = data.oci_core_images.latest_image.images.0.id
    # image_id can be found at https://docs.oracle.com/en-us/iaas/images but only some of image IDs can be supported.
    # get the supported image id "oci ce node-pool-options get --node-pool-option-id all"
    #  "source-name": "Oracle-Linux-8.7-aarch64-2023.04.25-0-OKE-1.26.2-607"
    image_id  = "ocid1.image.oc1.ca-toronto-1.aaaaaaaa2ma6c6opoozastpndsr5xq3evz354qqj7hoznas27rupebexkymq"
    source_type = "image"
  }

  initial_node_labels {
    key   = "name"
    value = "free-k8s-cluster"
  }

  ssh_public_key = var.ssh_public_key
}

resource "oci_artifacts_container_repository" "docker_repository" {
  compartment_id = var.compartment_id
  display_name   = "free-kubernetes-nginx"

  is_immutable = false
  is_public    = false
}
