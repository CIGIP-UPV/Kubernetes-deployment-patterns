#!/usr/bin/env bash
# =============================================================================
# publish_charts.sh — Publish Helm charts to GitHub Pages (gh-pages branch)
# =============================================================================
# Usage:
#   ./scripts/publish_charts.sh
#
# Prerequisites:
#   - helm CLI installed
#   - git configured with push access to the repo
#   - Working directory: project root
#
# What it does:
#   1. Lints all charts
#   2. Packages them into dist/charts/
#   3. Generates index.yaml
#   4. Publishes to gh-pages branch
# =============================================================================
set -euo pipefail

REPO_URL="https://cigip-upv.github.io/Kubernetes-deployment-patterns/charts"
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="${PROJECT_ROOT}/dist/charts"
TMP_DIR=$(mktemp -d)

# Chart paths (relative to PROJECT_ROOT)
# The four deployment patterns analysed in the IEEE Access submission:
#   monolithic, microservices, overlay, dynamic-loader
CHARTS=(
  "Patterns/monolithic/helm"
  "Patterns/microservices/helm/ros2-microservices"
  "Patterns/overlay/helm/ros2-overlay"
  "Patterns/dynamic-loader/helm/dynamic-loader"
)

cd "${PROJECT_ROOT}"

echo "============================================"
echo " Step 1: Lint all charts"
echo "============================================"
for chart in "${CHARTS[@]}"; do
  echo "  Linting ${chart}..."
  helm lint "${chart}" || { echo "LINT FAILED: ${chart}"; exit 1; }
done
echo "All charts passed lint."

echo ""
echo "============================================"
echo " Step 2: Template validation"
echo "============================================"
for chart in "${CHARTS[@]}"; do
  name=$(basename "${chart}")
  echo "  Rendering ${name}..."
  helm template test "${chart}" > /dev/null || { echo "TEMPLATE FAILED: ${chart}"; exit 1; }
done
echo "All templates render correctly."

echo ""
echo "============================================"
echo " Step 3: Package charts"
echo "============================================"
rm -rf "${DIST_DIR}"
mkdir -p "${DIST_DIR}"
for chart in "${CHARTS[@]}"; do
  helm package "${chart}" -d "${DIST_DIR}"
done
echo ""
echo "Packages created:"
ls -la "${DIST_DIR}"/*.tgz

echo ""
echo "============================================"
echo " Step 4: Generate index.yaml"
echo "============================================"
helm repo index "${DIST_DIR}" --url "${REPO_URL}"
echo "index.yaml generated at ${DIST_DIR}/index.yaml"
echo ""
echo "Contents:"
cat "${DIST_DIR}/index.yaml"

echo ""
echo "============================================"
echo " Step 5: Publish to gh-pages"
echo "============================================"

# Save current branch
CURRENT_BRANCH=$(git branch --show-current)

# Copy packaged charts to temp
cp -R "${DIST_DIR}"/* "${TMP_DIR}/"

# Switch to gh-pages
git stash --include-untracked -q 2>/dev/null || true
git checkout gh-pages

# Update charts directory
rm -rf charts
mkdir -p charts
cp -R "${TMP_DIR}"/* charts/

# Ensure .nojekyll exists
touch .nojekyll

# Commit and push
git add charts .nojekyll
if git diff --cached --quiet; then
  echo "No changes to publish."
else
  git commit -m "Publish Helm charts $(date +%Y-%m-%d)"
  git push origin gh-pages
  echo "Charts published successfully!"
fi

# Return to original branch
git checkout "${CURRENT_BRANCH}"
git stash pop -q 2>/dev/null || true

# Cleanup
rm -rf "${TMP_DIR}"

echo ""
echo "============================================"
echo " Done! Next steps:"
echo "============================================"
echo "  1. Wait ~1 min for GitHub Pages to deploy"
echo "  2. Verify: curl -s ${REPO_URL}/index.yaml | head -20"
echo "  3. In Rancher: Apps > Repositories > tesis-patterns > Refresh"
echo "  4. Upgrade releases with new chart versions"
echo "============================================"
