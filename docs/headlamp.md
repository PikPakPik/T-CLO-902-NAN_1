# Headlamp — Tableau de bord Kubernetes

Headlamp est une interface web open-source pour Kubernetes. Elle permet de visualiser et gérer les ressources du cluster (pods, deployments, services, namespaces, logs, etc.) depuis un navigateur.

## Architecture des composants

```mermaid
flowchart LR
    user[🌐 Utilisateur\nnavigateur] -->|HTTP :30080| svc

    subgraph ns[namespace: headlamp]
        svc[Service NodePort\nheadlamp-nodeport\n:30080 → :4466]
        pod[Headlamp Pod\n:4466]
        sa[ServiceAccount\nheadlamp-admin]
        svc --> pod
        pod --> sa
    end

    subgraph rbac[RBAC]
        crb[ClusterRoleBinding\nheadlamp-admin]
        cr[ClusterRole\ncluster-admin]
        crb --> cr
    end

    sa --> crb
    cr -->|accès complet| api[Kubernetes API Server]
```

## Déploiement

Headlamp est déployé via deux mécanismes combinés :

1. **Helm** — installe/met à jour le chart officiel Headlamp
2. **Kustomize** — applique les ressources complémentaires (ServiceAccount, RBAC, exposition réseau)

```bash
helm upgrade --install headlamp headlamp/headlamp --namespace headlamp --create-namespace
kubectl apply -k infra/headlamp/
```

## Authentification

Headlamp utilise les tokens Kubernetes pour l'authentification. Pour générer un token d'accès depuis le ServiceAccount `headlamp-admin` :

```bash
kubectl create token headlamp-admin -n headlamp
```

Coller le token dans l'interface web au moment de la connexion.