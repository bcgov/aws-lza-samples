# Sample EKS Appliucation Deployment using Terraform

This sample terraform application shows how to expose EKS workloads through an internal ALB in a Landing Zone Accelerator (LZA) environment. It demonstrates one of the patterns and the LZA-specific requirements (tagging and health checks) so teams can deploy consistently and trigger perimeter automation.

## Supported patterns (at a glance)

 • Pattern A – Kubernetes-managed ALB (Ingress + AWS Load Balancer Controller):
Kubernetes owns the ALB lifecycle. Use an Ingress (optionally with an Ingress Group to reuse the same ALB for multiple apps).
 • Pattern B – Terraform-managed ALB (prebuilt) + TargetGroupBinding:
Terraform owns the ALB, listeners, and rules. Kubernetes only registers pods into prebuilt target groups with a TargetGroupBinding. No Ingress in this pattern.

LZA-specific requirements
 • Tag every internal ALB with Public=True so perimeter automation can wire public routing to the internal ALB.
 • Expose a fixed 200 at /bcgovhealthcheck on the internal ALB (listener rule). The perimeter public ALB health-checks this path.
 • Use EKS Pod Identity for controller auth (LZA SCPs block creating IAM OIDC providers/IRSA). The controller runs with a ServiceAccount associated to an IAM role via Pod Identity.

Example Terraform to use TargetGroupBinding to use Existing Loadbalancer

```hcl

resource "kubernetes_manifest" "echo_tgb" {
  manifest = {
    apiVersion = "elbv2.k8s.aws/v1beta1"
    kind       = "TargetGroupBinding"
    metadata = {
      name      = "echo-tgb"
      namespace = "sample-app-namespace"
    }
    spec = {
      targetGroupARN = aws_lb_target_group.echo_tg.arn
      serviceRef = {
        name = kubernetes_service_v1.sample-app.metadata[0].name
        port = 80
      }

    }
  }
}

```
