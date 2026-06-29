output "cluster_name" {
  value = module.eks.cluster_name
}

output "region" {
  value = var.region
}

output "endpoint" {
  value = data.aws_eks_cluster.this.endpoint
}

output "player_kubeconfig" {
  value = "${path.module}/player-kubeconfig.yaml"
}

output "player_token" {
  value     = kubernetes_secret_v1.player_token.data.token
  sensitive = true
}