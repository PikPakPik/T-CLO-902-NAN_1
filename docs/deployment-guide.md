# Guide de déploiement — Gateway API + Headlamp (mode hostNetwork)

Ce document **justifie les choix techniques** et donne la **procédure de déploiement complète** (from scratch) du chemin d'ingress du cluster et de Headlamp.

Pour comprendre **comment ça fonctionne** (concepts Gateway API, flux d'une requête, ressources), voir [`gateway-api-architecture.md`](./gateway-api-architecture.md).

---

## 1. Contexte du cluster

- **kubeadm self-managed** sur AWS EC2 (pas EKS).
- 1 master + 3 workers, dans un VPC privé.
- Elastic IP `15.237.15.14` attachée au master.
- **Aucun cloud-controller AWS installé** dans le cluster (ni `aws-cloud-controller-manager`, ni `aws-load-balancer-controller`).
- Inventaire Ansible : `ansible/inventory.yml`.

Cette contrainte conditionne directement le choix d'exposition.

---

## 2. Pourquoi hostNetwork sur le master ?

### 2.1 Les contraintes réseau

- **Workers = IP privées uniquement** (10.0.3.x) → non joignables depuis Internet
- **Master = EIP publique** (15.237.15.14) avec port 80 ouvert dans le SG
- **Pas de cloud-controller AWS** → LoadBalancer impossible
- **Pas de permissions AWS** pour créer NLB/TargetGroup

### 2.2 Les options envisagées

| Option                               | Description                                                    | Verdict                                                         |
| ------------------------------------ | -------------------------------------------------------------- | --------------------------------------------------------------- |
| **A — NodePort + NLB manuel**        | Service Envoy en NodePort sur workers + NLB AWS créé à la main | ❌ Requiert création de ressource AWS (refusé)                  |
| **B — aws-load-balancer-controller** | LoadBalancer auto-provisionné par contrôleur AWS               | ❌ Trop de plomberie IAM/VPC, permissions AWS requises          |
| **C — hostNetwork sur master**       | Pod Envoy utilise réseau hôte, écoute sur master:80            | ✅ **Retenu** : aucune ressource AWS, marche avec EIP existante |

### 2.3 Pourquoi hostNetwork (Option C)

Avantages :

- **Aucune ressource AWS à créer** (pas de NLB, pas de TG)
- **Utilise l'EIP existante** (15.237.15.14) déjà attachée au master
- **Port 80 standard** (pas de :30080 dans l'URL)
- **Déploiement 100% Ansible/K8s** (pas de manipulation console)

Inconvénients :

- **Anti-pattern** : dataplane sur le control-plane (pas HA)
- **SPOF master** : si le master tombe, plus d'accès Internet

⚠️ Acceptable pour un cluster dev/test. Pour la prod, migrer vers NLB ou EKS.

---

## 3. Choix de design détaillés (EnvoyProxy)

Le CRD `EnvoyProxy` (référencé par `GatewayClass.parametersRef`) porte tous les choix d'infrastructure du dataplane. Source : `ansible/deploy_gateway.yml`.

| Paramètre                       | Valeur                                  | Justification                                       |
| ------------------------------- | --------------------------------------- | --------------------------------------------------- |
| `hostNetwork`                   | `true`                                  | Pod utilise réseau hôte, écoute sur master:80       |
| `dnsPolicy`                     | `ClusterFirstWithHostNet`               | DNS Kubernetes + DNS hôte (requis avec hostNetwork) |
| `nodeSelector`                  | `kubernetes.io/hostname: <master>`      | Force le pod sur le master                          |
| `tolerations`                   | `node-role.kubernetes.io/control-plane` | Permet scheduler sur control-plane                  |
| `gateway.listeners`             | `HTTP:80` uniquement                    | TLS ajouté plus tard (§6.1)                         |
| `allowedRoutes.namespaces.from` | `All`                                   | Multi-tenant : n'importe quel ns peut s'attacher    |

---

## 4. Architecture finale

```
Internet  ──TCP:80──►  Master (EIP 15.237.15.14)
                            │
                            ▼
                    Envoy dataplane (hostNetwork)
                            │
                            ▼
                    HTTPRoute (matching hostname/path)
                            │
                            ▼
                    Service ClusterIP de l'app → Pods
```

Voir le schéma détaillé dans `docs/gateway-api-architecture.md` §2.

---

## 5. Procédure de déploiement (from scratch)

### 5.1 Prérequis

- Ansible ≥ 2.9 sur ton PC.
- Clé SSH `~/.ssh/kubequest.pem` (chmod 600).
- Cluster k8s déjà up (master + 3 workers).
- Variable `k8s_master_config` définie dans `ansible/group_vars/` (pointe sur `/etc/kubernetes/admin.conf`).
- Collection Ansible : `ansible-galaxy collection install kubernetes.core`.

### 5.2 Test de connectivité

```bash
cd ansible
ansible-playbook -i inventory.yml test_connectivity.yml
```

### 5.3 Reset (si une ancienne install existe)

```bash
ansible-playbook -i inventory.yml cleanup_gateway.yml
```

Supprime, dans l'ordre : `HTTPRoute headlamp` → `Gateway public-gateway` → `GatewayClass envoy-gateway` → `EnvoyProxy envoy-hostnetwork` → Helm release `envoy-gateway` → namespace `envoy-gateway-system`. Idempotent.

### 5.4 Installer Envoy Gateway (CRDs + contrôleur)

```bash
ansible-playbook -i inventory.yml install_gateway-api.yml
```

Helm chart `envoy-gateway-helm v1.8.0` (embarque tous les CRDs Gateway API + Envoy Gateway). Le playbook attend que le Deployment `envoy-gateway` soit `Available`.

Vérif :

```bash
kubectl get pods -n envoy-gateway-system
# envoy-gateway-xxx   1/1   Running
```

### 5.5 Déployer le Gateway public

```bash
ansible-playbook -i inventory.yml deploy_gateway.yml
```

Crée dans l'ordre :

1. `EnvoyProxy envoy-hostnetwork` (hostNetwork, nodeSelector master, tolerations).
2. `GatewayClass envoy-gateway` avec `parametersRef` vers cet `EnvoyProxy`.
3. `Gateway public-gateway` (listener HTTP:80, `allowedRoutes.namespaces.from: All`).

Vérif :

```bash
kubectl get gateway -n envoy-gateway-system
# NAME             CLASS           ADDRESS   PROGRAMMED   AGE
# public-gateway   envoy-gateway   ...       True         1m

kubectl get pods -n envoy-gateway-system -o wide
# envoy-... pod doit être sur le master

kubectl get svc -n envoy-gateway-system
# envoy-... ClusterIP (pas de NodePort avec hostNetwork)
```

### 5.6 Déployer Headlamp

```bash
ansible-playbook -i inventory.yml deploy_headlamp.yml
```

Le rôle `ansible/roles/headlamp/tasks/main.yml` fait :

1. `helm upgrade --install headlamp headlamp/headlamp -n headlamp` (Service ClusterIP créé par le chart).
2. `kubectl apply -k infra/headlamp/` (ServiceAccount, ClusterRole read-only, ClusterRoleBinding, **HTTPRoute** ciblant `public-gateway`).

Vérif :

```bash
kubectl get httproute -n headlamp
# headlamp   ["headlamp.15.237.15.14.nip.io"]   ...

kubectl get pods -n headlamp
# headlamp-xxx   1/1   Running
```

### 5.7 Accès à l'UI Headlamp

```bash
# Depuis ton PC :
xdg-open http://headlamp.15.237.15.14.nip.io/

# Générer un token (sur le master, à la demande, durée limitée) :
ssh ec2-user@15.237.15.14
sudo KUBECONFIG=/etc/kubernetes/admin.conf \
  kubectl create token headlamp-admin -n headlamp --duration=48h
```

Coller le token **une seule fois** dans l'UI. Ne pas le commiter / coller dans des logs.

---

## 6. Récapitulatif des commandes

| Action                | Commande                                                         |
| --------------------- | ---------------------------------------------------------------- |
| Test SSH              | `ansible-playbook -i inventory.yml test_connectivity.yml`        |
| Reset complet         | `ansible-playbook -i inventory.yml cleanup_gateway.yml`          |
| Install Envoy Gateway | `ansible-playbook -i inventory.yml install_gateway-api.yml`      |
| Deploy public Gateway | `ansible-playbook -i inventory.yml deploy_gateway.yml`           |
| Deploy Headlamp       | `ansible-playbook -i inventory.yml deploy_headlamp.yml`          |
| Token Headlamp        | `kubectl create token headlamp-admin -n headlamp --duration=48h` |

---

## 7. Évolutions possibles

### 7.1 HTTPS

Ajouter un 2e listener dans `Gateway public-gateway` :

```yaml
- name: https
  protocol: HTTPS
  port: 443
  tls:
    mode: Terminate
    certificateRefs:
      - name: wildcard-tls
  allowedRoutes:
    namespaces:
      from: All
```

Certificats : `cert-manager` + Let's Encrypt (DNS-01 sur Route 53) ou import manuel d'un cert dans un `Secret kubernetes.io/tls`.

### 7.2 Passer en cloud-native (Option B future)

Installer `aws-load-balancer-controller` (Helm) + setup IAM. Permet alors de :

- Remplacer `hostNetwork` par `LoadBalancer` avec annotations NLB.
- Le contrôleur provisionne automatiquement NLB + TargetGroup.
- Supprimer hostNetwork (dataplane sur workers, HA réelle).

Migration sans downtime possible (Gateway API ne change pas, seul `EnvoyProxy` est modifié).

### 7.3 Observabilité

- Activer les access logs Envoy (`EnvoyProxy.spec.telemetry.accessLog`).
- Brancher Prometheus (le chart envoy-gateway expose `/metrics`).
- Tracing OpenTelemetry via `EnvoyProxy.spec.telemetry.tracing`.

---

## 8. Troubleshooting

| Symptôme                                        | Cause probable                                                      | Diagnostic                                                                                              |
| ----------------------------------------------- | ------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- | ----------------------- |
| `Gateway` reste `Programmed=False`              | EnvoyProxy mal référencé ou pod Envoy non schedulable sur master    | `kubectl describe gateway -n envoy-gateway-system` ; `kubectl get pods -n envoy-gateway-system -o wide` |
| Pod Envoy pas sur le master                     | `nodeSelector` ou `ansible_hostname` incorrect                      | Vérifier `kubectl get pods -n envoy-gateway-system -o wide`                                             |
| Accès Internet ne fonctionne pas                | Port 80 fermé sur SG master ou EIP détachée                         | Vérifier SG master + `curl http://15.237.15.14/` depuis ton PC                                          |
| 404 sur http://15.237.15.14 pour un host valide | HTTPRoute pas attachée (mauvais `parentRefs`) ou hostname différent | `kubectl get httproute -A -o wide` ; vérifier `parentRefs.namespace`                                    |
| Token Headlamp rejeté                           | Token expiré (durée 48h)                                            | Régénérer : `kubectl create token headlamp-admin -n headlamp --duration=48h`                            |
| Conflit de port 80 sur master                   | Autre service utilise déjà port 80 sur le master                    | `sudo netstat -tlnp                                                                                     | grep :80` sur le master |
