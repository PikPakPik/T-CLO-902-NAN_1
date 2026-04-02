# Déploiement avec Helm

## Qu'est-ce que Helm ?
Helm est le gestionnaire de paquets pour Kubernetes. Il permet de packager des applications complexes (comme notre application Laravel) sous forme de "Charts". Un Chart contient des templates YAML paramétrables via un fichier `values.yaml`.

Dans ce projet, Helm sert à déployer l'application et lancer automatiquement les migrations de la base de données (`php artisan migrate`) avant chaque déploiement.

## Structure du Chart (`charts/sample-app/`)
- `Chart.yaml` : Informations générales du chart (nom, version).
- `values.yaml` : Fichier de variables (réplicas, image Docker, identifiants BDD).
- `templates/` : Fichiers YAML qui seront déployés sur Kubernetes (Deployment, Service, Secrets).
- `templates/migration-job.yaml` : Job exécuté avant l'installation/mise à jour pour migrer la base de données (Helm Hook).

> ⚠️ **Important** : Pensez à créer un fichier `secrets.yaml` à partir du fichier `secrets.example.yaml` avant tout déploiement !

## Commandes utiles

Toutes les commandes sont à exécuter depuis la racine du projet.

### Vérifier la syntaxe
```bash
helm lint charts/sample-app
```
- Vérifie qu'il n'y a pas d'erreurs dans les fichiers YAML du chart.

### Prévisualiser les fichiers YAML générés
```bash
helm template my-release charts/sample-app
```
- Affiche le rendu final des fichiers Kubernetes sans rien déployer.

### Déployer l'application
```bash
helm install my-laravel-app charts/sample-app
```
- Installe l'application sur le cluster Kubernetes. Exécute le job de migration puis crée les Pods.

### Mettre à jour l'application
```bash
helm upgrade my-laravel-app charts/sample-app
```
- Met à jour l'application (ex: après un changement dans `values.yaml` ou une nouvelle image Docker).

### Lister et supprimer les déploiements
```bash
helm ls
helm uninstall my-laravel-app
```
- `helm ls` : Affiche les applications déployées.
- `helm uninstall` : Supprime l'application du cluster.
