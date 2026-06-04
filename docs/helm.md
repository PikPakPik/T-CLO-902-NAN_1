# Déploiement avec Helm

## Qu'est-ce que Helm ?
Helm est le gestionnaire de paquets pour Kubernetes. Il permet de packager des applications complexes (comme notre application Laravel) sous forme de "Charts". Un Chart contient des templates YAML paramétrables via un fichier `values.yaml`.

Dans ce projet, Helm sert à déployer l'application Laravel et sa base de données MySQL, et à lancer automatiquement les migrations (`php artisan migrate`) après chaque déploiement.

## Structure du Chart (`charts/sample-app/`)
- `Chart.yaml` : Informations générales du chart (nom, version).
- `values.yaml` : Fichier de variables (réplicas, image Docker, identifiants BDD).
- `values.sealed.yaml` : Secrets applicatifs chiffrés (APP_KEY, mot de passe BDD) — versionné dans Git.
- `sealed-secrets.example.yaml` : Exemple de structure pour `values.sealed.yaml`.
- `templates/` : Fichiers YAML déployés sur Kubernetes :
  - `deployment.yaml` : Déploiement de l'application Laravel (2 réplicas).
  - `mysql.yaml` : Déploiement MySQL + Service + PersistentVolumeClaim.
  - `mysql-backup-cronjob.yaml` : CronJob de backup BDD (`mysqldump`) + PVC de stockage des dumps.
  - `migration-job.yaml` : Job de migration BDD exécuté après installation/mise à jour (Helm Hook post-install/post-upgrade).
  - `sealedsecret.yaml` : SealedSecret contenant APP_KEY et le mot de passe BDD (mode recommandé).
  - `secrets.yaml` : Secret Kubernetes en clair (mode legacy, désactivé par défaut).
  - `registry-secret.yaml` : Secret pour l'authentification au registry GHCR.
  - `httproute.yaml` : HTTPRoute Gateway API pour exposer l'app via Envoy Gateway.

> Les secrets applicatifs passent par **Sealed Secrets** (`values.sealed.yaml`). Les credentials GHCR pour le pull d'image sont injectés au déploiement via `GITHUB_USER` / `GITHUB_TOKEN`. Voir `docs/sealed-secrets.md`.

> Les backups MySQL automatiques (CronJob, rétention, restauration) sont documentés dans [`docs/mysql-backup.md`](mysql-backup.md).

## Prérequis locaux

- [`kubeseal`](https://github.com/bitnami-labs/sealed-secrets/releases) CLI installé (version identique au controller, voir `ansible/group_vars/all.yml` → `sealed_secrets_chart_version`).

```bash
VERSION="0.32.2"
curl -OL "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${VERSION}/kubeseal-${VERSION}-linux-amd64.tar.gz"
tar -xzf "kubeseal-${VERSION}-linux-amd64.tar.gz" kubeseal
sudo install -m 755 kubeseal /usr/local/bin/kubeseal
rm -f kubeseal "kubeseal-${VERSION}-linux-amd64.tar.gz"
```

## Préparer les secrets

### 0. Récupérer le certificat du cluster (une fois par cluster)

Le fichier `ansible/sealed-secrets.pem` n'est pas versionné — il est propre à chaque cluster. Si le fichier n'existe pas (nouveau clone, nouveau cluster, réinstallation du controller), le régénérer.

**Sur le master** (kubectl n'est pas configuré en local) :

```bash
kubectl get secret -n kube-system \
  -l sealedsecrets.bitnami.com/sealed-secrets-key \
  -o jsonpath='{.items[0].data.tls\.crt}' | base64 -d
```

Copier l'output (de `-----BEGIN CERTIFICATE-----` à `-----END CERTIFICATE-----`) dans `ansible/sealed-secrets.pem` sur ta machine locale.

> Si `ansible/sealed-secrets.pem` est absent ou correspond à un ancien cluster, le SealedSecret ne pourra pas être déchiffré et la migration job restera bloquée en `Pending` jusqu'au timeout Helm.

### 1. Secrets applicatifs (APP_KEY, mot de passe BDD)

Générer `values.sealed.yaml` avec le script (nécessite `ansible/sealed-secrets.pem`) :

```bash
export APP_KEY='base64:…'   # ex. php artisan key:generate --show
export DB_PASSWORD='…'      # identique au mot de passe utilisateur BDD
./scripts/seal-sample-app-secrets.sh
```

Le script génère `charts/sample-app/values.sealed.yaml` avec les valeurs chiffrées. Commiter ce fichier (safe pour Git). Ne pas créer `sealed-secrets.yaml` manuellement — `sealed-secrets.example.yaml` est uniquement un exemple de structure.

### 2. Credentials GHCR (pull d'image)

Le token GitHub doit avoir le scope `read:packages`. Exporter les variables avant le déploiement Ansible :

```bash
export GITHUB_USER="<github-username>"
export GITHUB_TOKEN="<github-token>"
```

Ansible génère automatiquement le secret registry à partir de ces variables.

## Déploiement automatisé (recommandé)

Le déploiement complet est géré par Ansible (CI ou local). Voir `docs/gitops.md` pour le flux automatique.

```bash
export GITHUB_USER="<github-username>"
export GITHUB_TOKEN="<github-token>"
ansible-playbook -i ansible/inventory.yml ansible/deploy_app.yml
```

Le chart est publié automatiquement sur GHCR à chaque push sur `main` via la CI GitHub Actions.

## Commandes manuelles

Toutes les commandes sont à exécuter depuis la racine du projet sur le nœud master.

### Vérifier la syntaxe
```bash
helm lint charts/sample-app \
  -f charts/sample-app/values.sealed.yaml \
  -f gitops/sample-app/values.yaml
```

### Prévisualiser les fichiers YAML générés
```bash
helm template app charts/sample-app \
  -f charts/sample-app/values.sealed.yaml \
  -f gitops/sample-app/values.yaml
```

### Déployer / mettre à jour l'application
```bash
helm upgrade --install app charts/sample-app \
  -n sample-app --create-namespace \
  -f charts/sample-app/values.sealed.yaml \
  -f gitops/sample-app/values.yaml \
  -f registry-values.yaml
```

> Pour un déploiement manuel, générez `registry-values.yaml` avec les credentials GHCR (voir `docs/sealed-secrets.md`).

### Mettre à jour l'application depuis GHCR
```bash
helm upgrade --install app \
  oci://ghcr.io/epitechmscpropromo2026/t-clo-902-nan_1/charts/sample-app \
  --version 0.1.0 \
  -n sample-app --create-namespace \
  -f charts/sample-app/values.sealed.yaml \
  -f registry-values.yaml
```

### Lister et supprimer les déploiements
```bash
helm ls -n sample-app
helm uninstall app -n sample-app
```

## Autoscaling (HPA)

Le chart peut déployer un HorizontalPodAutoscaler si `autoscaling.enabled: true`. Prérequis sur le cluster :

1. **metrics-server** — installé par Ansible (`deploy_metrics_server.yml`, inclus dans `deploy_all.yml`). Sans lui, le HPA affiche `cpu: <unknown>/70%`.
2. **CPU requests** sur les pods de l'app — définis via `resources.requests.cpu` dans les values (nécessaire pour calculer le pourcentage CPU).

Vérification :

```bash
kubectl top pods -n sample-app
kubectl get hpa -n sample-app
kubectl describe hpa app-sample-app -n sample-app
```

Installation manuelle de metrics-server (si besoin) :

```bash
ansible-playbook -i ansible/inventory.yml ansible/deploy_metrics_server.yml
```
