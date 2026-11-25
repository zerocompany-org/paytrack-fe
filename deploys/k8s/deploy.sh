#!/usr/bin/env bash
# Deploy FE theo tag sha-* cố định (khớp tag CI đẩy lên GHCR). Chạy SAU khi
# workflow build-fe.yml push xong, nếu không sẽ ImagePullBackOff.
#
#   ./deploy.sh                # deploy commit HEAD hiện tại -> tag sha-<short>
#   ./deploy.sh sha-1a2b3c4    # deploy 1 tag cụ thể (dùng để rollback)
#
# Biến ghi đè: NAMESPACE, IMAGE.
set -euo pipefail

NAMESPACE="${NAMESPACE:-paytrack}"
IMAGE="${IMAGE:-ghcr.io/zerocompany-org/paytrack-fe/fe}"
DEPLOY="paytrack-fe"
CONTAINER="paytrack-fe"

# --short=7 ghim do dai: docker/metadata-action (type=sha,format=short) sinh
# tag 7 ky tu. De `--short` tran thi git co the tra 8+ ky tu khi bi dung do
# prefix -> tag khong ton tai tren GHCR -> ImagePullBackOff.
TAG="${1:-sha-$(git rev-parse --short=7 HEAD)}"

echo "Deploy $IMAGE:$TAG -> deployment/$DEPLOY (ns=$NAMESPACE)"
kubectl -n "$NAMESPACE" set image "deployment/$DEPLOY" "$CONTAINER=$IMAGE:$TAG"

if ! kubectl -n "$NAMESPACE" rollout status "deployment/$DEPLOY" --timeout=180s; then
  echo "Rollout THẤT BẠI. Chẩn đoán:"
  echo "  kubectl -n $NAMESPACE describe pod -l app=$DEPLOY"
  echo "  kubectl -n $NAMESPACE logs -l app=$DEPLOY --tail=100"
  exit 1
fi
echo "Xong."
