#!/usr/bin/env bash
# =============================================================================
# up.sh — Remettre le TP (cluster kind + Jenkins + app flask) en état
# TP3 ENI — Mini Projet Jenkins / Docker / Kubernetes
# =============================================================================
# USAGE :  ./jenkins_k8s/up.sh [--with-portainer] [--timeout N]
#
# Après un reboot de la machine, le conteneur du nœud kind redémarre avec
# Docker, mais les pods peuvent rester bloqués :
#   - pods Unknown ou ImagePullBackOff : ils ont tenté de (re)partir alors
#     que le registry du cluster ne démarrait pas encore
#   - jenkins-0 en Unknown.
# Ce script nettoie ces pods (le Deployment/StatefulSet les recrée), puis
# attend que tout soit vert et affiche les URLs.
#
# Idempotent : le lancer plusieurs fois ne casse rien.
# =============================================================================

set -euo pipefail

CLUSTER="tp-jenkins"
CTX="kind-${CLUSTER}"
NS="jenkins"
REGISTRY_URL="http://localhost:4000/v2/"
JENKINS_URL="http://localhost:32000/login"
APP_URL="http://localhost:31000/hello/"
PORTAINER_MANIFEST="https://downloads.portainer.io/ce2-45/portainer-agent-k8s-nodeport.yaml"
PORTAINER_AGENT_PORT="30778"   # nodePort défini dans le manifests Portainer
TIMEOUT=180
WITH_PORTAINER=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-portainer) WITH_PORTAINER=1 ;;
    --timeout) TIMEOUT="$2"; shift ;;
    -h|--help) sed -n '4,10p' "$0"; exit 0 ;;
    *) echo "Option inconnue: $1"; exit 1 ;;
  esac
  shift
done

kc() { kubectl --context "$CTX" "$@"; }

log() { printf '\033[1;36m[up.sh]\033[0m %s\n' "$*"; }
ok()  { printf '  \033[1;32m✔\033[0m %s\n' "$*"; }
ko()  { printf '  \033[1;31m✗ %s\033[0m\n' "$*"; }

# Attendre qu'une URL HTTP réponde (-w code), pendant TIMEOUT s
wait_url() { # $1 = url, $2 = code attendu (défaut 200)
  local url="$1" want="${2:-200}" n=0
  until [[ "$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 1 "$url" || true)" == "$want" ]]; do
    (( n += 3 )); (( n > TIMEOUT )) && return 1
    sleep 3
  done
}

# =============================================================================
# 0. Le cluster existe-t-il ?
# =============================================================================
log "Vérification du cluster kind '${CLUSTER}'..."
if ! kind get clusters 2>/dev/null | grep -q "^${CLUSTER}$"; then
  ko "Cluster '${CLUSTER}' introuvable."
  echo "  Recrée-le avec :"
  echo "    kind create cluster --name ${CLUSTER} --config \$(dirname \$0)/kind-config.yaml"
  exit 1
fi
ok "cluster kind '${CLUSTER}' présent"

# =============================================================================
# 1. Le nœud est-il Ready ?
# =============================================================================
log "Attente du nœud Ready..."
if kc wait --for=condition=Ready node --all --timeout="${TIMEOUT}s" >/dev/null 2>&1; then
  ok "nœud Ready"
else
  ko "nœud toujours pas Ready après ${TIMEOUT}s — vérifie docker/kubelet"
  exit 1
fi

# =============================================================================
# 2. Purger les pods bloqués (Unknown / ImagePull* / CrashLoop)
# =============================================================================
log "Recherche de pods bloqués..."
STUCK=$(kc get pods -A --no-headers 2>/dev/null \
  | awk '$4 ~ /^(Unknown|ImagePullBackOff|ErrImagePull|CrashLoopBackOff|Pending)$/ && $4 != "Pending" || $4 == "Pending" {print $1, $2, $4}' \
  | grep -vE 'Pending' || true)

# (les Pending vrais comme les images qui téléchargent ne sont PAS bloqués)
if [[ -n "${STUCK}" ]]; then
  while read -r ns pod state; do
    log "  → suppression de ${pod} (${ns}) [${state}] — le controller va le recréer"
    kc delete pod "${pod}" -n "${ns}" --wait=false >/dev/null 2>&1 || true
  done <<< "${STUCK}"
else
  ok "aucun pod bloqué"
fi

# =============================================================================
# 3. Registry en écoute (prérequis du pull de l'app)
# =============================================================================
log "Attente du registry (${REGISTRY_URL})..."
if wait_url "${REGISTRY_URL}"; then
  ok "registry opérationnel"
else
  ko "registry pas joignable — vois : kubectl -n ${NS} get deploy registry"
fi

# =============================================================================
# 4. Jenkins
# =============================================================================
log "Attente de Jenkins (${JENKINS_URL})..."
if kc wait pods -n "${NS}" -l app.kubernetes.io/component=jenkins-master \
     --for=condition=Ready --timeout="${TIMEOUT}s" >/dev/null 2>&1 \
   && wait_url "$JENKINS_URL"; then
  ok "jenkins répond"
else
  ko "jenkins indisponible — reprend avec : kubectl delete pod jenkins-0 -n ${NS}"
fi

# =============================================================================
# 5. App flask (déployée par le pipeline)
# =============================================================================
log "Attende de l'app flask (${APP_URL})..."
if kc -n "${NS}" get deploy pythontest >/dev/null 2>&1; then
  # Un rollout restart ne déclenche pas de pull tant que l'ancien pod tourne.
  # On ne le force que s'il n'y a aucun pod Running (cas ImagePullBackOff).
  if ! kc -n "${NS}" get pods -l app=pythontest --no-headers 2>/dev/null | head -1 | grep -qz 'Running'; then
    log "  → pods pythontest non fonctionnels : rollout restart"
    kc -n "${NS}" rollout restart deployment/pythontest >/dev/null 2>&1 || true
  fi
  if kc -n "${NS}" wait --for=condition=available deployment/pythontest \
       --timeout="${TIMEOUT}s" >/dev/null 2>&1 && wait_url "$APP_URL"; then
    ok "app flask répond"
  else
    ko "app flask indisponible — relance le pipeline Jenkins"
  fi
else
  ko "deployment/pythontest absent — relance un build du pipeline Jenkins"
fi

# =============================================================================
# 6. (Optionnel) Agent Portainer — pour la vue GUI du cluster
# =============================================================================
if [[ "${WITH_PORTAINER}" == "1" ]]; then
  log "Agent Portainer..."
  if kc get ns portainer >/dev/null 2>&1 && kc -n portainer get pods --no-headers 2>/dev/null | grep -q Running; then
    ok "agent Portainer déjà en place"
  else
    log "  → déploiement de l'agent dans le cluster"
    kubectl --context "$CTX" apply -f "$PORTAINER_MANIFEST" >/dev/null
    kc -n portainer wait --for=condition=available deployment/portainer-agent \
        --timeout="${TIMEOUT}s" >/dev/null 2>&1 || true
    NODE_IP=$(kc get node "${CLUSTER}-control-plane" \
      -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
    ok "agent Portainer déployé  →  environment URL: ${NODE_IP}:${PORTAINER_AGENT_PORT}"
    echo "     (dans Portainer : Environments → tp-jenkins)
"
  fi
fi

# =============================================================================
# Résumé
# =============================================================================
echo
echo "════════════════════════════════════════════════════════════"
echo "  TP Jenkins k8s — état du cluster"
echo "════════════════════════════════════════════════════════════"
echo "  Jenkins UI   : http://localhost:32000        (admin / admin)"
echo "  App flask    : http://localhost:31000/hello/"
echo "  Registry     : http://localhost:4000/v2/_catalog"
echo "  Blue Ocean   : http://localhost:32000/blue"
echo "  Pods         : kubectl -n ${NS} get pods"
echo "════════════════════════════════════════════════════════════"
