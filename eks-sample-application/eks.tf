data "aws_vpc" "workload_vpc" {
  filter {
    name   = "tag:Name"
    values = ["WorkloadPreProd-Dev"]
  }
}
# App subnets to place the EKS Cluster
data "aws_subnets" "app_subnet" {
  filter {
    name   = "tag:Name"
    values = ["Dev-App-A", "Dev-App-B"]
  }
}
# Web Subnets to place the internal load balancer
data "aws_subnets" "web_subent" {
  filter {
    name   = "tag:Name"
    values = ["Dev-Web-MainTgwAttach-A", "Dev-Web-MainTgwAttach-B"]
  }
}

# Read in security groups for the ALB

data "aws_security_group" "web_sg" {
  filter {
    name   = "tag:Name"
    values = ["Web"]
  }
}
resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  role_arn = aws_iam_role.eks_cluster.arn

  version = "1.29"
  vpc_config {
    subnet_ids              = data.aws_subnets.app_subnet.ids
    endpoint_public_access  = true 
    endpoint_private_access = true
  }


  tags = var.tags

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy,
    aws_iam_role_policy_attachment.eks_service_policy
  ]
}

# Managed Node Group (creates the EC2 workers for you)
resource "aws_eks_node_group" "default" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "default"
  node_role_arn   = aws_iam_role.eks_node.arn
  subnet_ids      = data.aws_subnets.app_subnet.ids

  scaling_config {
    desired_size = 2
    min_size     = 1
    max_size     = 2
  }

  instance_types = ["t3.small"]
  ami_type       = "AL2_x86_64"

  tags = var.tags

  depends_on = [
    aws_iam_role_policy_attachment.node_worker_policy,
    aws_iam_role_policy_attachment.node_cni_policy,
    aws_iam_role_policy_attachment.node_ecr_ro
  ]
}

## Pod Identity 
resource "aws_eks_addon" "pod_identity" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "eks-pod-identity-agent"
  resolve_conflicts_on_create = "OVERWRITE"
}

# iam-lbc
resource "aws_iam_policy" "lbc" {
  name   = "${var.cluster_name}-AWSLoadBalancerController"
  policy = file("${path.module}/iam_policy.json")
}

# IAM role for the AWS Load Balancer Controller
resource "aws_iam_role" "lbc_podid" {
  name = "${var.cluster_name}-lbc-podid"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Sid : "AllowEksPodsToAssume",
      Effect : "Allow",
      Principal : { Service : "pods.eks.amazonaws.com" },
      Action : ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lbc_attach" {
  role       = aws_iam_role.lbc_podid.name
  policy_arn = aws_iam_policy.lbc.arn
}



# k8s-lbc
resource "kubernetes_namespace_v1" "lbc" {
  metadata { name = "aws-load-balancer-controller" }
}
# Service Account for the AWS Load Balancer Controller
resource "kubernetes_service_account_v1" "lbc" {
  metadata {
    name      = "aws-lbc-sa"
    namespace = kubernetes_namespace_v1.lbc.metadata[0].name
  }
  automount_service_account_token = true
}

resource "aws_eks_pod_identity_association" "lbc" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = kubernetes_namespace_v1.lbc.metadata[0].name
  service_account = kubernetes_service_account_v1.lbc.metadata[0].name
  role_arn        = aws_iam_role.lbc_podid.arn

  depends_on = [aws_eks_addon.pod_identity]
}


# helm-lbc
resource "helm_release" "lbc" {
  name       = "aws-load-balancer-controller"
  namespace  = kubernetes_namespace_v1.lbc.metadata[0].name
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "1.9.2"

  values = [yamlencode({
    clusterName = aws_eks_cluster.this.name
    region      = var.region
    vpcId       = data.aws_vpc.workload_vpc.id
    serviceAccount = {
      create = false
      name   = kubernetes_service_account_v1.lbc.metadata[0].name
    }
  })]

  depends_on = [
    aws_eks_pod_identity_association.lbc,
    aws_eks_node_group.default
  ]
}

data "aws_eks_cluster" "this" {
  name = aws_eks_cluster.this.name
}

data "aws_eks_cluster_auth" "this" {
  name = aws_eks_cluster.this.name
}


provider "kubernetes" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.this.token
}

provider "helm" {
  kubernetes = {
    host                   = data.aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.this.token
    load_config_file       = false
  }
}


# Namespace for the sample app
resource "kubernetes_namespace_v1" "app" {
  metadata { name = "bcgov-eks-sample-app" }
}

# Tiny web app deployment

resource "kubernetes_deployment_v1" "echo" {
  metadata {
    name      = "echo"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
    labels    = { app = "echo" }
  }
  spec {
    replicas = 2
    selector { match_labels = { app = "echo" } }
    template {
      metadata { labels = { app = "echo" } }
      spec {
        container {
          name  = "echo"
          image = "hashicorp/http-echo:0.2.3"
          args  = ["-text=hello-from-eks"]
          port { container_port = 5678 } 
        }
      }
    }
  }
}

#Kubernetes service
resource "kubernetes_service_v1" "echo" {
  metadata {
    name      = "echo"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
    labels    = { app = "echo" }
  }
  spec {
    selector = { app = "echo" }
    port {
      name        = "http"
      port        = 80
      target_port = 5678 
    }
    type = "ClusterIP" 
  }
}

# What is Kubernetes Ingress
resource "kubernetes_ingress_v1" "echo_internal_alb" {
  metadata {
    name      = "echo-alb-internal"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
    annotations = {
      "kubernetes.io/ingress.class"                                   = "alb"
      "alb.ingress.kubernetes.io/group.name"                          = "sample-app-group"
      "alb.ingress.kubernetes.io/scheme"                              = "internal"
      "alb.ingress.kubernetes.io/subnets"                             = join(",", data.aws_subnets.web_subent.ids)
      "alb.ingress.kubernetes.io/security-groups"                     = data.aws_security_group.web_sg.id
      "alb.ingress.kubernetes.io/target-type"                         = "ip"
      "alb.ingress.kubernetes.io/certificate-arn"                     = "arn:aws:acm:ca-central-1:627754053854:certificate/a817283a-36aa-4183-b495-194c4fd2f0f1"
      "alb.ingress.kubernetes.io/listen-ports"                        = "[{\"HTTPS\":443}]"
      "alb.ingress.kubernetes.io/manage-backend-security-group-rules" = "true"
      "alb.ingress.kubernetes.io/load-balancer-name"                  = "eks-sample-app-alb"
      "alb.ingress.kubernetes.io/tags"                                = "Public=True"
      "alb.ingress.kubernetes.io/actions.healthz" = jsonencode({
        Type                = "fixed-response",
        FixedResponseConfig = { StatusCode = "200", ContentType = "text/plain", MessageBody = "ok" }
      })
    }
  }
  spec {
    rule {
      http {
        path {
          path      = "/bcgovhealthcheck"
          path_type = "Exact"
          backend {
            service {
              name = "healthz"
              port { name = "use-annotation" }
            }
          }
        }
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service_v1.echo.metadata[0].name
              port { number = 80 }
            }
          }
        }
      }
    }
  }
  depends_on = [helm_release.lbc]
}