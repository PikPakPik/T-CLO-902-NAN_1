# Backup MySQL automatique

Ce document décrit la CronJob Kubernetes qui sauvegarde la base de données MySQL de `sample-app`.

## Fonctionnement

Le chart Helm déploie une **CronJob** (`mysql-backup-cronjob.yaml`) qui :

1. Se connecte au service MySQL interne (`app-sample-app-mysql` par défaut).
2. Exécute `mysqldump` sur la base Laravel (`laravel` par défaut).
3. Compresse le dump en `.sql.gz` avec un horodatage (`laravel_20260522_020000.sql.gz`).
4. Stocke les fichiers sur un **PVC dédié** (`app-sample-app-mysql-backup`).
5. Supprime les backups plus anciens que la durée de rétention configurée.

L'image utilisée est `mysql:8.0` (client `mysqldump` inclus). Le mot de passe BDD est lu depuis le SealedSecret déjà déployé (`db-password`).

## Configuration

Les paramètres se trouvent dans `charts/sample-app/values.yaml` :

```yaml
database:
  backup:
    enabled: true          # false pour désactiver la CronJob et le PVC
    schedule: "0 2 * * *"  # tous les jours à 02:00 (UTC du noeud)
    retentionDays: 7       # conservation des fichiers .sql.gz
    storage: 5Gi           # taille du PVC de backup
```

| Paramètre        | Description                                      | Défaut        |
| ---------------- | ------------------------------------------------ | ------------- |
| `enabled`        | Active ou non la CronJob et le PVC               | `true`        |
| `schedule`       | Expression cron Kubernetes                       | `0 2 * * *`   |
| `retentionDays`  | Nombre de jours avant suppression automatique    | `7`           |
| `storage`        | Espace disque alloué au PVC de backup            | `5Gi`         |

Pour modifier le planning ou la rétention, éditez `values.yaml`, republiez le chart si besoin, puis relancez le déploiement Ansible ou `helm upgrade`.

## Vérifier le déploiement

Sur le master (namespace `sample-app`, release Helm `app`) :

```bash
kubectl get cronjob,pvc -n sample-app | grep mysql-backup
kubectl describe cronjob app-sample-app-mysql-backup -n sample-app
```

## Lancer un backup manuellement

Sans attendre le prochain créneau planifié :

```bash
kubectl create job --from=cronjob/app-sample-app-mysql-backup \
  manual-backup-$(date +%s) -n sample-app
```

Suivre l'exécution :

```bash
kubectl get jobs -n sample-app | grep mysql-backup
kubectl logs -l job-name=manual-backup-<timestamp> -n sample-app
```

## Consulter les fichiers de backup

Les dumps sont sur le PVC `app-sample-app-mysql-backup`. Pour lister le contenu, lancer un pod temporaire qui monte ce volume :

```bash
kubectl run backup-shell -n sample-app --rm -it --restart=Never \
  --image=busybox:1.36 \
  --overrides='{
    "spec": {
      "containers": [{
        "name": "backup-shell",
        "image": "busybox:1.36",
        "command": ["sh", "-c", "ls -lh /backups && sh"],
        "stdin": true,
        "tty": true,
        "volumeMounts": [{"name": "backup-data", "mountPath": "/backups"}]
      }],
      "volumes": [{
        "name": "backup-data",
        "persistentVolumeClaim": {"claimName": "app-sample-app-mysql-backup"}
      }]
    }
  }'
```

Quitter le shell (`exit`) supprime le pod.

## Restaurer un backup

> **Attention** : la restauration écrase les données actuelles de la base cible. À utiliser en maintenance ou sur un environnement de test.

1. Choisir le fichier à restaurer (ex. `laravel_20260522_020000.sql.gz`).
2. Lancer un pod avec le client MySQL et le PVC de backup monté :

```bash
BACKUP_FILE="laravel_20260522_020000.sql.gz"

kubectl run mysql-restore -n sample-app --rm -it --restart=Never \
  --image=mysql:8.0 \
  --overrides='{
    "spec": {
      "containers": [{
        "name": "mysql-restore",
        "image": "mysql:8.0",
        "command": ["sh", "-c",
          "gunzip -c /backups/'"${BACKUP_FILE}"' | mysql -h app-sample-app-mysql -u sample_app_user -p\"$MYSQL_PASSWORD\" laravel"
        ],
        "env": [{
          "name": "MYSQL_PASSWORD",
          "valueFrom": {
            "secretKeyRef": {
              "name": "app-sample-app-app-secrets",
              "key": "db-password"
            }
          }
        }],
        "volumeMounts": [{"name": "backup-data", "mountPath": "/backups"}]
      }],
      "volumes": [{
        "name": "backup-data",
        "persistentVolumeClaim": {"claimName": "app-sample-app-mysql-backup"}
      }]
    }
  }'
```

3. Vérifier que l'application fonctionne après restauration :

```bash
kubectl rollout status deployment/app-sample-app -n sample-app
```

## Dépannage

| Symptôme | Piste |
| -------- | ----- |
| Job en `Error` / `CrashLoopBackOff` | `kubectl logs` sur le pod du job ; vérifier que MySQL répond (`kubectl get pods -n sample-app \| grep mysql`). |
| `Access denied` | Le mot de passe dans le SealedSecret doit correspondre à `MYSQL_PASSWORD` / `MYSQL_USER` du déploiement MySQL. |
| `PROCESS privilege` / `dump tablespaces` | L'utilisateur applicatif n'a pas le droit de dumper les tablespaces (MySQL 8+). Le chart utilise `--no-tablespaces` ; redéployer le chart si l'erreur persiste. |
| Dump de 4 Ko / fichier vide | `mysqldump` a échoué silencieusement (souvent lié à l'erreur tablespaces ci-dessus). Vérifier les logs du job ; le script échoue désormais si le fichier fait moins de 100 octets. |
| PVC `Pending` | Vérifier le StorageClass et la capacité disponible sur le cluster (`kubectl describe pvc app-sample-app-mysql-backup -n sample-app`). |
| Disque plein | Augmenter `database.backup.storage` ou réduire `retentionDays` ; supprimer manuellement d'anciens `.sql.gz` via le pod `backup-shell`. |
| Aucun job planifié | Vérifier `database.backup.enabled: true` et que la CronJob existe (`kubectl get cronjob -n sample-app`). |
| Pod du job `Pending` (`anti-affinity`, `PV node affinity`, `untolerated taint`) | Le PVC `local-path` est **ReadWriteOnce** : le job doit tourner sur le **même nœud** que le volume. Le pod de backup ne doit pas porter le label `app.kubernetes.io/name: sample-app` (conflit avec l'anti-affinity du Deployment). Voir la section ci-dessous. |

### Job bloqué en `Pending` (scheduling)

Message typique :

```text
0/4 nodes are available: ... anti-affinity ... untolerated taint(s) ...
... didn't match PersistentVolume's node affinity
```

**Causes fréquentes :**

1. **Volume `local-path` lié à un autre nœud** que celui attendu (ex. premier backup lancé via `backup-shell` sur un worker générique). Seul le nœud `kubequest/role=database` peut accéder au PVC.
2. **Anti-affinity** : un pod `sample-app` sur le nœud cible empêchait l'ancien job (même label `app.kubernetes.io/name: sample-app`) de s'y placer.
3. **Taint control-plane** : le master est exclu (normal).

**Diagnostic :**

```bash
# Nœud où le volume est réellement provisionné
kubectl get pv -o wide | grep mysql-backup
kubectl describe pvc app-sample-app-mysql-backup -n sample-app

# État du job / pod
kubectl get jobs,pods -n sample-app | grep mysql-backup
kubectl describe pod -n sample-app -l app.kubernetes.io/component=mysql-backup
```

**Correction si le PV est sur le mauvais nœud** (supprime les dumps existants sur le PVC) :

```bash
kubectl delete jobs -n sample-app -l app.kubernetes.io/component=mysql-backup
kubectl delete pvc app-sample-app-mysql-backup -n sample-app
# Puis helm upgrade / redeploy Ansible pour recréer le PVC sur worker3 (database)
```

Ensuite relancer un backup manuel ; le PVC sera provisionné sur le nœud database grâce au `nodeSelector` du CronJob.

## Limites actuelles

- Les backups restent **sur le cluster** (PVC local). En cas de perte du cluster ou du volume, les dumps sont perdus.
- Pour une production exigeante, envisager une copie externe (S3, NFS, etc.) en complément de cette CronJob.

Voir aussi : [Déploiement avec Helm](helm.md).
