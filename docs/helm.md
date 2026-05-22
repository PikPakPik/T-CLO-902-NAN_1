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
  - `migration-job.yaml` : Job de migration BDD exécuté après installation/mise à jour (Helm Hook post-install/post-upgrade).
  - `sealedsecret.yaml` : SealedSecret contenant APP_KEY et le mot de passe BDD (mode recommandé).
  - `secrets.yaml` : Secret Kubernetes en clair (mode legacy, désactivé par défaut).
  - `registry-secret.yaml` : Secret pour l'authentification au registry GHCR.
  - `httproute.yaml` : HTTPRoute Gateway API pour exposer l'app via Envoy Gateway.

> Les secrets applicatifs passent par **Sealed Secrets** (`values.sealed.yaml`). Les credentials GHCR pour le pull d'image sont injectés au déploiement via `GITHUB_USER` / `GITHUB_TOKEN`. Voir `docs/sealed-secrets.md`.

## Préparer les secrets

### 1. Secrets applicatifs (APP_KEY, mot de passe BDD)

Générer `values.sealed.yaml` avec le script :

```bash
export APP_KEY='base64:…'   # ex. php artisan key:generate --show
export DB_PASSWORD='…'      # identique au mot de passe utilisateur BDD
./scripts/seal-sample-app-secrets.sh
```

Commiter `charts/sample-app/values.sealed.yaml` (données chiffrées, safe pour Git).

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
