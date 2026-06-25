# Flux de déploiement

## CI/CD + GitOps - Publication et déploiement

```mermaid
flowchart TD
    dev([Développeur])

    subgraph local[Machine locale]
        code[Modification du code\nou du chart Helm]
        sealed[values.sealed.yaml\nchiffré versionné]
        gitops[gitops/sample-app/values.yaml\nconfig déploiement]
    end

    subgraph github[GitHub]
        push[Push sur une branche]
        subgraph ci[GitHub Actions]
            ci_docker[docker-build.yml\nBuild image + update GitOps]
            ci_helm[publish-sample-app-chart.yml\nPackage et push\ndu chart Helm]
        end
    end

    subgraph ghcr[GHCR ghcr.io]
        img[Image Docker\nsample-app:SHA12]
        chart[Chart Helm OCI\ncharts/sample-app:0.1.0]
    end

    subgraph ansible[Ansible Infra]
        infra[deploy_all.yml\nInfra : SealedSecrets, Traefik, ArgoCD]
    end

    subgraph cluster[Cluster Kubernetes]
        argocd[ArgoCD\nGitOps Controller]
        helm_release[Release Helm : app\nNamespace : sample-app]
        sealed_ctrl[Sealed Secrets Controller]
        subgraph pods[Pods]
            app_pod[Laravel app\nx 2 réplicas]
            mysql_pod[MySQL 8.0\nx 1]
        end
        migration[Job de migration\nphp artisan migrate]
        gateway[Traefik\npublic-gateway]
    end

    dev --> code
    code --> push
    push --> ci_docker --> img
    push --> ci_helm --> chart
    ci_docker --> gitops
    gitops --> argocd
    argocd --> helm_release
    helm_release --> sealed_ctrl
    sealed_ctrl --> |Secret déchiffré| pods
    img --> |imagePull| app_pod
    helm_release --> pods
    helm_release --> migration
    migration --> mysql_pod
    gateway --> app_pod
    dev --> |ansible-playbook infra| infra
    infra --> argocd
```

**Note** : Le workflow `deploy-sample-app.yml` est obsolète. Le déploiement passe maintenant exclusivement par ArgoCD GitOps.

## Ordre des opérations lors d'un sync ArgoCD

```mermaid
sequenceDiagram
    participant G as Git Push
    participant A as ArgoCD
    participant H as Helm
    participant K as Kubernetes
    participant S as Sealed Secrets
    participant M as MySQL Pod
    participant J as Migration Job
    participant P as App Pods

    G->>A: gitops/sample-app/values.yaml modifié
    A->>A: Détection du changement (polling ou webhook)
    A->>H: helm upgrade --install app charts/sample-app
    H->>K: Créer SealedSecret (APP_KEY, DB_PASSWORD)
    S->>K: Déchiffrer en Secret Kubernetes
    Note over K: Secret registry GHCR (ghcr-registry) deja cree par Ansible/bootstrap (kubectl create secret docker-registry)
    H->>K: Créer PVC MySQL
    H->>K: Créer Deployment MySQL + Service
    H->>K: Créer Deployment app + Service
    H->>K: Créer HTTPRoute
    K->>M: Démarrer MySQL
    Note over M: MySQL s'initialise...
    H->>K: Déclencher Job migration (post-install hook)
    K->>J: Démarrer init container (wait-for-db)
    J->>M: nc -z mysql 3306 (attente port 3306)
    M-->>J: Port ouvert
    J->>M: php artisan migrate --force
    M-->>J: Migrations OK
    J-->>H: Job succeeded
    H-->>A: Sync terminé ✓
    A->>A: Application status : Synced & Healthy
```
