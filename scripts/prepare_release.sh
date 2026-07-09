#!/usr/bin/env bash
# =============================================================================
# prepare_release.sh — Repository cleanup prior to a Zenodo / GitHub release.
# =============================================================================
# Removes work-in-progress files, build logs and OS / IDE caches that should
# not appear in an archival snapshot of the artifact. Detects and refuses to
# include any files that look like exposed credentials.
#
# Default mode: dry-run (prints what would happen, does NOT touch the disk).
# Apply mode: pass --apply to actually perform the operations.
#
# Usage:
#   bash scripts/prepare_release.sh             # dry-run, no changes
#   bash scripts/prepare_release.sh --apply     # actually clean up
#
# Sync raw campaign data from kb2 BEFORE running with --apply if you want
# the Zenodo upload to include raw rosbridge samples (see the SYNC RAW DATA
# section at the bottom of this script for the exact rsync command).
# =============================================================================
set -uo pipefail

APPLY=false
if [ "${1:-}" = "--apply" ]; then APPLY=true; fi

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${PROJECT_ROOT}"

# ── helpers ─────────────────────────────────────────────────────────────────
GREEN="\033[32m"; YELLOW="\033[33m"; RED="\033[31m"; CYAN="\033[36m"; RST="\033[0m"

step()  { echo -e "${CYAN}══════ $* ══════${RST}"; }
info()  { echo -e "  $*"; }
warn()  { echo -e "  ${YELLOW}WARN:${RST} $*"; }
fail()  { echo -e "  ${RED}FAIL:${RST} $*"; }

run() {
  if ${APPLY}; then
    echo -e "  ${GREEN}EXEC${RST}: $*"
    eval "$*"
  else
    echo -e "  ${YELLOW}DRY ${RST}: $*"
  fi
}

mode_banner() {
  if ${APPLY}; then
    echo -e "${RED}═══ APPLY MODE — disk WILL be modified ═══${RST}"
  else
    echo -e "${GREEN}═══ DRY-RUN MODE — re-run with --apply to perform changes ═══${RST}"
  fi
  echo ""
}

# ── pre-flight: refuse to run if uncommitted changes outside of staging ─────
preflight() {
  step "Pre-flight checks"
  if [ ! -d .git ]; then
    fail ".git directory not found. Run this from the repository root."
    exit 1
  fi
  if ! git diff --quiet HEAD; then
    warn "There are uncommitted changes in the working tree. Continuing anyway,"
    warn "but consider committing first so you can revert with git reset --hard."
  fi
  info "Project root: ${PROJECT_ROOT}"
  info "Apply mode  : ${APPLY}"
  echo ""
}

# ── secret detection ────────────────────────────────────────────────────────
detect_secrets() {
  step "Scanning for exposed credentials"
  local found_any=0

  # regcred backups left by the campaign wrapper
  if compgen -G "results/_campaigns/.regcred_*.yaml" >/dev/null 2>&1; then
    warn "Found regcred backup(s) in results/_campaigns/ — these contain your"
    warn "GitLab registry credentials in plaintext. Removing them."
    for f in results/_campaigns/.regcred_*.yaml; do
      run "rm -f \"${f}\""
      found_any=1
    done
  fi

  # generic look for tokens/keys in WIP markdown files
  local hits
  hits=$(grep -rIlnE "(hf_[A-Za-z0-9]{30,}|glpat-[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16})" \
                 --exclude-dir=.git --exclude-dir=Patterns --exclude-dir=Models \
                 . 2>/dev/null || true)
  if [ -n "${hits}" ]; then
    warn "Possible credential strings detected in:"
    echo "${hits}" | sed "s/^/    /"
    warn "These files were NOT auto-removed. Review them by hand before pushing."
    found_any=1
  fi

  if [ "${found_any}" = "0" ]; then
    info "No exposed credentials found."
  fi
  echo ""
}

# ── remove WIP markdown / LaTeX drafts in the root ──────────────────────────
remove_wip_drafts() {
  step "Removing work-in-progress drafts in the repository root"
  local wip=(
    "seccion_V_final.md"
    "seccion_V_reescrita.md"
    "table7_revisada.md"
    "table7_revisada.tex"
    "instrucciones_figuras_excel.md"
  )
  for f in "${wip[@]}"; do
    if [ -e "${f}" ]; then
      run "rm -f \"${f}\""
    fi
  done
  echo ""
}

# ── remove docker build logs that we left in the root ───────────────────────
remove_build_logs() {
  step "Removing Docker build logs in the repository root"
  for f in build-*.log build-*-fix*.log; do
    if [ -e "${f}" ]; then
      run "rm -f \"${f}\""
    fi
  done
  # campaign logs that ended up in root rather than under results/
  for f in mega_final.log mega_meta.log prueba_meta.log runtime_meta.log \
           overlay_inc_warm*.log overlay_meta.log; do
    if [ -e "${f}" ]; then
      run "rm -f \"${f}\""
    fi
  done
  echo ""
}

# ── remove OS / IDE caches ──────────────────────────────────────────────────
remove_os_caches() {
  step "Removing OS / IDE caches"
  for d in .idea .vscode .npm; do
    if [ -e "${d}" ]; then
      run "rm -rf \"${d}\""
    fi
  done
  if find . -name ".DS_Store" -not -path "./.git/*" 2>/dev/null | grep -q .; then
    run "find . -name .DS_Store -not -path './.git/*' -delete"
  fi
  if [ -e "node_modules" ]; then
    run "rm -rf node_modules"
  fi
  echo ""
}

# ── move CLAUDE.md into docs/JETSON_NOTES.md (only its technical content) ───
move_claude_md() {
  step "Relocating internal context file"
  if [ -e "CLAUDE.md" ]; then
    if [ -e "docs/JETSON_NOTES.md" ]; then
      info "docs/JETSON_NOTES.md already exists (extracted Jetson-specific content)."
      info "CLAUDE.md is internal context for the AI assistant; removing the root copy."
      run "rm -f CLAUDE.md"
    else
      warn "docs/JETSON_NOTES.md does not exist yet. CLAUDE.md will NOT be removed."
      warn "Run scripts/prepare_release.sh again after extracting Jetson notes."
    fi
  fi
  echo ""
}

# ── stale comparison artefacts under metrics/ ───────────────────────────────
remove_stale_metrics() {
  step "Cleaning stale comparison artefacts under metrics/"
  # These were intermediate snapshots from the 4-pattern comparison work.
  # The aggregated CSVs live under dist/metrics/.
  if [ -d "metrics" ]; then
    if [ -e "metrics/comparison-3patterns.md" ]; then
      run "rm -f metrics/comparison-3patterns.md"
    fi
    if [ -e "metrics/comparison-4patterns.md" ]; then
      run "rm -f metrics/comparison-4patterns.md"
    fi
    # The per-pattern .csv files are still useful as historical baselines
    # for the figures regenerator; keeping them.
    info "Per-pattern *.metrics.csv files kept (used by paper's figure scripts)."
  fi
  echo ""
}

# ── update .gitignore so the cleaned-out patterns do not re-appear ──────────
update_gitignore() {
  step "Updating .gitignore"
  local entries=(
    ".DS_Store"
    ".idea/"
    ".vscode/"
    "node_modules/"
    "build-*.log"
    "mega_final.log"
    "mega_meta.log"
    "prueba_meta.log"
    "runtime_meta.log"
    "overlay_inc_warm*.log"
    "overlay_meta.log"
    "results/_campaigns/.regcred_*.yaml"
  )
  for e in "${entries[@]}"; do
    if ! grep -qxF "${e}" .gitignore 2>/dev/null; then
      run "echo \"${e}\" >> .gitignore"
    fi
  done
  echo ""
}

# ── verify the campaign data is present ───────────────────────────
verify_data() {
  step "Verifying measurement data"
  local mega="dist/metrics/meta_campaign_20260526-065922_summary.csv"
  local inc="results/overlay_incremental_warm/20260527-122308/measurements.csv"
  if [ -e "${mega}" ]; then
    info "OK aggregated mega-campaign summary: ${mega}"
  else
    warn "MISSING ${mega} — sync from kb2 before publishing (see sync section below)."
  fi
  if [ -e "${inc}" ]; then
    info "OK overlay incremental warm measurements: ${inc}"
  else
    warn "MISSING ${inc} — sync from kb2 before publishing."
  fi

  local raw_cycles=0
  if [ -d "results/_campaigns" ]; then
    raw_cycles=$(find results/_campaigns -mindepth 1 -maxdepth 1 -type d \
                       -name '2026*' 2>/dev/null | wc -l)
  fi
  info "Raw cycle directories present: ${raw_cycles}"
  if [ "${raw_cycles}" -lt 8 ]; then
    warn "Expected at least 8 raw cycle directories from the mega-campaign."
    warn "Sync from kb2:  rsync -av administrador@kb2:~/Kubernetes-deployment-patterns/results/_campaigns/  results/_campaigns/"
  fi
  echo ""
}

# ── summary ─────────────────────────────────────────────────────────────────
summary() {
  step "Summary"
  if ${APPLY}; then
    info "Clean-up applied. Recommended next steps:"
  else
    info "DRY-RUN complete. To apply, re-run with --apply. Next steps after that:"
  fi
  cat <<EOF
    1. Sync the raw campaign data from kb2 if not already present:
         rsync -av --exclude='_meta_*.log' \\
               administrador@kb2:~/Kubernetes-deployment-patterns/results/_campaigns/ \\
               results/_campaigns/
         rsync -av administrador@kb2:~/Kubernetes-deployment-patterns/results/overlay_incremental_warm/ \\
                   results/overlay_incremental_warm/
         rsync -av administrador@kb2:~/Kubernetes-deployment-patterns/dist/metrics/ \\
                   dist/metrics/

    2. Verify no credentials slipped through:
         grep -rIE "hf_[A-Za-z0-9]{30,}|glpat-|AKIA[0-9A-Z]{16}" \\
              --exclude-dir=.git --exclude-dir=Patterns --exclude-dir=Models .

    3. Stage, review, commit and tag:
         git add -A
         git diff --staged --stat
         git commit -m "release: prepare v1.0.0 snapshot for Zenodo / IEEE Access artifact"
         git tag -a v1.0.0 -m "Reproducibility artifact for IEEE Access submission"
         git push --tags

    4. Connect the GitHub repository to Zenodo (Settings → Zenodo) and
       publish the tag. Zenodo will generate a DOI; paste it into
       CITATION.cff (the doi: field) and into the article's Code and
       Data Availability section.
EOF
  echo ""
}

# ── main ────────────────────────────────────────────────────────────────────
mode_banner
preflight
detect_secrets
remove_wip_drafts
remove_build_logs
remove_os_caches
move_claude_md
remove_stale_metrics
update_gitignore
verify_data
summary
