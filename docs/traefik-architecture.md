# Traefik - Architecture et déploiement

## Vue d'ensemble

Traefik est déployé comme **contrôleur Gateway API** sur le cluster Kubernetes. Il écoute directement sur les ports **80** et **443** de l'IP publique du master (15.237.15.14) grâce au mode `hostNetwork`, et route le trafic vers les services internes du cluster en fonction des ressources Gateway API (Gateway, HTTPRoute).

Le **TLS est terminé par Traefik** sur le port 443 : le certificat Let's Encrypt (Secret `apps-tls`) est émis et renouvelé automatiquement par **cert-manager** (voir [docs/cert-manager.md](cert-manager.md)). Le port 80 ne sert plus qu'à **rediriger** le trafic HTTP vers HTTPS (301) et à résoudre le **challenge ACME**.

## Architecture

```
                    Internet
                       │  (80 HTTP -> 443 HTTPS)
                       ▼
            ┌──────────────────────┐
            │  AWS Security Group  │
            │  Ports 80 + 443      │
            └─────────┬────────────┘
                       │
                       ▼
            ┌──────────────────────────┐
            │   Master Node            │
            │   15.237.15.14           │
            │                          │
            │  ┌────────────────────┐  │
            │  │   Traefik Pod      │  │
            │  │   (hostNetwork)    │  │
            │  │  :80  (web)        │  │
            │  │  :443 (websecure)  │  │
            │  └─────────┬──────────┘  │
            │  cert-manager -> apps-tls │
            └────────────┼─────────────┘
                       │
              Réseau interne K8s
                       │
         ┌─────────────┼─────────────┐
         │             │             │
         ▼             ▼             ▼
   ┌──────────┐  ┌──────────┐  ┌──────────┐
   │ Worker 1 │  │ Worker 2 │  │ Worker 3 │
   │Monitoring│  │   Dex    │  │ Headlamp │
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

Installé dans le namespace `traefik-system`. Les **valeurs Helm** vivent dans [`infra/traefik/values.yaml`](../infra/traefik/values.yaml) **source unique, statique**, partagée avec ArgoCD. Le rôle Ansible se contente de copier `infra/traefik/` sur le master puis lance `helm ... -f infra/traefik/values.yaml`.

| Paramètre | Valeur | Rôle |
|-----------|--------|------|
| `providers.kubernetesGateway.enabled` | `true` | Active le provider Gateway API |
| `ports.web.port` | `80` | Entrypoint HTTP (redirection vers HTTPS + challenge ACME) |
| `ports.websecure.port` | `443` | Entrypoint HTTPS (TLS terminé, certificat `apps-tls`) |
| `service.enabled` | `false` | Pas de Service K8s (hostNetwork) |
| `hostNetwork` | `true` | Bind direct sur les ports de l'hôte |
| `nodeSelector` | `kubernetes.io/hostname: ip-10-0-3-214.eu-west-3.compute.internal` | Épingle sur le master |
| `tolerations` | `node-role.kubernetes.io/control-plane` | Autorise le scheduling sur le control-plane |
| `securityContext.runAsUser` | `0` | Nécessaire pour binder les ports 80/443 |
| `securityContext.capabilities.add` | `NET_BIND_SERVICE` | Autorise le bind sur les ports < 1024 |

> Traefik expose aussi en interne le dashboard (`:8000`) et les métriques (`:9101`) ; seuls les ports 80 et 443 sont pertinents pour le trafic public.

> ⚠️ Le `nodeSelector` est codé en dur sur le nom AWS du noeud master. Si le node est recréé ou change d'IP interne, mettre à jour `infra/traefik/values.yaml` (sinon pod Traefik `Pending`). 
> Nom courant : `kubectl get nodes -o wide`.

### 3. GatewayClass

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: traefik
spec:
  controllerName: traefik.io/gateway-controller
  description: Traefik Gateway Controller
```

Défini de façon **déclarative** dans [`infra/traefik/gatewayclass.yaml`](../infra/traefik/gatewayclass.yaml) et appliqué via Kustomize (`kubectl apply -k infra/traefik/`) il n'est **pas** créé automatiquement par le chart Helm. Il fait le lien entre les ressources Gateway et le contrôleur Traefik via `controllerName: traefik.io/gateway-controller`.

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
    - name: web                 # HTTP redirection + challenge ACME
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: All
    - name: websecure           # HTTPS - TLS terminé par Traefik
      protocol: HTTPS
      port: 443
      allowedRoutes:
        namespaces:
          from: All
      tls:
        mode: Terminate
        certificateRefs:
          - kind: Secret
            name: apps-tls       # certificat émis par cert-manager
```

Déclare **deux** points d'entrée accessibles depuis tous les namespaces :
- `web` (HTTP/80) sert la redirection vers HTTPS et le challenge ACME ;
- `websecure` (HTTPS/443) termine le TLS avec le certificat `apps-tls` (cf. [docs/cert-manager.md](cert-manager.md)).

### 5. Redirection HTTP -> HTTPS

Une `HTTPRoute` dédiée ([`infra/traefik/httproute-redirect-https.yaml`](../infra/traefik/httproute-redirect-https.yaml)), attachée uniquement au listener `web` (port 80), renvoie un **301** vers `https://` pour tout le trafic HTTP :

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: redirect-https
  namespace: traefik-system
spec:
  parentRefs:
    - name: public-gateway
      namespace: traefik-system
      sectionName: web          # uniquement le listener HTTP
  rules:
    - filters:
        - type: RequestRedirect
          requestRedirect:
            scheme: https
            statusCode: 301
```

> Les `HTTPRoute` de challenge ACME (`/.well-known/acme-challenge/...`) créées par cert-manager ont
> un path plus spécifique et **priment** sur ce catch-all (précédence Gateway API) : le
> renouvellement automatique des certificats fonctionne sans casser la redirection.

### 6. HTTPRoute applicative (exemple : Headlamp)

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
      sectionName: websecure     # attache au listener HTTPS (443)
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

## Flux d'une requête

```
1.  Client -> http://headlamp.15-237-15-14.nip.io
2.  DNS (nip.io) -> résout vers 15.237.15.14
3.  TCP -> arrive sur le master:80 (Security Group autorise)
4.  Traefik (hostNetwork) -> reçoit sur le listener "web" (HTTP/80)
5.  HTTPRoute "redirect-https" -> renvoie 301 vers https://headlamp.15-237-15-14.nip.io
6.  Client rejoue la requête en HTTPS
7.  TCP -> arrive sur le master:443
8.  Traefik -> termine le TLS avec le certificat apps-tls (cert-manager) sur le listener "websecure"
9.  Provider Gateway API -> match le hostname avec l'HTTPRoute "headlamp" (sectionName websecure)
10. Routage interne -> forward vers le Service headlamp:80 (ClusterIP)
11. kube-proxy/Calico -> route vers le pod Headlamp sur worker3
```

## Déploiement (Ansible)

### Playbooks

| Playbook | Rôle |
|----------|------|
| `install_traefik.yml` | Installe CRDs + Helm chart Traefik |
| `deploy_traefik.yml` | Applique le Gateway public |
| `cleanup_traefik.yml` | Supprime toutes les ressources Traefik |
| `cleanup_gateway.yml` | **Heritage (legacy)** : nettoyage de l'ancien **Envoy Gateway** (namespace `envoy-gateway-system`, `EnvoyProxy envoy-nodeport`, GatewayClass `envoy-gateway`, release Helm `envoy-gateway`). Sans rapport avec Traefik : a n'utiliser que pour repartir d'un etat propre apres l'ancienne stack Envoy. |

### Ordre d'exécution

```bash
# 1. Installer Traefik (CRDs + Helm)
ansible-playbook -i ansible/inventory.yml ansible/install_traefik.yml

# 2. Déployer le Gateway public
ansible-playbook -i ansible/inventory.yml ansible/deploy_traefik.yml

# 3. Déployer les applications (crée les HTTPRoutes)
ansible-playbook -i ansible/inventory.yml ansible/deploy_headlamp.yml
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
      sectionName: websecure     # attache au listener HTTPS (443)
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
