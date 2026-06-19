# ArgoCD - Documentation Complète

## Table des matières

1. [Introduction](#introduction)
2. [Architecture d'ArgoCD](#architecture-dargocd)
3. [Implémentation dans le projet](#implémentation-dans-le-projet)
4. [Structure des fichiers](#structure-des-fichiers)
5. [Workflow de déploiement](#workflow-de-déploiement)
6. [Gestion des secrets avec SealedSecrets](#gestion-des-secrets-avec-sealedsecrets)
7. [Authentification OIDC via Dex (SSO)](#authentification-oidc-via-dex-sso)
8. [Configuration des Applications](#configuration-des-applications)
9. [Patterns et bonnes pratiques](#patterns-et-bonnes-pratiques)
10. [Dépannage](#dépannage)
11. [Commandes utiles](#commandes-utiles)
12. [Flux CI/CD](#flux-cicd)

---

## Introduction

ArgoCD est un outil de **GitOps continu** pour Kubernetes. Il automatise le déploiement des applications en synchronisant l'état du cluster avec le code source dans un dépôt Git.

### Principes GitOps

- **Déclaratif** : l'état désiré est défini dans Git (manifests Kubernetes, Helm charts, Kustomize)
- **Versionné** : tout changement est tracé dans Git
- **Automatisé** : ArgoCD détecte les changements et applique automatiquement
- **Réconcilié** : ArgoCD maintient l'état du cluster aligné avec Git

### Avantages

- Auditabilité complète (historique Git)
- Rollback facile (retour sur un commit précédent)
- Pas de drift (les changements manuels sont détectés et corrigés)
- CI/CD simplifié (le pipeline de build pousse l'image, ArgoCD déploie)

---

## Architecture d'ArgoCD

### Composants principaux

| Composant | Rôle |
|-----------|------|
| **API Server** | API gRPC/REST, interface Web, authentification |
| **Application Controller** | Réconcilie l'état, gère les cycles de vie des ressources |
| **Repository Server** | Clone les dépôts Git, sert les manifests aux autres composants |
| **Redis** | Cache pour les données de l'Application Controller |
| **Dex** (optionnel) | Fournisseur d'identité OIDC (SSO) |

### Flux de données

```
Git Repository → ArgoCD Repository Server → Application Controller → Kubernetes Cluster
                     ↓
                   Redis (cache)
```

---

## Implémentation dans le projet

### Vue d'ensemble

Le projet utilise ArgoCD comme **seule source de vérité** pour le déploiement des applications. L'infrastructure (cluster, Traefik, ArgoCD lui-même) est déployée via Ansible, mais les applications métier sont gérées par ArgoCD.

### Séparation des responsabilités

| Composant | Déployé par | Géré par |
|-----------|-------------|----------|
| Cluster Kubernetes | Ansible (`setup_cluster_playbook.yml`) | Ansible |
| Traefik Gateway | Ansible (`install_traefik.yml`) | Ansible |
| SealedSecrets | Ansible (`deploy_sealed_secrets.yml`) | Ansible |
| ArgoCD | Ansible (`install_argocd.yml` + `deploy_argocd.yml`) | Ansible |
| Applications (sample-app) | ArgoCD (Application manifests) | ArgoCD |

### Pourquoi cette séparation ?

- **Day-1 infra** : Ansible déploie les composants d'infrastructure (une fois)
- **Day-2 apps** : ArgoCD gère les applications qui évoluent fréquemment
- **Idempotence** : ArgoCD peut réconcilier automatiquement sans intervention humaine

---

## Structure des fichiers

### Arborescence

```
T-CLO-902-NAN_1/
├── ansible/
│   ├── deploy_all.yml              # Orchestration complète
│   ├── deploy_argocd.yml           # Déploiement ArgoCD
│   └── roles/argocd/
│       ├── defaults/main.yml       # Repo/version du chart, namespace, release
│       └── tasks/
│           ├── install.yml         # Installation Helm ArgoCD (-f infra/argocd/values.yaml)
│           └── deploy.yml          # Application des manifests (kubectl apply -k)
├── infra/argocd/
│   ├── values.yaml                 # Configuration Helm ArgoCD (dont SSO OIDC + RBAC)
│   ├── values.sealed.yaml          # SealedSecret repo GitHub
│   ├── kustomization.yaml          # Kustomize pour les manifests
│   ├── app-argocd-sample-app.yaml  # Application sample-app
│   ├── httproute.yaml              # HTTPRoute pour ArgoCD UI
│   └── argocd-oidc-sealedsecret.yaml  # SealedSecret client OIDC Dex (clientSecret)
├── charts/sample-app/
│   ├── Chart.yaml
│   ├── values.yaml                 # Valeurs par défaut du chart
│   ├── values.sealed.yaml          # Secrets chiffrés (appKey, dbPassword)
│   └── templates/
│       ├── mysql.yaml
│       ├── secrets.yaml
│       └── sealedsecret.yaml
└── gitops/sample-app/
    └── values.yaml                 # Surcharges GitOps (image tag, annotations)
```

### Fichiers clés

#### `infra/argocd/app-argocd-sample-app.yaml`

Définit l'Application ArgoCD pour `sample-app` :

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: sample-app
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/EpitechMscProPromo2026/T-CLO-902-NAN_1
    targetRevision: main
    path: charts/sample-app
    helm:
      releaseName: app              # CRITIQUE : aligne avec scope strict SealedSecret
      valueFiles:
        - values.sealed.yaml        # Secrets chiffrés
        - ../../gitops/sample-app/values.yaml  # Surcharges GitOps
  destination:
    server: https://kubernetes.default.svc
    namespace: sample-app
  syncPolicy:
    automated:
      prune: true                   # Supprime les ressources non désirées
      selfHeal: true                # Corrige les drifts
```

#### `charts/sample-app/values.sealed.yaml`

Contient les secrets chiffrés de l'application :

```yaml
secrets:
  useSealedSecrets: true           # Active la création de SealedSecret
  scope: strict                    # Lie le secret à un nom précis
  encryptedData:
    appKey: AgByZi6efXzxuYaCmY8V5VAlv+mCMf0ce79veBRnaFbedp6...
    dbPassword: AgCkRcjmiar0XP8uPAfCiH1LeREjwpVecbhLBVxTXSYeiTA+...
```

#### `infra/argocd/values.sealed.yaml`

Contient les credentials du dépôt GitHub pour ArgoCD :

```yaml
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: repo-sample-app
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
spec:
  encryptedData:
    url: AgCViPel1sw6nJW6fU7ij5SmhmcrcjwDEcwd4qKfd5mfUUzXpfA4tB4W48x+YuLTSZrQcYuvmIGTbDgwu2JLoEyVWMeeMAsQJ6ZjyKdH76s7eQKcMNSbeXMPA/7QlF/dVw6trNSuJhznoJpCbgiUzYCL3HU9o0Niiu5AoMAXxcCd4qdyEwlSGFl+nvlgp3StSpVzuOB7iks10JrGWckZV1H1fj1Vu9aE/R75lHKSy2UcLmciq9GV2kA4ST3BD0rGBa9L1x1PXE93wwYQl970LD1P5tOjPSZf6SIcEU/XaktqwLiA1wmIAjOShzR4ykRoNTmAxw5ub5aoqL98iCdiqMb5ilcXBKEyp32Ia4FfRKmzCksRm+V9aJIUsUb8BfLhEzabJi4VKxQk5pJoKKHRAamDqPHl14mXjBlUGgh8Y3EOmHueTMjMGfTJI+rrB8I00ssuxlQ4H0sai/OkUIsQlZANGlnwmEveG79VMzx3UAd318E1sQg7Z+IIiWxP4jUgLG1E7dUjxO9AonHniv4BmYSaXuvoXBo3snolJt4b30cw3G7wMEp8K6GoCZEcniV6HM5kw+qogWhW/tnsyeVYqUHfZpXjs/MHhazubmlfcSHAJcFUJ1mJ3TkyJdbkEFrj1Fj0Rno7gmtXjsb8E+aDVkHEER1I1nCeArWIGj2ZHQk7jzj445PoEujwBc/jZsV9r0faO9p3gbhV3/PFleI71PWFRub0HYu3GTCvM6zuixBhZwlHsDSP7cApXkO8qHw36+Ot7gs2CA0t/kI=
    username: AgB/sDvMgwbe70wC5+TA4vXV2ZMJT/ElJNTOQ8wbSvYPqXIkN6KNJ6fRf6Wym9DAY2s0h72zOS0Zkk7SIT1YIl31nA7k95nHJ/6CqXZImdW3bZ+bY1dwK2QnySCplTsvfk0e9VG6AJ6m0RaBVc206qygXkG8YqET5V8iv5F8Zbw2pCyUk20s52BvHf7iZWrAAaOJJ3aYwGgJvZjfHhYsczaz7NEz0/DBhUcme/tbd9iw4tMWFMTiw/o/R5sKTo/KvJ5KdJ/y5pOcb2OIiBnzR4c9QHx+njbErTwrvEuQH6BTuaH6k5tsTrffbacPuPmNbPw1McONq+PrL6Y9yDPnybKEvqCxD2YPzb+4DLZNyOCbxw09Cb+60+wvWByBeWXWCpp+Glgj5y1LQoQHlDylDmrGjjlWMxWNahvghpUE62cM/QUfqBpZxhzBD/AYEgVpMcacQCwE0eugzYgEtb6nBe9dl9yPErhGMid1HdujAU6H8sKgm3N1Sn5bUWh8N0tTiHbOi/+CiQ6CZjR62E6ueqoFcRF5WBYcx9taiTDEEx8uS87pFzXNzxUgOu2lHtrV2gEUAwN4zAQQIi1WPw/B3oZ0qo31zUhJYmEIqQT9FRGmb4rxDkhG1L5Pbi5KA96DAlTSdFshoH71M3dNN4T/6Jt7e1b09pXsYAuGMVP7ia5t+1IEE0MYOhO4N7+b00jR955Hyt0cxfk=
    password: AgCGGyMPfmW3MzVZsuTzhgrpy/kCnzp+Rz1WuW+ZDp61XBM+U4CGsg+8ikuYn4xOkeLC5Pw7HB3gMWd1tzwSvQMzrO62/VI/Dw5mRf2NFKf42l8S7JBxNMa/i7ESDee01KJx/lqP1Irl7DC3RgwJ50LUFQIOgvmeLrbRS4IBV1+dGIRSOCjw76SVum2UCl7cUr/dsqaXnxD+Up/kI6VpRSRrCgwtBLAms1PrDHqX+iv/xtpSeUQWijStZ02NloTN+K3asOTyWtJdrJYLFT6MGdk3MN5aT8ciMjda5e7q9csYB5JpDJ5Lqz1SDVnITUY0eJPGrFvym0aKVaiFFi+/jeMdNQUPnt8ThaDCKPLK9QqDMK3FV7p/Bbq/4u3GonDQGbjcR2ORidAhp0nKi0L2JhjU1wuUvLYOb9vptbRN6LozUO6Z0PSlhDtfzxwl2KPLkBun62cCMpfHRCNhLT7NVmbpGClJOx6lUclHOiaVVym2SNQL/vu4e0ppsfeJxWQq2K0aCMLSlE9MzsvSh4Tlc+4rjyKC0QYC+EL/1QV/A8ZZ4TEYWZDevimya1tv53rZLXxb4407LbasJuVz4vHbM1OEMMj290CfkvDwDG0pcVlQ3XxQmuRzTjBlNECOdeLs8hGq2qVSzFCaVLuHEHZAI1oejmH0YrTJcMUrdpjwMoannBoAqmrCL/NP4k2ORdpOSEt+F2c8DC3tlMfs4cOw6FCy9x/C2hwLcTmMy/rQyKhb2sMaEUWvy47R
    type: AgBBTtcxVFsFoDRZbINDGWdRxPaUcVBP6kfXphYpA1j656VnKHVmkZOY+SrSnoEantYI385PCY8O/qnTENYPnAFnteTn1tTbunFyn3d6TkfQXt0JZU9TzDDNOC6OpY1oEMSj3jxpxKamI2F4ACDg2Kn64j9uu1IYuH2SCr4MCtAjkyej7/8Xxe0o4INNrbsphZJ8lbXErwzr33tm3roA8gyi7NDuNt1mMQBGyvRZkQ+PjjoPFIXSUzqVpyEt+8OMsYis+X/kXAZY4aD+871LqwIg3jzKzv1Z7a6NoQKoVfWDl2StH39U3JcpFOZOIsx+xFisvQmZ9UA6DSjw0N9WBhT1VWYk7+smHcUdm5t+Dns9BsQ7HXBlxVx6wDPePQLLoMT3fyLcctYjutp1Xr0J9qyBzKu2B45uPlEDoqCDjImRu8hDt7TJil3OYUzP+JltfPYZ8tlbsXV5mlFW/JxeCEAJyV6+I5bzAKG5pFsI78txwOVXRTMWSEw1Fsh807U5bMxmQVtc8JzBn4Cm0/FVQ2PdtxBwujB/jxa/M7Y1+EJQJyoaGm9VFYc7u8kIv9sexlgAixLkfe3Kekc0TaYTg2OMTHzNV2PTAe42ozebVuuU032my5ktUAZT3geJzMrk+eA50nEcXeUTu9uDZyOKkGlq4ZilHRGdcvu+dbpaDQfVIDI8AgU5E+zohkPp0XNdhqvVc40=
  template:
    metadata:
      name: repo-sample-app
      namespace: argocd
      labels:
        argocd.argoproj.io/secret-type: repository
```

---

## Workflow de déploiement

### 1. Installation d'ArgoCD (Ansible)

```bash
ansible-playbook -i inventory.yml deploy_all.yml --tags "argocd"
```

Ce playbook :
- Installe ArgoCD via Helm (`install_argocd.yml`)
- Applique les manifests ArgoCD (`deploy_argocd.yml`) :
  - Configuration Helm (`values.yaml`)
  - SealedSecrets (`values.sealed.yaml`)
  - Applications (`app-argocd-sample-app.yaml`)
  - HTTPRoute (`httproute.yaml`)

### 2. Flux CI/CD + GitOps (complet)

Le projet utilise un pipeline CI/CD combiné avec GitOps pour le déploiement des applications.

#### Flux de bout en bout

```
Code change → CI build image → CI update gitops → ArgoCD sync → Application déployée
```

#### Étape 1 : Build Docker image (CI)

Le workflow `.github/workflows/docker-build.yml` se déclenche sur :
- Toutes les branches : build et push de l'image Docker
- Branch `main` uniquement : mise à jour de `gitops/sample-app/values.yaml`

```yaml
on:
  push:
    branches:
      - '**'  # Toutes les branches
    paths:
      - 'resources/sample-app-master/**'
```

#### Étape 2 : Update GitOps values (CI)

Sur `main` uniquement, la CI met à jour `gitops/sample-app/values.yaml` avec le nouveau tag d'image :

```yaml
update-gitops:
  if: github.ref == 'refs/heads/main'
  steps:
    - name: Update gitops/sample-app/values.yaml
      run: |
        echo "image:" > gitops/sample-app/values.yaml
        echo "  tag: \"${SHORT_SHA}\"" >> gitops/sample-app/values.yaml
    - name: Commit and push
      run: |
        git add gitops/sample-app/values.yaml
        git commit -m "chore(gitops): deploy sample-app ${GITHUB_SHA:0:12}"
        git push
```

#### Étape 3 : ArgoCD sync automatique

ArgoCD détecte le changement dans `gitops/sample-app/values.yaml` et sync automatiquement :

```yaml
syncPolicy:
  automated:
    prune: true
    selfHeal: true
```

#### Résumé par branche

| Branch | Build image | Update GitOps | ArgoCD sync |
|--------|-------------|--------------|-------------|
| feature/* | ✅ Oui | ❌ Non | ❌ Non |
| main | ✅ Oui | ✅ Oui | ✅ Oui |

### 3. Déploiement manuel (GitOps direct)

Pour des changements de configuration sans rebuild d'image :

```bash
# 1. Modifier les values (image tag, annotations)
vim gitops/sample-app/values.yaml

# 2. Commit et push
git add gitops/sample-app/values.yaml
git commit -m "feat: update sample-app configuration"
git push

# 3. ArgoCD détecte le changement et sync automatiquement
# (ou forcer manuellement)
argocd app sync sample-app
```

### 4. Workflows obsolètes

⚠️ **Important** : Le workflow `.github/workflows/deploy-sample-app.yml` est **obsolète** et a été renommé en `.old`. Il déployait via Ansible/Helm direct, ce qui créait des conflits avec ArgoCD.

**Ne pas utiliser** ce workflow. Le déploiement passe maintenant exclusivement par ArgoCD GitOps.

### 5. Cycle de vie d'une Application

```
Git Push → ArgoCD détecte → Sync → Helm rend les manifests → Kubernetes applique → Pods démarrés
```

### 6. Mise à jour de l'objet Application

⚠️ **Important** : Modifier un fichier `app-*.yaml` dans Git **ne met pas à jour** l'objet Application dans le cluster. Il faut réappliquer le manifeste :

```bash
# Via Ansible (recommandé)
ansible-playbook -i inventory.yml deploy_argocd.yml

# Ou directement sur le master
kubectl apply -k infra/argocd/
```

Pour automatiser cela, voir le pattern **App-of-Apps** (section 8).

---

## Gestion des secrets avec SealedSecrets

### Pourquoi SealedSecrets ?

Les secrets ne doivent **jamais** être en clair dans Git. SealedSecrets permet de :
- Chiffrer les secrets avec la clé publique du cluster
- Les stocker en toute sécurité dans Git
- Les déchiffrer automatiquement dans le cluster par le contrôleur

### Flux de chiffrement/déchiffrement

```
Secret en clair (local) → kubeseal (clé publique) → SealedSecret (Git)
                                                              ↓
                                                   Contrôleur SealedSecrets (cluster)
                                                              ↓
                                                   Secret classique (cluster)
```

### Scope strict

Le scope `strict` lie le secret chiffré à un **nom + namespace précis** :

```yaml
secrets:
  scope: strict
```

Cela signifie que le secret ne peut être déchiffré que si le nom du Secret correspond exactement à celui utilisé lors du chiffrement.

### Importance du `releaseName`

Le nom du secret dépend du `releaseName` Helm. Pour `sample-app` :

| `releaseName` | Nom du secret généré |
|---------------|----------------------|
| `app` | `app-sample-app-app-secrets` |
| `sample-app` | `sample-app-app-secrets` |

Si le SealedSecret a été scellé pour `app-sample-app-app-secrets` (scope strict), il **refusera** de se déchiffrer sous le nom `sample-app-app-secrets`.

C'est pourquoi l'Application ArgoCD doit spécifier `releaseName: app` :

```yaml
helm:
  releaseName: app
```

### Sceller un secret

```bash
# Récupérer la clé publique du cluster
kubectl get secret -n kube-system sealed-secrets-key -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/sealed-secret.pem

# Créer un secret temporaire
kubectl create secret generic app-sample-app-app-secrets \
  --namespace sample-app \
  --from-literal=app-key='votre-app-key' \
  --from-literal=db-password='votre-mdp-mysql' \
  --dry-run=client -o yaml \
  | kubeseal --format=yaml --cert /tmp/sealed-secret.pem --scope strict -o yaml
```

Copier le résultat dans `charts/sample-app/values.sealed.yaml`.

### Rotation des secrets

1. Révoquer l'ancien token sur GitHub
2. Générer un nouveau token
3. Re-sceller avec le **même nom** (`--name app-sample-app-app-secrets`)
4. Mettre à jour `values.sealed.yaml`
5. Commit/push → ArgoCD sync

---

## Authentification OIDC via Dex (SSO)

ArgoCD se connecte au **Dex partagé du cluster** (namespace `dex`), le **même** que
Grafana et Headlamp. On n'utilise donc **pas** le Dex *embarqué* d'ArgoCD : on le
désactive (`dex.enabled: false`) et on configure directement `oidc.config`.

### Vue d'ensemble

```mermaid
flowchart LR
    user[Utilisateur] -->|1. Log in via Dex| argocd[ArgoCD server]
    argocd -->|2. redirige| dex[Dex IDP\nns dex]
    user -->|3. identifiants locaux / Entra| dex
    dex -->|4. code OAuth| argocd
    argocd -->|5. token / userinfo| dex
    sealed[SealedSecret argocd-oidc\nclientSecret] -->|$argocd-oidc:clientSecret| argocd
```

### Ce qui est déjà en place côté Dex

Le client OAuth `argocd` **existe déjà** dans `infra/dex/values.yaml`
(`config.staticClients`) et son secret `ARGOCD_CLIENT_SECRET` est déjà scellé dans
`dex-secrets` (`infra/dex/dex-sealedsecret.yaml`) :

```yaml
staticClients:
  - id: "argocd"
    name: ArgoCD
    secretEnv: ARGOCD_CLIENT_SECRET
    redirectURIs:
      - "https://argocd.15-237-15-14.nip.io/auth/callback"
```

→ Aucune modification de Dex n'est nécessaire. Il faut seulement câbler **le côté
ArgoCD**.

### Configuration côté ArgoCD (`infra/argocd/values.yaml`)

```yaml
configs:
  params:
    server.insecure: true            # TLS terminé par Traefik
  cm:
    url: https://argocd.15-237-15-14.nip.io   # construit le redirect_uri OIDC
    oidc.config: |
      name: Dex
      issuer: https://dex.15-237-15-14.nip.io
      clientID: argocd
      clientSecret: $argocd-oidc:clientSecret  # lu depuis le SealedSecret argocd-oidc
      requestedScopes:
        - openid
        - profile
        - email
        - groups
  rbac:
    policy.default: role:readonly
    scopes: "[email, groups]"
    policy.csv: |
      g, admin@kubequest.local, role:admin

dex:
  enabled: false                     # on utilise le Dex partagé, pas celui d'ArgoCD
```

Points importants :

- **`url`** doit être l'URL publique exacte d'ArgoCD : ArgoCD en dérive le
  `redirect_uri` (`<url>/auth/callback`), qui doit correspondre **au caractère près**
  au `redirectURIs` du client `argocd` dans Dex.
- **`issuer`** doit être **strictement identique** à l'émetteur Dex
  (`config.issuer` dans `infra/dex/values.yaml`). ArgoCD découvre les endpoints via
  `<issuer>/.well-known/openid-configuration`.
- **`clientSecret: $argocd-oidc:clientSecret`** : la syntaxe `$<secret>:<clé>`
  fait lire la valeur dans le Secret `argocd-oidc`. ArgoCD n'autorise cette
  référence externe que si le Secret porte le label
  `app.kubernetes.io/part-of: argocd` (voir le SealedSecret ci-dessous).

### Sceller le client secret ArgoCD (sur le master)

Le Secret `argocd-oidc` (ns `argocd`) doit contenir **la même valeur en clair** que
`ARGOCD_CLIENT_SECRET` côté Dex c'est exactement le pattern de Grafana, dont le
client secret est scellé **des deux côtés** (ns `dex` **et** ns `monitoring`).

> Le fichier `infra/argocd/argocd-oidc-sealedsecret.yaml` versionné est un
> **placeholder** (`clientSecret: REPLACE_WITH_SEALED_VALUE`). **Il faut le
> régénérer** avant tout déploiement.

Prérequis : `kubeseal` + accès cluster sur le master, et **la valeur en clair** du
client secret ArgoCD (celle utilisée lors du scellement de `dex-secrets`).

```bash
export KUBECONFIG=/etc/kubernetes/admin.conf

# MÊME valeur en clair que ARGOCD_CLIENT_SECRET côté Dex
ARGOCD_CLIENT_SECRET="<le secret en clair>"

# On part d'un manifeste Secret portant DÉJÀ le label part-of: argocd,
# pour que le label survive au scellement (kubeseal recopie le template).
kubectl create secret generic argocd-oidc -n argocd \
  --from-literal=clientSecret="$ARGOCD_CLIENT_SECRET" \
  --dry-run=client -o yaml \
  | kubectl label -f - --local --dry-run=client -o yaml \
      app.kubernetes.io/part-of=argocd \
  | kubeseal --format=yaml --scope strict \
      --controller-name sealed-secrets-controller \
      --controller-namespace kube-system \
  > infra/argocd/argocd-oidc-sealedsecret.yaml
```

> Vérifier que le bloc `template.metadata.labels` du fichier produit contient bien
> `app.kubernetes.io/part-of: argocd` (sinon ArgoCD refusera de lire le secret).
> Le fichier produit est chiffré, **sûr à committer**.

#### Je n'ai plus la valeur en clair ? (rotation)

Si le client secret d'origine est perdu, on en génère un nouveau et on le scelle
**des deux côtés** (Dex **et** ArgoCD), avec la même valeur :

```bash
NEW_SECRET=$(openssl rand -hex 24)

# 1. Mettre à jour ARGOCD_CLIENT_SECRET dans dex-secrets (merge sans toucher au reste)
kubectl create secret generic dex-secrets -n dex \
  --from-literal=ARGOCD_CLIENT_SECRET="$NEW_SECRET" --dry-run=client -o yaml \
  | kubeseal --format=yaml --scope strict \
      --controller-name sealed-secrets-controller --controller-namespace kube-system \
      --merge-into infra/dex/dex-sealedsecret.yaml

# 2. (Re)générer infra/argocd/argocd-oidc-sealedsecret.yaml avec la même valeur
#    (commande de la section précédente, ARGOCD_CLIENT_SECRET="$NEW_SECRET")
```

Puis re-déployer **dex** et **argocd**.

### Déployer

```bash
cd ansible
# Helm (values.yaml : oidc.config + rbac + dex désactivé) puis kubectl apply -k
ansible-playbook -i inventory.yml deploy_argocd.yml
# ou via l'orchestrateur :
ansible-playbook -i inventory.yml deploy_all.yml --tags argocd
```

### Se connecter

1. Ouvrir `https://argocd.15-237-15-14.nip.io`.
2. Cliquer sur **« Log in via Dex »**.
3. Saisir `admin@kubequest.local` + le mot de passe Dex (ou passer par Microsoft
   Entra ID).
4. Arrivée dans ArgoCD avec le rôle **admin**.

> **Accès de secours (break-glass)** : le compte local `admin` d'ArgoCD reste
> actif (`kubectl -n argocd get secret argocd-initial-admin-secret -o
> jsonpath='{.data.password}' | base64 -d`). Utile si Dex est indisponible. La
> connexion locale se fait sous le formulaire « Log in via Dex ».

### Mapping des rôles (RBAC)

Le rôle ArgoCD est déterminé **par email** (comme Grafana et Headlamp), via
`argocd-rbac-cm` :

| Claim email | Rôle ArgoCD | Effet |
| ----------- | ----------- | ----- |
| `admin@kubequest.local` | `role:admin` | Accès complet (sync, suppression, settings) |
| tout autre (`user@kubequest.local`, …) | `role:readonly` (défaut) | Lecture seule |

`scopes: "[email, groups]"` indique à ArgoCD de matcher les politiques sur les
claims `email` **et** `groups`. Les comptes locaux Dex n'émettent pas de `groups`
(cf. [docs/dex.md](dex.md#mapping-des-rôles-grafana)), d'où le matching par email ;
le matching par **groupe** deviendra possible avec les groupes Entra ID (ajouter
p. ex. `g, <group-id>, role:admin`).

### Dépannage

| Symptôme | Piste |
| -------- | ----- |
| `invalid_client` / `unauthorized_client` au retour de Dex | `clientSecret` côté ArgoCD ≠ `ARGOCD_CLIENT_SECRET` côté Dex. Re-sceller avec **la même valeur** des deux côtés. |
| `redirect_uri did not match` | `configs.cm.url` ≠ `redirectURIs` du client `argocd` dans Dex. Doit donner exactement `https://argocd.<nip>/auth/callback`. |
| Bouton « Log in via Dex » absent | `oidc.config` non pris en compte : vérifier `kubectl -n argocd get cm argocd-cm -o yaml` et redémarrer `deploy/argocd-server`. |
| `failed to query provider ... /.well-known/openid-configuration` | Le pod `argocd-server` n'atteint pas l'`issuer` Dex (URL publique du master, **hairpin réseau**) ou l'`issuer` ne correspond pas. Vérifier la connectivité et l'égalité stricte des issuers. |
| Connecté mais tout est en lecture seule | RBAC : email ≠ `admin@kubequest.local`, ou `scopes` ne contient pas `email`. Vérifier `argocd-rbac-cm`. |
| `argocd-oidc` Secret absent | Le SealedSecret est resté en placeholder ou a échoué au déchiffrement : `kubectl -n argocd get sealedsecret,secret argocd-oidc` et logs du contrôleur sealed-secrets. |

---

## Configuration des Applications

### Structure d'une Application

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: sample-app
  namespace: argocd
spec:
  project: default                    # Projet ArgoCD (isolation)
  source:
    repoURL: https://github.com/EpitechMscProPromo2026/T-CLO-902-NAN_1
    targetRevision: main              # Branche Git
    path: charts/sample-app           # Chemin vers le chart/manifests
    helm:
      releaseName: app                # Nom de la release Helm
      valueFiles:                     # Fichiers de values (ordre important)
        - values.sealed.yaml          # Secrets chiffrés
        - ../../gitops/sample-app/values.yaml  # Surcharges
  destination:
    server: https://kubernetes.default.svc
    namespace: sample-app
  syncPolicy:
    automated:
      prune: true                     # Supprime les ressources non désirées
      selfHeal: true                 # Corrige les drifts
      allowEmpty: false
    syncOptions:
      - CreateNamespace=true
```

### Politique de sync

| Option | Effet |
|--------|-------|
| `prune: true` | Supprime les ressources présentes dans le cluster mais pas dans Git |
| `selfHeal: true` | Corrige automatiquement les drifts (modifications manuelles) |
| `CreateNamespace=true` | Crée le namespace s'il n'existe pas |

### Health checks

ArgoCD surveille l'état des ressources via des health checks :

- **Deployment** : Pods Running + Ready
- **StatefulSet** : Pods Running + Ready
- **Service** : Endpoints disponibles
- **PVC** : Bound
- **Custom** : Hooks personnalisables

---

## Patterns et bonnes pratiques

### 1. Séparation infra/apps

**Pattern** : Ansible pour l'infra, ArgoCD pour les apps.

**Avantages** :
- Infrastructure stable (rarement modifiée)
- Applications évolutives (GitOps)
- Bootstrap idempotent

**Implémentation** :
- `deploy_all.yml` ne contient plus `deploy_app.yml`
- Les apps sont déployées uniquement via ArgoCD Applications

### 2. Fichiers de values multiples

**Pattern** : Empiler les values files par ordre de priorité.

| Fichier | Rôle | Priorité |
|---------|------|----------|
| `charts/sample-app/values.yaml` | Défauts du chart | Base |
| `charts/sample-app/values.sealed.yaml` | Secrets chiffrés | Surcharge |
| `gitops/sample-app/values.yaml` | Surcharges GitOps | Plus haute |

**Implémentation** :
```yaml
helm:
  valueFiles:
    - values.sealed.yaml
    - ../../gitops/sample-app/values.yaml
```

### 3. ReleaseName stable

**Pattern** : Fixer le `releaseName` pour éviter les conflits de noms.

**Pourquoi** :
- Les PVC et Secrets sont nommés d'après le releaseName
- Les SealedSecrets scope strict dépendent du nom
- Changer le releaseName recrée toutes les ressources

**Implémentation** :
```yaml
helm:
  releaseName: app  # Jamais changer
```

### 4. App-of-Apps (pour plusieurs applications)

**Pattern** : Une Application "racine" qui crée automatiquement toutes les autres Applications.

**Avantages** :
- Mettre à jour les définitions d'Applications depuis Git
- Un seul point d'entrée pour gérer toutes les apps
- Bootstrap automatique des nouvelles apps

**Implémentation** (futur) :
```yaml
# infra/argocd/apps-of-apps.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: apps-of-apps
  namespace: argocd
spec:
  source:
    repoURL: https://github.com/EpitechMscProPromo2026/T-CLO-902-NAN_1
    targetRevision: main
    path: infra/argocd/apps
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
```

### 5. Nommage des SealedSecrets

**Pattern** : Ne jamais réutiliser les noms de secrets système.

**À éviter** :
- `argocd-secret` (secret système ArgoCD)
- `argocd-initial-admin-secret` (secret admin)

**Recommandé** :
- `repo-sample-app` (credentials repo)
- `app-sample-app-app-secrets` (secrets app)

### 6. Labels fonctionnels

**Pattern** : Ajouter des labels pour identifier le type de secret.

```yaml
metadata:
  labels:
    argocd.argoproj.io/secret-type: repository
```

ArgoCD utilise ce label pour reconnaître les credentials de dépôt.

### 7. Rotation des tokens

**Pattern** : Révoquer immédiatement les tokens exposés.

**Procédure** :
1. Révoquer sur GitHub
2. Générer nouveau token
3. Re-sceller
4. Commit/push
5. Sync ArgoCD

---

## Dépannage

### Problème : MySQL CrashLoopBackOff

**Symptôme** :
```
Database is uninitialized and password option is not specified
```

**Cause** : Le secret `db-password` est vide.

**Diagnostic** :
```bash
kubectl get secret sample-app-app-secrets -n sample-app -o jsonpath='{.data.db-password}' | base64 -d
```

**Solution** :
1. Vérifier que `values.sealed.yaml` est chargé dans l'Application
2. Vérifier que `releaseName: app` est spécifié
3. Re-sceller le secret pour le bon nom

### Problème : Repo Failed "Invalid username or token"

**Symptôme** :
```
argocd repo list → Failed
```

**Cause** : Token invalide ou expiré.

**Diagnostic** :
```bash
# Vérifier le token dans le cluster
kubectl get secret repo-sample-app -n argocd -o jsonpath='{.data.password}' | base64 -d

# Tester depuis le repo-server
kubectl -n argocd exec deploy/argocd-repo-server -- sh -c \
  "git ls-remote https://user:token@github.com/repo HEAD"
```

**Solution** :
1. Révoquer l'ancien token
2. Générer nouveau token avec SSO autorisé
3. Re-sceller `infra/argocd/values.sealed.yaml`
4. Restart repo-server
5. Sync ArgoCD

### Problème : Cache périmé (statut Failed alors que ça marche)

**Symptôme** :
```
argocd repo list → Failed
git ls-remote → Success
```

**Cause** : Cache Redis périmé.

**Solution** :
```bash
kubectl -n argocd rollout restart deploy/argocd-redis
kubectl -n argocd rollout restart deploy/argocd-repo-server
```

### Problème : Helm "another operation in progress"

**Symptôme** :
```
Error: UPGRADE FAILED: another operation (install/upgrade/rollback) is in progress
```

**Cause** : Release Helm coincée en état pending.

**Solution** :
```bash
helm history argocd -n argocd
helm rollback argocd <NUMERO-DEPLOYED> -n argocd
```

### Problème : ArgoCD perd server.secretkey

**Symptôme** :
```
argocd repo list → server.secretkey is missing
```

**Cause** : Le secret `argocd-secret` a été écrasé.

**Solution** :
```bash
kubectl delete secret argocd-secret -n argocd
helm rollback argocd <NUMERO> -n argocd
kubectl -n argocd rollout restart deploy/argocd-server
```

### Problème : Doublon de déploiements

**Symptôme** :
```
kubectl get pods -n sample-app
app-sample-app-* (ancien)
sample-app-* (nouveau)
```

**Cause** : `releaseName` différent entre l'ancien et le nouveau déploiement.

**Solution** :
1. Aligner `releaseName: app` dans l'Application
2. Activer `prune: true`
3. Sync ArgoCD → le doublon sera supprimé

### Problème : Application non mise à jour après Git push

**Symptôme** :
```
git push → argocd app get → ancienne config
```

**Cause** : L'objet Application dans le cluster n'a pas été réappliqué.

**Solution** :
```bash
ansible-playbook -i inventory.yml deploy_argocd.yml
# ou
kubectl apply -k infra/argocd/
```

Pour éviter cela à l'avenir, utiliser le pattern **App-of-Apps**.

---

## Commandes utiles

### CLI ArgoCD

```bash
# Login
argocd login argocd.15-237-15-14.nip.io --username admin --password <mdp> --grpc-web --insecure

# Lister les applications
argocd app list

# Détails d'une application
argocd app get sample-app

# Sync manuel
argocd app sync sample-app

# Refresh forcé
argocd app get sample-app --refresh

# Terminer une opération coincée
argocd app terminate-op sample-app

# Lister les dépôts
argocd repo list

# Ajouter un dépôt
argocd repo add https://github.com/user/repo --username user --password token

# Supprimer un dépôt
argocd repo rm https://github.com/user/repo
```

### Kubernetes

```bash
# Pods ArgoCD
kubectl get pods -n argocd

# Logs des composants
kubectl -n argocd logs deploy/argocd-server
kubectl -n argocd logs deploy/argocd-repo-server
kubectl -n argocd logs deploy/argocd-application-controller

# Restart des composants
kubectl -n argocd rollout restart deploy/argocd-server
kubectl -n argocd rollout restart deploy/argocd-repo-server
kubectl -n argocd rollout restart deploy/argocd-redis

# Secrets
kubectl get secrets -n argocd
kubectl get secret repo-sample-app -n argocd -o yaml
kubectl get secret app-sample-app-app-secrets -n sample-app -o yaml

# Applications
kubectl get applications -n argocd
kubectl get application sample-app -n argocd -o yaml
```

### Helm

```bash
# Liste des releases
helm list -n argocd
helm list -n sample-app

# Historique
helm history argocd -n argocd

# Rollback
helm rollback argocd <NUMERO> -n argocd

# Template
helm template app charts/sample-app \
  -f charts/sample-app/values.sealed.yaml \
  -f gitops/sample-app/values.yaml
```

### SealedSecrets

```bash
# Récupérer la clé publique
kubectl get secret -n kube-system sealed-secrets-key -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/sealed-secret.pem

# Sceller un secret
kubectl create secret generic app-sample-app-app-secrets \
  --namespace sample-app \
  --from-literal=db-password='mdp' \
  --dry-run=client -o yaml \
  | kubeseal --format=yaml --cert /tmp/sealed-secret.pem --scope strict -o yaml

# Vérifier le déchiffrement
kubectl get secret app-sample-app-app-secrets -n sample-app -o jsonpath='{.data.db-password}' | base64 -d
```

---

## Annexes

### Liens utiles

- [Documentation officielle ArgoCD](https://argoproj.github.io/argo-cd/)
- [Documentation SealedSecrets](https://github.com/bitnami-labs/sealed-secrets)
- [Helm Chart ArgoCD](https://github.com/argoproj/argo-helm/tree/main/charts/argo-cd)

### Glossaire

| Terme | Définition |
|-------|------------|
| **GitOps** | Méthodologie de déploiement où Git est la source de vérité |
| **Application** | Ressource ArgoCD définissant comment déployer une app |
| **Sync** | Processus de synchronisation de l'état du cluster avec Git |
| **Prune** | Suppression des ressources non désirées |
| **SelfHeal** | Correction automatique des drifts |
| **SealedSecret** | Secret chiffré pour stockage dans Git |
| **Scope strict** | Contrainte liant un secret chiffré à un nom précis |
| **ReleaseName** | Nom de la release Helm, influence les noms des ressources |
| **App-of-Apps** | Pattern où une Application crée d'autres Applications |

### Historique des incidents (session actuelle)

| Incident | Cause | Solution |
|---------|-------|----------|
| MySQL CrashLoopBackOff | Secret `db-password` vide (values.sealed.yaml non chargé) | Ajouter `values.sealed.yaml` + `releaseName: app` dans l'Application |
| Repo Failed "Invalid token" | Token non autorisé SSO | Autoriser le token sur GitHub |
| Repo Failed (cache) | Cache Redis périmé | Restart redis + repo-server |
| Helm "another operation" | Release en pending-upgrade | Rollback à la dernière révision déployée |
| ArgoCD secretkey missing | Secret `argocd-secret` écrasé | Supprimer + régénérer via Helm |
| Doublon de déploiements | releaseName différent | Aligner releaseName + prune |

---

## Flux CI/CD

### Workflows GitHub Actions

Le projet utilise GitHub Actions pour le CI/CD, combiné avec ArgoCD pour le déploiement GitOps.

#### docker-build.yml

**Rôle** : Build et push de l'image Docker, mise à jour des valeurs GitOps.

**Déclenchement** :
- Toutes les branches quand le code de l'app change (`resources/sample-app-master/**`)
- Manuel via `workflow_dispatch`

**Jobs** :
1. `build` : Build et push l'image sur GHCR
2. `update-gitops` (main uniquement) : Met à jour `gitops/sample-app/values.yaml` avec le nouveau tag

#### publish-sample-app-chart.yml

**Rôle** : Publie le Helm chart sur GHCR.

**Déclenchement** :
- Toutes les branches quand le chart change (`charts/sample-app/**`)
- Manuel via `workflow_dispatch`

#### deploy-sample-app.yml.old

**Statut** : **OBSOLÈTE**

Ce workflow déployait via Ansible/Helm direct, créant des conflits avec ArgoCD. Il a été renommé en `.old` et ne doit plus être utilisé.

### Séparation des responsabilités CI/CD vs GitOps

| Étape | Responsable | Outil |
|-------|-------------|-------|
| Build image | CI | GitHub Actions (docker-build.yml) |
| Publish chart | CI | GitHub Actions (publish-sample-app-chart.yml) |
| Update GitOps values | CI | GitHub Actions (docker-build.yml) |
| Sync application | GitOps | ArgoCD (automatique) |
| Deploy infrastructure | Infra | Ansible (deploy_all.yml) |

### Avantages de cette architecture

- **CI** : Build, test, publication d'artefacts (images, charts)
- **GitOps** : Déploiement continu, réconciliation automatique
- **Séparation claire** : CI construit, GitOps déploie
- **Pas de conflit** : Un seul chemin de déploiement (ArgoCD)

---

## Conclusion

ArgoCD est la pierre angulaire du déploiement GitOps dans ce projet. En suivant les patterns documentés (séparation infra/apps, values multiples, releaseName stable, SealedSecrets), tu assures :

- **Sécurité** : Secrets chiffrés, jamais en clair
- **Stabilité** : ReleaseName fixe, pas de conflits de noms
- **Maintenabilité** : GitOps, auditabilité, rollback facile
- **Scalabilité** : App-of-Apps pour gérer plusieurs applications

Pour toute question ou problème, réfère-toi à la section **Dépannage** ou consulte la documentation officielle.
