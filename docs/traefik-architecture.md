# Traefik - Architecture et déploiement

## Vue d'ensemble

Traefik est déployé comme **contrôleur Gateway API** sur le cluster Kubernetes. Il écoute directement sur le port 80 de l'IP publique du master (15.237.15.14) grâce au mode `hostNetwork`, et route le trafic HTTP vers les services internes du cluster en fonction des ressources Gateway API (Gateway, HTTPRoute).

## Architecture

```
                    Internet
                       │
                       ▼
            ┌─────────────────────┐
            │  AWS Security Group │
            │     Port 80 ouvert  │
            └─────────┬───────────┘
                       │
                       ▼
            ┌─────────────────────┐
            │   Master Node       │
            │   15.237.15.14      │
            │                     │
            │  ┌───────────────┐  │
            │  │  Traefik Pod  │  │
            │  │  (hostNetwork)│  │
            │  │  :80 (web)    │  │
            │  └───────┬───────┘  │
            └──────────┼──────────┘
                       │
              Réseau interne K8s
                       │
         ┌─────────────┼─────────────┐
         │             │             │
         ▼             ▼             ▼
   ┌──────────┐  ┌──────────┐  ┌──────────┐
   │ Worker 1 │  │ Worker 2 │  │ Worker 3 │
   │ Headlamp │  │  (apps)  │  │  (apps)  │
   └──────────┘  └──────────┘  └──────────┘
```

## Composants déployés

### 1. Gateway API CRDs (v1.5.1)

Les Custom Resource Definitions de la Gateway API sont installés séparément car le chart Traefik v40.2.0 ne les inclut plus :
- `GatewayClass`
- `Gateway`
- `HTTPRoute`
- `ReferenceGrant`

Source : https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.1/standard-install.yaml

### 2. Traefik (Helm chart v40.2.0)

Installé dans le namespace `traefik-system`. Les **valeurs Helm** vivent dans
[`infra/traefik/values.yaml`](../infra/traefik/values.yaml) — **source unique, statique**,
partagée avec ArgoCD. Le rôle Ansible se contente de copier `infra/traefik/` sur le master
puis lance `helm ... -f infra/traefik/values.yaml`.

| Paramètre | Valeur | Rôle |
|-----------|--------|------|
| `providers.kubernetesGateway.enabled` | `true` | Active le provider Gateway API |
| `ports.web.port` | `80` | Entrypoint HTTP principal |
| `service.enabled` | `false` | Pas de Service K8s (hostNetwork) |
| `hostNetwork` | `true` | Bind direct sur les ports de l'hôte |
| `nodeSelector` | `kubernetes.io/hostname: ip-10-0-3-214.eu-west-3.compute.internal` | Épingle sur le master |
| `tolerations` | `node-role.kubernetes.io/control-plane` | Autorise le scheduling sur le control-plane |
| `securityContext.runAsUser` | `0` | Nécessaire pour binder le port 80 |

> ⚠️ Le `nodeSelector` est codé en dur sur le nom AWS du nœud master. Si le node est recréé
> ou change d'IP interne, mettre à jour `infra/traefik/values.yaml` (sinon pod Traefik `Pending`).
> Nom courant : `kubectl get nodes -o wide`.

### 3. GatewayClass

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: traefik
spec:
  controllerName: traefik.io/gateway-controller
```

Créé automatiquement par le chart Helm quand le provider Kubernetes Gateway est activé. Fait le lien entre les ressources Gateway et le contrôleur Traefik.

### 4. Gateway (public-gateway)

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: public-gateway
  namespace: traefik-system
spec:
  gatewayClassName: traefik
  listeners:
    - name: web
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: All
```

Déclare un point d'entrée HTTP sur le port 80, accessible depuis tous les namespaces.

### 5. HTTPRoute (exemple : Headlamp)

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: headlamp
  namespace: headlamp
spec:
  parentRefs:
    - name: public-gateway
      namespace: traefik-system
  hostnames:
    - headlamp.15-237-15-14.nip.io
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: headlamp
          port: 80
```

Route le trafic de `headlamp.15-237-15-14.nip.io` vers le service Headlamp (port 80) dans le namespace `headlamp`.

## Flux d'une requête HTTP

```
1. Client → http://headlamp.15-237-15-14.nip.io
2. DNS (nip.io) → résout vers 15.237.15.14
3. TCP → arrive sur le master:80 (Security Group autorise)
4. Traefik (hostNetwork) → reçoit la requête sur l'entrypoint "web"
5. Provider Gateway API → match le hostname avec l'HTTPRoute "headlamp"
6. Routage interne → forward vers le Service headlamp:80 (ClusterIP)
7. kube-proxy/Calico → route vers le pod Headlamp sur worker1
```

## Déploiement (Ansible)

### Playbooks

| Playbook | Rôle |
|----------|------|
| `install_traefik.yml` | Installe CRDs + Helm chart Traefik |
| `deploy_traefik.yml` | Applique le Gateway public |
| `cleanup_traefik.yml` | Supprime toutes les ressources Traefik |

### Ordre d'exécution

```bash
# 1. Installer Traefik (CRDs + Helm)
ansible-playbook -i inventory.yml install_traefik.yml

# 2. Déployer le Gateway public
ansible-playbook -i inventory.yml deploy_traefik.yml

# 3. Déployer les applications (crée les HTTPRoutes)
ansible-playbook -i inventory.yml deploy_headlamp.yml
```

## Ajouter un nouveau service

Pour exposer un nouveau service via Traefik :

1. Créer un fichier `httproute.yaml` dans le dossier infra du service :

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: mon-service
  namespace: mon-namespace
spec:
  parentRefs:
    - name: public-gateway
      namespace: traefik-system
  hostnames:
    - mon-service.15-237-15-14.nip.io
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: mon-service
          port: 80
```

2. Appliquer le manifest sur le cluster.

Le trafic sera automatiquement routé vers le service dès que Traefik détecte la nouvelle HTTPRoute.

## Commandes de debug

```bash
# Vérifier le statut du Gateway
kubectl get gateway -n traefik-system public-gateway

# Vérifier les HTTPRoutes
kubectl get httproute -A

# Logs Traefik
kubectl logs -n traefik-system -l app.kubernetes.io/name=traefik

# Vérifier que le pod écoute sur le port 80
kubectl get pods -n traefik-system -o wide
ss -tlnp | grep :80   # sur le master directement
```
