# Architecture Gateway API avec Envoy Gateway (mode hostNetwork)

## Vue d'ensemble

Gateway API est le standard Kubernetes pour le routage de trafic (successeur d'Ingress). Envoy Gateway est l'implémentation de référence, basée sur Envoy Proxy.

### Composants

- **GatewayClass** : Définit le contrôleur qui gère les Gateways (ici `gateway.envoyproxy.io/gatewayclass-controller`)
- **Gateway** : Point d'entrée réseau (listener sur un port, ex: HTTP:80)
- **HTTPRoute** : Règles de routage (hostname, path, headers) vers des services
- **EnvoyProxy** : Configuration du dataplane Envoy (hostNetwork, nodeSelector, etc.)

## Architecture actuelle

```
┌─────────────────────────────────────────────────────────────────┐
│                         Internet                                │
│                  EIP 15.237.15.14:80                            │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Master Node (hostNetwork)                    │
│  ┌──────────────┐                                               │
│  │   Envoy      │  Pod avec hostNetwork=true                    │
│  │   Proxy      │  Écoute directement sur master:80             │
│  │  (dataplane) │                                               │
│  └──────────────┘                                               │
└─────────────────────────────────────────────────────────────────┘
                              │
                              │ Match HTTPRoute (hostname/path)
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                  Service ClusterIP                              │
│  ┌──────────────┐                                               │
│  │  Service     │                                               │
│  │  Headlamp    │                                               │
│  └──────────────┘                                               │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                      Pod Headlamp                               │
│  ┌──────────────┐                                               │
│  │   Headlamp   │                                               │
│  │   Dashboard  │                                               │
│  └──────────────┘                                               │
└─────────────────────────────────────────────────────────────────┘
```

### Pourquoi hostNetwork ?

- **Workers = IP privées uniquement** (10.0.3.x) → non joignables depuis Internet
- **Master = EIP publique** (15.237.15.14) avec port 80 ouvert dans le SG
- **Pas de cloud-controller AWS** → LoadBalancer impossible
- **Pas de ressource AWS à créer** (NLB, TG, etc.)

⚠️ **Note** : hostNetwork sur le control-plane est un anti-pattern en prod, mais acceptable pour un cluster dev/test sans ressource AWS.

## Séparation des responsabilités

| Composant                | Rôle                                              | Qui le crée                       |
| ------------------------ | ------------------------------------------------- | --------------------------------- |
| Envoy Gateway Controller | Gère les CRDs Gateway API, déploie les pods Envoy | Helm (`install_gateway-api.yml`)  |
| GatewayClass             | Lie le contrôleur à une config EnvoyProxy         | Ansible (`deploy_gateway.yml`)    |
| EnvoyProxy               | Configure hostNetwork et pin sur master           | Ansible (`deploy_gateway.yml`)    |
| Gateway                  | Définit un point d'entrée HTTP:80                 | Ansible (`deploy_gateway.yml`)    |
| HTTPRoute                | Définit les règles de routage pour une app        | Kustomize (par app, ex: Headlamp) |

## EnvoyProxy CRD (hostNetwork)

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyProxy
metadata:
  name: envoy-hostnetwork
  namespace: envoy-gateway-system
spec:
  provider:
    type: Kubernetes
    kubernetes:
      envoyDeployment:
        replicas: 2 # HA
        patch:
          type: StrategicMerge
          value:
            spec:
              template:
                spec:
                  topologySpreadConstraints: # 1 pod par worker max
                    - maxSkew: 1
                      topologyKey: kubernetes.io/hostname
                      whenUnsatisfiable: ScheduleAnyway
                      labelSelector:
                        matchLabels:
                          app.kubernetes.io/name: envoy
      envoyService:
        type: NodePort
        externalTrafficPolicy: Local # préserve l'IP source client
        ports:
          - name: http
            port: 80
            nodePort: 30080
```

Points clés :

- **`replicas: 2`** + **`topologySpreadConstraints`** : 2 pods Envoy schedulés sur 2 workers différents. Si un worker tombe, le trafic continue.
- **`type: NodePort`** : indispensable sur ce cluster (cf. §4 ci-dessous et `deployment-guide.md`).
- **`externalTrafficPolicy: Local`** : le kube-proxy ne fait **pas** de SNAT, donc l'IP source du client est préservée (utile pour logs, rate-limiting, géoloc). Conséquence : seuls les nœuds qui hébergent un pod Envoy répondent au health check du NLB → le NLB n'envoie du trafic qu'à eux.
- **Pas de `nodeSelector master`, pas de tolerations control-plane** : on ne place pas de dataplane sur le control-plane (anti-pattern).

---

## 4. Pourquoi pas un Service `type: LoadBalancer` direct ?

Sur un cluster **EKS managé**, `type: LoadBalancer` provisionnerait automatiquement un NLB AWS. Ici, **ce n'est pas EKS** : il n'y a ni `aws-cloud-controller-manager` ni `aws-load-balancer-controller` installé. Un Service `LoadBalancer` resterait donc indéfiniment en `EXTERNAL-IP: <pending>`.

→ On utilise **NodePort + NLB AWS créé manuellement** comme front. C'est la même chose que ferait le LB Controller, juste branché à la main. Justification complète : [`deployment-guide.md` §2](./deployment-guide.md#2-pourquoi-nodeport--nlb-manuel-et-pas-loadbalancer).

---

## 5. Séparation des responsabilités

```
┌──────────────────────────────────────────────────────────────┐
│ INFRASTRUCTURE (ops / ce repo)                                │
│ ns: envoy-gateway-system                                      │
│   - Helm release  envoy-gateway     (install_gateway-api.yml) │
│   - EnvoyProxy    envoy-nodeport    (deploy_gateway.yml)      │
│   - GatewayClass  envoy-gateway     (deploy_gateway.yml)      │
│   - Gateway       public-gateway    (deploy_gateway.yml)      │
└──────────────────────────────────────────────────────────────┘
                          ▲
                          │ parentRefs
                          │
┌──────────────────────────────────────────────────────────────┐
│ APPLICATIONS (1 par app, dans le ns de l'app)                 │
│   - HTTPRoute   (routage hostname/path → Service)             │
│   - Service     (ClusterIP, déjà créé par le chart Helm)      │
└──────────────────────────────────────────────────────────────┘
```

| Couche      | Qui possède       | Source                                     |
| ----------- | ----------------- | ------------------------------------------ |
| CRDs + ctrl | Ops               | `ansible/install_gateway-api.yml`          |
| Dataplane   | Ops               | `ansible/deploy_gateway.yml` (EnvoyProxy)  |
| Gateway     | Ops               | `ansible/deploy_gateway.yml`               |
| HTTPRoute   | Dev de chaque app | `infra/<app>/httproute.yaml` ou chart Helm |

---

## 6. Flux d'une requête HTTP

Exemple : `curl http://headlamp.15.237.15.14.nip.io/`

1. **Résolution DNS** : `nip.io` retourne `15.237.15.14` (Elastic IP attachée au NLB AWS).
2. **NLB AWS** reçoit en TCP:80, forwarde vers le TargetGroup TCP:30080.
3. **Health check NLB** : avec `externalTrafficPolicy: Local`, seuls les workers hébergeant un pod Envoy sont `healthy`. Le NLB n'envoie le trafic qu'à eux.
4. **kube-proxy** sur le worker sélectionné délivre le paquet au pod Envoy local (pas de SNAT).
5. **Envoy** lit `Host: headlamp.15.237.15.14.nip.io`, cherche un `HTTPRoute` attaché à `public-gateway` qui matche ce hostname → trouve `headlamp/headlamp`.
6. **Envoy** forwarde vers `backendRefs[0]` = Service `headlamp:80` (ClusterIP).
7. **Service ClusterIP** load-balance vers un pod Headlamp.

---

## 7. Commandes de debug

```bash
# Vue d'ensemble
kubectl get gateway,httproute,gatewayclass -A

# État du Gateway (condition Programmed=True attendue)
kubectl describe gateway public-gateway -n envoy-gateway-system

# Répartition des pods Envoy
kubectl get pods -n envoy-gateway-system \
  -l gateway.envoyproxy.io/owning-gateway-name=public-gateway -o wide

# Service NodePort (vérifier nodePort=30080)
kubectl get svc -n envoy-gateway-system

# Logs du contrôleur
kubectl logs -n envoy-gateway-system -l app.kubernetes.io/name=envoy-gateway

# Logs d'un dataplane (Envoy access logs)
kubectl logs -n envoy-gateway-system <envoy-pod>

# Test direct depuis le master (court-circuit du NLB)
curl -H 'Host: headlamp.15.237.15.14.nip.io' http://<worker-ip>:30080/
```

---

## 8. Pour aller plus loin

- TLS terminé au Gateway : ajouter un listener `HTTPS:443` avec `tls.mode: Terminate` et un `Secret` `kubernetes.io/tls` référencé via `certificateRefs`.
- Canary / split de trafic : plusieurs `backendRefs` pondérés par `weight`.
- Multi-tenant : `allowedRoutes.namespaces.from: Selector` + labels de namespace.
- Filtres (rewrite, redirect, headers) : `rules[].filters` dans l'HTTPRoute.
