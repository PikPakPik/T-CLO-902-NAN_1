# Déploiement avec Helm

## Qu'est-ce que Helm ?
Helm est le gestionnaire de paquets pour Kubernetes. Il permet de packager des applications complexes (comme notre application Laravel) sous forme de "Charts". Un Chart contient des templates YAML paramétrables via un fichier `values.yaml`.

Dans ce projet, Helm sert à déployer l'application Laravel et sa base de données MySQL, et à lancer automatiquement les migrations (`php artisan migrate`) après chaque déploiement.

## Structure du Chart (`charts/sample-app/`)
- `Chart.yaml` : Informations générales du chart (nom, version).
- `values.yaml` : Fichier de variables (réplicas, image Docker, identifiants BDD).
- `values.sealed.yaml` : Secrets applicatifs chiffrés (APP_KEY, mot de passe BDD) versionné dans Git.
- `sealed-secrets.example.yaml` : Exemple de structure pour `values.sealed.yaml`.
- `templates/` : Fichiers YAML déployés sur Kubernetes :
  - `deployment.yaml` : Déploiement de l'application Laravel (2 réplicas par défaut ; le HPA ajuste entre `minReplicas` et `maxReplicas`, soit **2 à 5**, quand `autoscaling.enabled: true`).
  - `mysql.yaml` : Déploiement MySQL + Service + PersistentVolumeClaim.
  - `mysql-backup-cronjob.yaml` : CronJob de backup BDD (`mysqldump`) + PVC de stockage des dumps.
  - `migration-job.yaml` : Job de migration BDD exécuté après installation/mise à jour (Helm Hook post-install/post-upgrade).
  - `sealedsecret.yaml` : SealedSecret contenant APP_KEY et le mot de passe BDD (mode recommandé).
  - `secrets.yaml` : Secret Kubernetes en clair (mode legacy, désactivé par défaut).
  - `hpa.yaml` : HorizontalPodAutoscaler (optionnel, si `autoscaling.enabled: true`).
  - `httproute.yaml` : HTTPRoute Gateway API exposant l'app via le Gateway public (Traefik, listener `websecure` / **HTTPS**) activé par défaut (`httpRoute.enabled: true`).
  - `ingress.yaml` : Ingress classique (mode **legacy**, désactivé par défaut `ingress.enabled: false`).
  - `service.yaml` : Service ClusterIP de l'application.
  - `serviceaccount.yaml` : ServiceAccount de l'application.
  - `_helpers.tpl` : helpers de nommage et labels du chart.
  - `NOTES.txt` : message affiché par Helm après installation.
  - `tests/test-connection.yaml` : test Helm (`helm test`) de connectivité au service.

> Le Secret d'authentification au registry GHCR (`ghcr-registry`) n'est **pas** un template du chart : il est créé au déploiement par Ansible (`kubectl create secret docker-registry`) à partir de `GITHUB_USER` / `GITHUB_TOKEN`, puis référencé via `imagePullSecrets`.

> Les secrets applicatifs passent par **Sealed Secrets** (`values.sealed.yaml`). Les credentials GHCR pour le pull d'image sont injectés au déploiement via `GITHUB_USER` / `GITHUB_TOKEN`. Voir `docs/sealed-secrets.md`.

> Les backups MySQL automatiques (CronJob, rétention, restauration) sont documentés dans [`docs/mysql-backup.md`](mysql-backup.md).

## Prérequis locaux

- [`kubeseal`](https://github.com/bitnami-labs/sealed-secrets/releases) CLI installé (version identique au contrôleur, voir `ansible/roles/sealed_secrets/defaults/main.yml` -> `sealed_secrets_controller_version`, soit `0.32.2`).

```bash
VERSION="0.32.2"
curl -OL "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${VERSION}/kubeseal-${VERSION}-linux-amd64.tar.gz"
tar -xzf "kubeseal-${VERSION}-linux-amd64.tar.gz" kubeseal
sudo install -m 755 kubeseal /usr/local/bin/kubeseal
rm -f kubeseal "kubeseal-${VERSION}-linux-amd64.tar.gz"
```

## Préparer les secrets

### 0. Récupérer le certificat du cluster (une fois par cluster)

Le fichier `ansible/sealed-secrets.pem` n'est pas versionné il est propre à chaque cluster. Si le fichier n'existe pas (nouveau clone, nouveau cluster, réinstallation du controller), le régénérer.

**Sur le master** (kubectl n'est pas configuré en local) :

```bash
kubectl get secret -n kube-system \
  -l sealedsecrets.bitnami.com/sealed-secrets-key \
  -o jsonpath='{.items[0].data.tls\.crt}' | base64 -d
```

Copier l'output (de `-----BEGIN CERTIFICATE-----` à `-----END CERTIFICATE-----`) dans `ansible/sealed-secrets.pem` sur ta machine locale.

> Si `ansible/sealed-secrets.pem` est absent ou correspond à un ancien cluster, le SealedSecret ne pourra pas être déchiffré et la migration job restera bloquée en `Pending` jusqu'au timeout Helm.

### 1. Secrets applicatifs (APP_KEY, mot de passe BDD)

Sceller `APP_KEY` et le mot de passe BDD avec `kubeseal`, puis reporter les chaînes chiffrées dans `encryptedData` de `charts/sample-app/values.sealed.yaml` (secret `app-sample-app-app-secrets`, namespace `sample-app`, scope `strict`). Commiter ce fichier (safe pour Git). Ne pas créer `sealed-secrets.yaml` manuellement `sealed-secrets.example.yaml` est uniquement un exemple de structure. Procédure complète : [`docs/sealed-secrets.md`](sealed-secrets.md).

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

Toutes les commandes sont à exécuter depuis la racine du projet sur le noeud master.

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

1. **metrics-server** installé par Ansible (`deploy_metrics_server.yml`, inclus dans `deploy_all.yml`). Sans lui, le HPA affiche `cpu: <unknown>/70%`.
2. **CPU requests** sur les pods de l'app définis via `resources.requests.cpu` dans les values (nécessaire pour calculer le pourcentage CPU).

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
