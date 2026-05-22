# Déploiement avec Helm

## Qu'est-ce que Helm ?
Helm est le gestionnaire de paquets pour Kubernetes. Il permet de packager des applications complexes (comme notre application Laravel) sous forme de "Charts". Un Chart contient des templates YAML paramétrables via un fichier `values.yaml`.

Dans ce projet, Helm sert à déployer l'application Laravel et sa base de données MySQL, et à lancer automatiquement les migrations (`php artisan migrate`) après chaque déploiement.

## Structure du Chart (`charts/sample-app/`)
- `Chart.yaml` : Informations générales du chart (nom, version).
- `values.yaml` : Fichier de variables (réplicas, image Docker, identifiants BDD).
- `secrets.example.yaml` : Exemple de fichier de secrets à remplir.
- `templates/` : Fichiers YAML déployés sur Kubernetes :
  - `deployment.yaml` : Déploiement de l'application Laravel (2 réplicas).
  - `mysql.yaml` : Déploiement MySQL + Service + PersistentVolumeClaim.
  - `migration-job.yaml` : Job de migration BDD exécuté après installation/mise à jour (Helm Hook post-install/post-upgrade).
  - `secrets.yaml` : Secret Kubernetes contenant APP_KEY et le mot de passe BDD.
  - `registry-secret.yaml` : Secret pour l'authentification au registry GHCR.
  - `httproute.yaml` : HTTPRoute Gateway API pour exposer l'app via Envoy Gateway.

> ⚠️ **Important** : Créez un fichier `secrets.yaml` à partir de `secrets.example.yaml` avant tout déploiement.

## Préparer le fichier secrets.yaml

### Générer le `registry.dockerconfigjson`

Ce champ contient les credentials base64 pour puller l'image depuis GHCR. Le token GitHub doit avoir le scope `read:packages`.

Ces commandes s'exécutent **en local**, aucune connexion SSH ni accès au cluster n'est nécessaire.

**Avec kubectl (recommandé) :**
```bash
kubectl create secret docker-registry ghcr-secret \
  --docker-server=ghcr.io \
  --docker-username=<github-username> \
  --docker-password=<github-token> \
  --dry-run=client -o jsonpath='{.data.\.dockerconfigjson}'
```

**Sans kubectl (avec base64 uniquement) :**
```bash
echo -n '{"auths":{"ghcr.io":{"auth":"'$(echo -n "<github-username>:<github-token>" | base64 -w 0)'"}}}' | base64 -w 0
```

Coller la valeur retournée dans `secrets.yaml` :

```yaml
registry:
  dockerconfigjson: "<valeur générée ci-dessus>"

app:
  key: "<laravel-app-key>"   # base64:... généré avec php artisan key:generate

database:
  password: "<mot-de-passe-mysql>"
```

## Déploiement automatisé (recommandé)

Le déploiement complet est géré par Ansible depuis la racine du projet :

```bash
ansible-playbook -i ansible/inventory.yml ansible/deploy_app.yml
```

Le chart est publié automatiquement sur GHCR à chaque push sur `main` via la CI GitHub Actions.

## Commandes manuelles

Toutes les commandes sont à exécuter depuis la racine du projet sur le nœud master.

### Vérifier la syntaxe
```bash
helm lint charts/sample-app -f charts/sample-app/secrets.yaml
```

### Prévisualiser les fichiers YAML générés
```bash
helm template app charts/sample-app -f charts/sample-app/secrets.yaml
```

### Déployer / mettre à jour l'application
```bash
helm upgrade --install app charts/sample-app \
  -n sample-app --create-namespace \
  -f charts/sample-app/secrets.yaml
```

### Depuis le registry GHCR (après publication CI)
```bash
helm upgrade --install app \
  oci://ghcr.io/epitechmscpropromo2026/t-clo-902-nan_1/charts/sample-app \
  --version 0.1.0 \
  -n sample-app --create-namespace \
  -f secrets.yaml
```

### Lister et supprimer les déploiements
```bash
helm ls -n sample-app
helm uninstall app -n sample-app
```
