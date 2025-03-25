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

# Detect ingress-nginx deployments
DEPLOYMENTS=$(kubectl get deployment -n "$NAMESPACE" -l app.kubernetes.io/name=ingress-nginx -o jsonpath="{.items[*].metadata.name}")
if [ -z "$DEPLOYMENTS" ]; then
  echo "Ingress-nginx deployment not found in namespace $NAMESPACE" >&2
  exit 1
fi

# If multiple deployments, let user select
if [[ $(echo "$DEPLOYMENTS" | wc -w) -gt 1 ]]; then
  echo "Multiple ingress-nginx deployments found:"
  select DEPLOYMENT in $DEPLOYMENTS; do
    if [ -n "$DEPLOYMENT" ]; then
      break
    fi
  done
else
  DEPLOYMENT=$DEPLOYMENTS
fi
echo "Selected Deployment: $DEPLOYMENT"

# Get container name
CONTAINER_NAMES=$(kubectl get deployment "$DEPLOYMENT" -n "$NAMESPACE" -o jsonpath="{.spec.template.spec.containers[*].name}")
if [[ $(echo "$CONTAINER_NAMES" | wc -w) -gt 1 ]]; then
  echo "Multiple containers found in deployment:"
  select CONTAINER_NAME in $CONTAINER_NAMES; do
    if [ -n "$CONTAINER_NAME" ]; then
      break
    fi
  done
else
  CONTAINER_NAME=$CONTAINER_NAMES
fi
echo "Container name: $CONTAINER_NAME"

# Get current image
CURRENT_IMAGE=$(kubectl get deployment "$DEPLOYMENT" -n "$NAMESPACE" -o jsonpath="{.spec.template.spec.containers[?(@.name=='$CONTAINER_NAME')].image}")
echo "Current image: $CURRENT_IMAGE"

# Extract version for comparison
CURRENT_VERSION=$(echo "$CURRENT_IMAGE" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")

# Prompt for new image
read -rp "Enter patched ingress-nginx image (full path, e.g., k8s.gcr.io/ingress-nginx/controller:v1.9.6): " NEW_IMAGE
if [ -z "$NEW_IMAGE" ]; then
  echo "New image must be specified." >&2
  exit 1
fi

# Extract target version for comparison
TARGET_VERSION=$(echo "$NEW_IMAGE" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")

if [ "$CURRENT_VERSION" != "unknown" ] && [ "$TARGET_VERSION" != "unknown" ]; then
  echo "Upgrading from $CURRENT_VERSION to $TARGET_VERSION"
  CURRENT_MAJOR=$(echo "$CURRENT_VERSION" | cut -d. -f1 | tr -d 'v')
  TARGET_MAJOR=$(echo "$TARGET_VERSION" | cut -d. -f1 | tr -d 'v')
  
  if [ "$TARGET_MAJOR" -lt "$CURRENT_MAJOR" ]; then
    read -rp "Warning: Downgrading to an older major version. Continue? [y/N]: " CONTINUE_DOWNGRADE
    if [[ ! $CONTINUE_DOWNGRADE =~ ^[Yy]$ ]]; then
      echo "Upgrade canceled."
      exit 0
    fi
  fi
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
kubectl set image deployment "$DEPLOYMENT" -n "$NAMESPACE" "${CONTAINER_NAME}=${NEW_IMAGE}"
echo "Monitoring rollout..."
kubectl rollout status deployment "$DEPLOYMENT" -n "$NAMESPACE"

# Verify health
sleep 5
HEALTHY_POD=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=ingress-nginx,app.kubernetes.io/component=controller -o jsonpath='{.items[0].metadata.name}')

# Try both old and new health endpoint locations
if kubectl exec -n "$NAMESPACE" "$HEALTHY_POD" -- curl -sf http://localhost:10254/healthz > /dev/null 2>&1; then
  echo "Ingress-nginx health check passed via /healthz endpoint."
elif kubectl exec -n "$NAMESPACE" "$HEALTHY_POD" -- curl -sf http://localhost:10254/health > /dev/null 2>&1; then
  echo "Ingress-nginx health check passed via /health endpoint."
elif kubectl get pods -n "$NAMESPACE" "$HEALTHY_POD" -o jsonpath='{.status.containerStatuses[0].ready}' | grep -q "true"; then
  echo "Ingress-nginx pod reports ready status."
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
