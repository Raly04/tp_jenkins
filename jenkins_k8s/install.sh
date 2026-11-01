#!/bin/bash
# =============================================================================
# install.sh — Installer Jenkins sur Kubernetes avec Helm
# TP3 ENI — Mini Projet Jenkins / Docker / Kubernetes
# =============================================================================
# Prérequis : kubectl + helm installés, un cluster Kubernetes accessible
# =============================================================================

set -e

NAMESPACE="jenkins"
RELEASE_NAME="jenkins"
VALUES_FILE="values.yaml"
CHART_REPO="https://charts.jenkins.io/"
CHART_NAME="jenkins/jenkins"

echo "============================================================"
echo "  Installation de Jenkins sur Kubernetes (Helm)"
echo "============================================================"

# --- 1. Vérifier les outils ---
echo "[1/7] Vérification des outils..."
if ! command -v kubectl &> /dev/null; then
    echo "ERREUR: kubectl n'est pas installé"
    exit 1
fi
if ! command -v helm &> /dev/null; then
    echo "ERREUR: helm n'est pas installé"
    exit 1
fi
echo "  kubectl: $(kubectl version --client --short 2>/dev/null || kubectl version --client 2>&1 | head -1)"
echo "  helm:    $(helm version --short 2>/dev/null || helm version 2>&1 | head -1)"

# --- 2. Vérifier le cluster ---
echo "[2/7] Vérification du cluster Kubernetes..."
if ! kubectl cluster-info &> /dev/null; then
    echo "ERREUR: Aucun cluster Kubernetes accessible"
    echo "        Démarrez minikube, kind, k3s ou configurez un accès distant"
    exit 1
fi
echo "  Cluster accessible OK"

# --- 3. Créer le namespace ---
echo "[3/7] Création du namespace '$NAMESPACE'..."
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl config set-context --current --namespace="$NAMESPACE"

# --- 4. Ajouter le repo Helm Jenkins ---
echo "[4/7] Ajout du dépôt Helm Jenkins..."
helm repo add jenkins "$CHART_REPO" 2>/dev/null || helm repo update jenkins
helm repo update

# --- 5. Installer Jenkins avec Helm ---
echo "[5/7] Installation de Jenkins (release: $RELEASE_NAME)..."
helm install "$RELEASE_NAME" "$CHART_NAME" -f "$VALUES_FILE" --namespace "$NAMESPACE"

# --- 6. Attendre que le pod soit prêt ---
echo "[6/7] Attente que le pod Jenkins soit prêt..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/component=jenkins-master -n "$NAMESPACE" --timeout=300s 2>/dev/null || \
kubectl wait --for=condition=ready pod -l app=jenkins -n "$NAMESPACE" --timeout=300s 2>/dev/null || \
echo "  (attente manuelle requise - vérifiez avec: kubectl get pods -n $NAMESPACE)"

# --- 7. Afficher les informations d'accès ---
echo "[7/7] Installation terminée !"
echo ""
echo "============================================================"
echo "  ACCÈS À JENKINS"
echo "============================================================"
echo "  URL: http://localhost:32000  (NodePort)"
echo "  Identifiants: admin / admin  (modifiez dans values.yaml)"
echo ""
echo "  Pour exposer le port localement (si nécessaire):"
echo "    kubectl port-forward svc/$RELEASE_NAME 32000:8080 -n $NAMESPACE"
echo ""
echo "  Ensuite, installez le plugin Blue Ocean depuis l'UI Jenkins:"
echo "    Gérer Jenkins > Gérer les plugins > Disponibles > Blue Ocean"
echo "============================================================"