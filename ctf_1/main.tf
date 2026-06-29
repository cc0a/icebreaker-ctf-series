provider "aws" {
  region = var.region
}

locals {
  player_cidr = "${var.external_ip}/32"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.cluster_name}-vpc"
  cidr = "10.42.0.0/16"

  azs             = ["${var.region}a", "${var.region}b"]
  private_subnets = ["10.42.1.0/24", "10.42.2.0/24"]
  public_subnets  = ["10.42.101.0/24", "10.42.102.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = "1.30"

  cluster_endpoint_public_access       = true
  cluster_endpoint_public_access_cidrs = [local.player_cidr]
  cluster_endpoint_private_access      = true

  enable_cluster_creator_admin_permissions = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  eks_managed_node_groups = {
    ctf_nodes = {
      min_size       = 2
      max_size       = 3
      desired_size   = 2
      instance_types = ["t3.medium"]
      capacity_type  = "ON_DEMAND"
    }
  }
}

data "aws_eks_cluster" "this" {
  name       = module.eks.cluster_name
  depends_on = [module.eks]
}

data "aws_eks_cluster_auth" "this" {
  name       = module.eks.cluster_name
  depends_on = [module.eks]
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.this.token
}

resource "kubernetes_namespace_v1" "ctf" {
  metadata {
    name = "ctf-start"
  }
}

resource "kubernetes_namespace_v1" "flag" {
  metadata {
    name = "flag-vault"
  }
}

resource "kubernetes_namespace_v1" "blue" {
  metadata {
    name = "blue-team"
  }
}

resource "kubernetes_service_account_v1" "player" {
  metadata {
    name      = "ctf-player"
    namespace = kubernetes_namespace_v1.ctf.metadata[0].name
  }
}

resource "kubernetes_secret_v1" "player_token" {
  metadata {
    name      = "ctf-player-token"
    namespace = kubernetes_namespace_v1.ctf.metadata[0].name

    annotations = {
      "kubernetes.io/service-account.name" = kubernetes_service_account_v1.player.metadata[0].name
    }
  }

  type                           = "kubernetes.io/service-account-token"
  wait_for_service_account_token = true
}

resource "kubernetes_cluster_role_v1" "weak_recon_escalate" {
  metadata {
    name = "cc0a-weak-recon-escalate"
  }

  rule {
    api_groups = [""]
    resources  = ["namespaces", "pods", "pods/log", "serviceaccounts"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["rbac.authorization.k8s.io"]
    resources  = ["roles", "rolebindings", "clusterroles", "clusterrolebindings"]
    verbs      = ["get", "list", "watch"]
  }

  # Intentional CTF flaw:
  # This lets the player bind themselves to cluster-admin.
  rule {
    api_groups     = ["rbac.authorization.k8s.io"]
    resources      = ["clusterroles"]
    resource_names = ["cluster-admin"]
    verbs          = ["bind"]
  }

  rule {
    api_groups = ["rbac.authorization.k8s.io"]
    resources  = ["clusterrolebindings"]
    verbs      = ["create", "patch", "update", "get", "list"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "player_weak_binding" {
  metadata {
    name = "cc0a-player-weak-binding"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.weak_recon_escalate.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.player.metadata[0].name
    namespace = kubernetes_namespace_v1.ctf.metadata[0].name
  }
}

resource "kubernetes_deployment_v1" "blue_api" {
  metadata {
    name      = "blue-api"
    namespace = kubernetes_namespace_v1.blue.metadata[0].name
  }

  spec {
    replicas = 2

    selector {
      match_labels = {
        app = "blue-api"
      }
    }

    template {
      metadata {
        labels = {
          app = "blue-api"
        }
      }

      spec {
        container {
          name  = "api"
          image = "nginx:1.27-alpine"

          port {
            container_port = 80
          }
        }
      }
    }
  }
}

resource "kubernetes_secret_v1" "flag_secret" {
  metadata {
    name      = "cluster-flag"
    namespace = kubernetes_namespace_v1.flag.metadata[0].name
  }

  data = {
    "flag.txt" = base64encode("cc0a{root_in_the_cloud_context_is_everything}")
  }

  type = "Opaque"
}

resource "kubernetes_pod_v1" "flag_pod" {
  metadata {
    name      = "quiet-snowflake"
    namespace = kubernetes_namespace_v1.flag.metadata[0].name

    labels = {
      app = "flag-holder"
    }
  }

  spec {
    container {
      name    = "vault"
      image   = "busybox:1.36"
      command = ["/bin/sh", "-c", "sleep 365d"]

      volume_mount {
        name       = "flag-volume"
        mount_path = "/opt/flag"
        read_only  = true
      }
    }

    volume {
      name = "flag-volume"

      secret {
        secret_name = kubernetes_secret_v1.flag_secret.metadata[0].name
      }
    }
  }
}

resource "local_sensitive_file" "player_kubeconfig" {
  filename = "${path.module}/player-kubeconfig.yaml"

  content = yamlencode({
    apiVersion = "v1"
    kind       = "Config"

    clusters = [{
      name = module.eks.cluster_name
      cluster = {
        server                       = data.aws_eks_cluster.this.endpoint
        "certificate-authority-data" = data.aws_eks_cluster.this.certificate_authority[0].data
      }
    }]

    users = [{
      name = "ctf-player"
      user = {
        token = kubernetes_secret_v1.player_token.data.token
      }
    }]

    contexts = [{
      name = "ctf-player@${module.eks.cluster_name}"
      context = {
        cluster   = module.eks.cluster_name
        user      = "ctf-player"
        namespace = kubernetes_namespace_v1.ctf.metadata[0].name
      }
    }]

    "current-context" = "ctf-player@${module.eks.cluster_name}"
  })
}