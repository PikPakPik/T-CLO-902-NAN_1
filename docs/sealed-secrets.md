# Sealed Secrets pour le projet

Ce document explique comment installer et utiliser `kubeseal` avec le cluster Kubernetes du projet.

## 1) Installer le contrôleur Sealed Secrets dans le cluster

Le playbook Ansible installe automatiquement le contrôleur sur le master via Helm (`kubernetes.core.helm`, chart `sealed-secrets`, namespace `kube-system`).

Depuis `ansible/` :

```bash
# Seul le contrôleur (cluster déjà prêt)
ansible-playbook -i inventory.yml deploy_sealed_secrets.yml

# Ou tout le stack
ansible-playbook -i inventory.yml deploy_all.yml
# ansible-playbook -i inventory.yml deploy_all.yml --tags sealed-secrets
```

Vérification :

```bash
kubectl --kubeconfig /etc/kubernetes/admin.conf get deploy -n kube-system -l app.kubernetes.io/name=sealed-secrets
```

## 2) Installer `kubeseal` sur votre machine locale

Sur macOS :

```bash
brew install kubeseal
kubeseal --version
```

## 3) Récupérer la clé publique du cluster

Depuis la racine du dépôt (ne pas committer `ansible/sealed-secrets.pem` si vous préférez le régénérer à la demande) :

```bash
kubeseal \
  --fetch-cert \
  --controller-name=sealed-secrets-controller \
  --controller-namespace=kube-system \
  > ansible/sealed-secrets.pem
```

## 4) Générer un SealedSecret pour le chart Helm

Le secret doit porter le **même nom** et le **même namespace** que ceux rendus par Helm (mode `strict`). Pour la release `app` dans le namespace `sample-app`, le nom est `app-sample-app-app-secrets`.

Méthode recommandée : script à la racine du dépôt :

```bash
export APP_KEY='base64:…'   # ex. php artisan key:generate --show
export DB_PASSWORD='…'      # identique au mot de passe utilisateur BDD
./scripts/seal-sample-app-secrets.sh
```

Cela crée `charts/sample-app/values.sealed.yaml` (données chiffrées — prêt à être versionné).

À la main :

```bash
kubectl create secret generic app-sample-app-app-secrets \
  --from-literal=app-key='base64:…' \
  --from-literal=db-password='…' \
  -n sample-app \
  --dry-run=client -o yaml | \
  kubeseal --format=yaml --cert ansible/sealed-secrets.pem --scope strict -o yaml
```

Copiez les entrées `spec.encryptedData` dans `charts/sample-app/values.sealed.yaml` :

```yaml
secrets:
  useSealedSecrets: true
  scope: strict
  encryptedData:
    appKey: "<encrypted app-key>"
    dbPassword: "<encrypted db-password>"
```

## 5) Déployer l'application en mode Sealed Secrets

Via Ansible (recommandé) :

```bash
export GITHUB_USER="<github-username>"
export GITHUB_TOKEN="<github-token>"
ansible-playbook -i ansible/inventory.yml ansible/deploy_app.yml
```

Manuellement :

```bash
helm upgrade --install app charts/sample-app -n sample-app -f charts/sample-app/values.sealed.yaml
```

Le chart va créer une ressource `SealedSecret` (`bitnami.com/v1alpha1`) qui sera déchiffrée automatiquement dans le cluster.

## Scope supportés

- `strict` (par défaut) : secret lié au nom + namespace.
- `namespace-wide` : secret déchiffrable dans le namespace.
- `cluster-wide` : secret déchiffrable dans tout le cluster.

Le scope se configure via `secrets.scope` dans `values.sealed.yaml`.
