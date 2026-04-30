# Architecture Gateway API & Envoy Gateway

Ce document explique où et comment organiser les fichiers Gateway API dans ton projet, avec la logique de séparation entre infrastructure (ops) et applications (devs).

---

## Principe fondamental : Séparation des responsabilités

```
┌─────────────────────────────────────────────────────────────┐
│                    INFRASTRUCTURE (Ops)                      │
│  Namespace: envoy-gateway-system                             │
│  ├── GatewayClass (auto-créé par Helm)                      │
│  └── Gateway public-gateway (1 seul par cluster)            │
│       └── Port 80, 443, TLS, Rate Limiting global...        │
└─────────────────────────────────────────────────────────────┘
                              │
                              │ parentRefs
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    APPLICATIONS (Devs)                       │
│  Namespace: default (ou staging, prod...)                    │
│  ├── HTTPRoute mon-app (routage vers les pods)              │
│  └── Service mon-app (cible du backendRefs)                 │
│                                                             │
│  Namespace: api                                              │
│  ├── HTTPRoute api-service                                  │
│  └── Service api-service                                    │
└─────────────────────────────────────────────────────────────┘
```

---

## Arborescence recommandée dans ton projet

```
T-CLO-902-NAN_1/
├── ansible/
│   └── install_gateway-api.yml          # ← Installation du contrôleur
│
├── infra/
│   └── gateway/                         # ← Infrastructure réseau (ops)
│       ├── gateway-public.yaml          # Gateway principale (1 seul)
│       ├── gateway-internal.yaml        # (optionnel) Gateway interne
│       └── kustomization.yaml
│
├── charts/sample-app/templates/         # ← Applications (devs)
│   ├── httproute.yaml                   # HTTPRoute de l'app
│   ├── service.yaml                     # Service cible
│   └── deployment.yaml                  # Pods
│
└── docs/
    └── gateway-api-architecture.md      # ← Ce fichier
```

---

## Détails des composants

### 1. Gateway (Infrastructure) — 1 seul fichier par cluster

**Emplacement :** `infra/gateway/gateway-public.yaml`

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: public-gateway
  namespace: envoy-gateway-system
  annotations:
    # Optionnel : spécifier le type de LoadBalancer AWS
    service.beta.kubernetes.io/aws-load-balancer-type: nlb
spec:
  gatewayClassName: envoy-gateway
  listeners:
    # HTTP standard
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: All # Permet aux routes de tous les namespaces de s'y brancher

    # HTTPS avec TLS
    - name: https
      protocol: HTTPS
      port: 443
      tls:
        mode: Terminate
        certificateRefs:
          - name: wildcard-tls-secret # Secret contenant cert+key
      allowedRoutes:
        namespaces:
          from: All
```

**Qui le gère :** L'équipe Ops/Infrastructure (toi avec Ansible ou manuellement)

**Combien :** **UN SEUL** par cluster (ou un par zone si multi-AZ)

---

### 1.1 Configuration TLS dans le Gateway

#### `tls.mode: Terminate` — Déchiffrement TLS au Gateway

Cette configuration signifie que **Envoy Gateway gère le HTTPS** :

```
Internet ──► [HTTPS:443] ──► [Gateway déchiffre TLS] ──► [HTTP vers pods]
              ↑                                ↓
         Certificat TLS                    Trafic en clair
         (wildcard-tls-secret)               (HTTP) dans le cluster
```

**Pourquoi `Terminate` ?**

- Le Gateway **termine** (déchiffre) la connexion TLS
- Les pods reçoivent du **HTTP non-chiffré** (plus simple, pas besoin de cert dans chaque app)
- Le Gateway fait office de **point unique de gestion TLS**

**Alternative : `mode: Passthrough`**

- Le Gateway ne touche pas au TLS
- Le trafic chiffré passe directement aux pods (qui doivent gérer leurs propres certificats)
- Utile pour du SNI routing ou des besoins spécifiques de chiffrement end-to-end

#### `certificateRefs` — Référence à un Secret Kubernetes

Le `certificateRefs` pointe vers un **Secret Kubernetes de type TLS** :

```yaml
certificateRefs:
  - name: wildcard-tls-secret # ← Nom du Secret
    namespace: envoy-gateway-system # ← Optionnel, défaut = namespace du Gateway
```

**Créer le Secret TLS :**

```bash
# Depuis des fichiers cert + key
kubectl create secret tls wildcard-tls-secret \
  --cert=path/to/tls.crt \
  --key=path/to/tls.key \
  -n envoy-gateway-system
```

**Ou en YAML :**

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: wildcard-tls-secret
  namespace: envoy-gateway-system
type: kubernetes.io/tls # ← Type obligatoire
data:
  tls.crt: <base64-encoded-certificate>
  tls.key: <base64-encoded-private-key>
```

**Structure du Secret TLS :**

| Clé       | Contenu                 |
| --------- | ----------------------- |
| `tls.crt` | Certificat public (PEM) |
| `tls.key` | Clé privée (PEM)        |

#### Flux de trafic avec TLS

```
Client ──► https://mon-app.example.com ──┐
                                         │
    [Résolution DNS → IP du LoadBalancer]  │
                                         │
    [Handshake TLS] ◄──── Certificat wildcard-tls-secret
    (vérification *.example.com)         │
                                         │
    [HTTP chiffré (HTTPS)]               │
           │                             │
           ▼                             │
    ┌──────────────┐                     │
    │   Gateway    │── Déchiffre TLS ────┤
    │  (Envoy)     │                     │
    └──────────────┘                     │
           │                             │
           │ HTTP en clair               │
           ▼                             │
    ┌──────────────┐                     │
    │   Service    │─────────────────────┘
    │   mon-app    │
    └──────────────┘
```

#### `allowedRoutes` : Contrôle d'accès au Gateway

```yaml
allowedRoutes:
  namespaces:
    from: All # Tous les namespaces peuvent créer des HTTPRoutes
```

**Options :**

- `from: All` — Tous les namespaces (ouvert)
- `from: Same` — Seulement le namespace du Gateway (restrictif)
- `from: Selector` — Namespaces avec un label spécifique :

```yaml
allowedRoutes:
  namespaces:
    from: Selector
    selector:
      matchLabels:
        gateway-access: 'true'
```

---

### 2. HTTPRoute (Application) — 1 par service exposé

**Emplacement :** Dans chaque Helm Chart (`charts/sample-app/templates/httproute.yaml`)

Ton fichier existe déjà : `charts/sample-app/templates/httproute.yaml`

**Activation dans `values.yaml` :**

```yaml
httpRoute:
  enabled: true
  parentRefs:
    - name: public-gateway
      namespace: envoy-gateway-system
  hostnames:
    - 'sample-app.example.com'
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: sample-app
          port: 80
          weight: 100
```

**Qui le gère :** Chaque développeur dans son propre namespace

**Combien :** **Un par application/service** à exposer

---

## Mapping : Ancien Ingress vs Nouveau Gateway API

| Concept Ancien             | Emplacement Ancien                | Concept Nouveau        | Emplacement Nouveau                 |
| -------------------------- | --------------------------------- | ---------------------- | ----------------------------------- |
| Ingress Controller (NGINX) | `infra/ingress/`                  | GatewayClass + Gateway | `infra/gateway/gateway-public.yaml` |
| Ingress resource par app   | `charts/*/templates/ingress.yaml` | HTTPRoute par app      | `charts/*/templates/httproute.yaml` |
| Service (même)             | `charts/*/templates/service.yaml` | Service (même)         | `charts/*/templates/service.yaml`   |

---

## Exemple complet de flux de déploiement

### Étape 1 : Déployer l'infrastructure (une fois)

```bash
# 1. Installer Envoy Gateway (crée GatewayClass automatiquement)
ansible-playbook -i inventory.yml ansible/install_gateway-api.yml

# 2. Déployer le Gateway public (si pas déjà fait par Helm)
kubectl apply -f infra/gateway/gateway-public.yaml

# 3. Vérifier
kubectl get gateway -n envoy-gateway-system
# NAME             CLASS           ADDRESS        READY   AGE
# public-gateway   envoy-gateway   15.237.15.14   True    5m
```

### Étape 2 : Déployer une application (pour chaque app)

```bash
# Le HTTPRoute est dans le chart, activé via values.yaml
helm install sample-app charts/sample-app -f charts/sample-app/secrets.yaml

# Vérifier que la route est attachée au gateway
kubectl get httproute
# NAME       HOSTNAMES               AGE
# sample-app    sample-app.example.com     10s
```

### Étape 3 : Vérifier le routage

```bash
# Voir la configuration complète envoyée à Envoy
kubectl get gateway public-gateway -n envoy-gateway-system -o yaml

# Voir les routes programmées
kubectl get httproute -A

# Test depuis l'extérieur
curl -H "Host: sample-app.example.com" http://15.237.15.14/
```

---

## Cas d'usage avancés

### Plusieurs Gateways (multi-environnement)

```
infra/gateway/
├── gateway-public.yaml      # Production (port 80/443)
├── gateway-staging.yaml     # Staging (port 8080)
└── gateway-internal.yaml    # Services internes (VPC uniquement)
```

```yaml
# gateway-staging.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: staging-gateway
  namespace: envoy-gateway-system
spec:
  gatewayClassName: envoy-gateway
  listeners:
    - name: http-staging
      protocol: HTTP
      port: 8080 # Port différent pour staging
      allowedRoutes:
        namespaces:
          from: Selector
          selector:
            matchLabels:
              env: staging # Seulement les namespaces labelisés "staging"
```

### Routage avancé avec HTTPRoute

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: api-route
  namespace: default
spec:
  parentRefs:
    - name: public-gateway
      namespace: envoy-gateway-system
  hostnames:
    - 'api.example.com'
  rules:
    # Route API vers v2 (Canary : 10% du trafic)
    - matches:
        - headers:
            - name: X-Canary
              value: 'true'
      backendRefs:
        - name: api-v2
          port: 80
          weight: 100

    # Route par path
    - matches:
        - path:
            type: PathPrefix
            value: /api/v2
      backendRefs:
        - name: api-v2
          port: 80

    # Route par défaut
    - matches:
        - path:
            type: PathPrefix
            value: /api/v1
      backendRefs:
        - name: api-v1
          port: 80
          weight: 90
        - name: api-v2
          port: 80
          weight: 10 # 10% vers v2 pour test
```

---

## Checklist migration Ingress → Gateway API

| Étape | Action                      | Fichier concerné                          |
| ----- | --------------------------- | ----------------------------------------- |
| 1     | Désactiver l'ancien Ingress | `values.yaml` : `ingress.enabled: false`  |
| 2     | Créer le Gateway (ops)      | `infra/gateway/gateway-public.yaml`       |
| 3     | Activer HTTPRoute (dev)     | `values.yaml` : `httpRoute.enabled: true` |
| 4     | Configurer parentRefs       | Pointer vers `public-gateway`             |
| 5     | Tester                      | `curl` avec Host header                   |
| 6     | Supprimer ancien Ingress    | `kubectl delete ingress xxx`              |

---

## Commandes de debug

```bash
# Voir tous les objets Gateway API
kubectl get gateway,httproute,tlsroute -A

# Voir la configuration détaillée d'un Gateway
kubectl describe gateway public-gateway -n envoy-gateway-system

# Voir les routes attachées
kubectl describe httproute mon-app -n default

# Voir les logs du contrôleur Envoy
kubectl logs -n envoy-gateway-system -l app.kubernetes.io/name=envoy-gateway

# Voir la configuration Envoy générée
kubectl get configmap -n envoy-gateway-system envoy-gateway-config -o yaml
```

---

## Procédure de déploiement complète

### Comment Ansible se connecte à tes VMs AWS

Ansible utilise SSH pour se connecter à tes instances EC2. La configuration est dans `ansible/inventory.yml` :

```yaml
# Connexion directe au Master (IP publique)
master:
  ansible_host: 15.237.15.14 # ← IP publique AWS
  ansible_ssh_private_key_file: ~/.ssh/kubequest.pem

# Connexion aux Workers via ProxyCommand (IP privées uniquement)
worker1:
  ansible_host: 10.0.3.198 # ← IP privée (pas d'accès Internet direct)
  ansible_ssh_common_args: '-o ProxyCommand="ssh -i ~/.ssh/kubequest.pem ... -W %h:%p ec2-user@15.237.15.14"'
```

**Schéma de connexion :**

```
Ton PC (local) ──SSH──► Master (15.237.15.14) ──tunnel──► Worker1 (10.0.3.198)
                              ↑                              ↑
                         IP publique                    IP privée (VPC)
                    (accessible depuis               (accessible uniquement
                     ton réseau)                       via le Master)
```

**Explication du ProxyCommand :**

- `-W %h:%p` : Crée un tunnel TCP vers l'hôte et port cible
- Ansible se connecte d'abord au Master, puis "rebondit" vers les Workers via le réseau privé AWS

---

### Prérequis avant déploiement

**Sur ton PC (contrôleur Ansible) :**

```bash
# 1. Vérifier qu'Ansible est installé
ansible --version
# Si non : pip install ansible

# 2. Vérifier la clé SSH AWS
ls ~/.ssh/kubequest.pem
# Si absent : récupérer la clé depuis la console AWS EC2

# 3. Vérifier les permissions de la clé (important !)
chmod 600 ~/.ssh/kubequest.pem

# 4. Tester la connectivité SSH
cd ansible
ansible-playbook -i inventory.yml test_connectivity.yml
# Doit afficher "ping" réussi pour master, worker1, worker2, worker3
```

**Configuration requise :**

- Ansible ≥ 2.9
- Python ≥ 3.8
- Clé SSH `~/.ssh/kubequest.pem` (fournie par AWS)
- Accès réseau au Master (IP publique dans `inventory.yml`)

---

### Partie 1 : Déployer l'infrastructure Gateway API

**Étape 1 : Installer Envoy Gateway (une seule fois par cluster)**

```bash
cd ansible

# Déployer Gateway API CRDs + Envoy Gateway via Helm
ansible-playbook -i inventory.yml install_gateway-api.yml
```

Ce playbook exécute sur le Master :

1. Installation des CRDs Gateway API (v1.5.0)
2. Ajout du repo Helm Envoy Gateway
3. Installation du chart Helm Envoy Gateway (v1.7.1)

**Étape 2 : Déployer le Gateway public**

```bash
# Se connecter au Master pour kubectl
ssh -i ~/.ssh/kubequest.pem ec2-user@15.237.15.14

# Sur le Master, déployer le Gateway
sudo kubectl apply -f /path/to/infra/gateway/gateway-public.yaml
# Ou depuis ton PC avec kubectl configuré :
kubectl apply -f infra/gateway/gateway-public.yaml
```

**Étape 3 : Vérifier l'installation**

```bash
# Vérifier le GatewayClass (créé automatiquement)
kubectl get gatewayclass
# NAME             CONTROLLER
# envoy-gateway    gateway.envoyproxy.io/gatewayclass-controller

# Vérifier le Gateway
kubectl get gateway -n envoy-gateway-system
# NAME             CLASS           ADDRESS        READY   AGE
# public-gateway   envoy-gateway   15.237.15.14   True    5m

# Vérifier les pods Envoy Gateway
kubectl get pods -n envoy-gateway-system
# NAME                             READY   STATUS
# envoy-gateway-xxx                2/2     Running
```

---

### Partie 2 : Déployer une application avec HTTPRoute

**Étape 1 : Configurer values.yaml**

Dans `charts/sample-app/values.yaml` :

```yaml
httpRoute:
  enabled: true
  parentRefs:
    - name: public-gateway
      namespace: envoy-gateway-system
  hostnames:
    - 'sample-app.example.com' # ← Ton domaine
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: sample-app
          port: 80
          weight: 100
```

**Étape 2 : Déployer avec Helm**

```bash
# Depuis ton PC (ou le Master avec kubectl configuré)
helm install sample-app charts/sample-app -f charts/sample-app/secrets.yaml

# Ou mettre à jour si déjà déployé
helm upgrade sample-app charts/sample-app -f charts/sample-app/secrets.yaml
```

**Étape 3 : Vérifier le déploiement**

```bash
# Vérifier l'HTTPRoute
kubectl get httproute
# NAME         HOSTNAMES                 AGE
# sample-app   sample-app.example.com    30s

# Vérifier que le Service existe
kubectl get svc sample-app
# NAME         TYPE        CLUSTER-IP      PORT(S)
# sample-app   ClusterIP   10.96.123.45    80/TCP

# Vérifier les pods
kubectl get pods -l app.kubernetes.io/name=sample-app
```

---

### Partie 3 : Tester l'accès depuis l'extérieur

**Méthode 1 : Avec le domaine configuré**

```bash
# Si tu as configuré DNS ou /etc/hosts
curl http://sample-app.example.com
# Doit retourner la réponse de ton application
```

**Méthode 2 : Avec l'IP du LoadBalancer et Host header**

```bash
# Récupérer l'IP du Gateway (AWS ELB)
kubectl get gateway public-gateway -n envoy-gateway-system -o jsonpath='{.status.addresses[0].value}'
# 15.237.15.14

# Tester avec curl
curl -H "Host: sample-app.example.com" http://15.237.15.14/
```

**Méthode 3 : Port-forward pour test local**

```bash
# Exposer le Service localement (pas besoin du Gateway)
kubectl port-forward svc/sample-app 8080:80
# Puis ouvrir http://localhost:8080 dans ton navigateur
```

---

### Récapitulatif des commandes

| Action                  | Commande                                                          |
| ----------------------- | ----------------------------------------------------------------- |
| **Test connexion SSH**  | `ansible-playbook -i inventory.yml test_connectivity.yml`         |
| **Install Gateway API** | `ansible-playbook -i inventory.yml install_gateway-api.yml`       |
| **Déployer Gateway**    | `kubectl apply -f infra/gateway/gateway-public.yaml`              |
| **Déployer app**        | `helm install sample-app charts/sample-app -f secrets.yaml`       |
| **Mettre à jour app**   | `helm upgrade sample-app charts/sample-app -f secrets.yaml`       |
| **Supprimer app**       | `helm uninstall sample-app`                                       |
| **Voir routes**         | `kubectl get httproute`                                           |
| **Debug Gateway**       | `kubectl describe gateway public-gateway -n envoy-gateway-system` |
