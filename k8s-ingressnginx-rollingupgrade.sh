#!/usr/bin/env bash

set -eo pipefail

# Interactive upgrade script for ingress-nginx on Kubernetes (AKS/EKS/GKE)

echo "Ingress-NGINX Rolling Upgrade Script"

# Prompt for Kubernetes context
kubectl config get-contexts
read -rp "Enter your Kubernetes context (leave blank for current): " KUBE_CONTEXT
if [ -n "$KUBE_CONTEXT" ]; then
  kubectl config use-context "$KUBE_CONTEXT"
fi

# Check connectivity
if ! kubectl cluster-info > /dev/null; then
  echo "Cannot connect to Kubernetes cluster. Please verify your configuration." >&2
  exit 1
fi

# Namespace
read -rp "Ingress-NGINX Namespace [default: ingress-nginx]: " NAMESPACE
NAMESPACE=${NAMESPACE:-ingress-nginx}

# Detect ingress-nginx deployment
DEPLOYMENT=$(kubectl get deployment -n "$NAMESPACE" -l app.kubernetes.io/name=ingress-nginx -o jsonpath="{.items[0].metadata.name}")
if [ -z "$DEPLOYMENT" ]; then
  echo "Ingress-nginx deployment not found in namespace $NAMESPACE" >&2
  exit 1
fi
echo "Detected Deployment: $DEPLOYMENT"

# Get current image
CURRENT_IMAGE=$(kubectl get deployment "$DEPLOYMENT" -n "$NAMESPACE" -o jsonpath="{.spec.template.spec.containers[0].image}")
echo "Current image: $CURRENT_IMAGE"

# Prompt for new image
read -rp "Enter patched ingress-nginx image (full path, e.g., k8s.gcr.io/ingress-nginx/controller:v1.9.6): " NEW_IMAGE
if [ -z "$NEW_IMAGE" ]; then
  echo "New image must be specified." >&2
  exit 1
fi

# Confirm rolling update strategy
cat << EOF

Recommended Rolling Update Strategy:
maxUnavailable: 0
maxSurge: 1

EOF

read -rp "Apply recommended rolling update strategy? [Y/n]: " APPLY_STRATEGY
APPLY_STRATEGY=${APPLY_STRATEGY:-Y}

if [[ $APPLY_STRATEGY =~ ^[Yy]$ ]]; then
  kubectl patch deployment "$DEPLOYMENT" -n "$NAMESPACE" -p '{"spec":{"strategy":{"rollingUpdate":{"maxUnavailable":0,"maxSurge":1}}}}'
fi

# Backup current deployment manifest
BACKUP_FILE="${DEPLOYMENT}-backup-$(date +%Y%m%d-%H%M%S).yaml"
kubectl get deployment "$DEPLOYMENT" -n "$NAMESPACE" -o yaml > "$BACKUP_FILE"
echo "Deployment backed up as $BACKUP_FILE"

# Confirm and apply update
read -rp "Proceed with updating image to $NEW_IMAGE? [y/N]: " CONFIRM_UPDATE
if [[ ! $CONFIRM_UPDATE =~ ^[Yy]$ ]]; then
  echo "Upgrade canceled by user."
  exit 0
fi

# Apply update
kubectl set image deployment "$DEPLOYMENT" -n "$NAMESPACE" "controller=$NEW_IMAGE"

echo "Monitoring rollout..."
kubectl rollout status deployment "$DEPLOYMENT" -n "$NAMESPACE"

# Verify health
sleep 5
HEALTHY_POD=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=ingress-nginx -o jsonpath='{.items[0].metadata.name}')
if kubectl exec -n "$NAMESPACE" "$HEALTHY_POD" -- curl -sf http://localhost:10254/healthz; then
  echo "Ingress-nginx successfully updated and healthy."
else
  echo "Post-upgrade health check failed. Initiating rollback." >&2
  kubectl rollout undo deployment "$DEPLOYMENT" -n "$NAMESPACE"
  exit 1
fi

# Rollback instructions
cat << EOF

To rollback manually at any time, use:
kubectl rollout undo deployment $DEPLOYMENT -n $NAMESPACE

EOF

echo "Upgrade completed successfully."
