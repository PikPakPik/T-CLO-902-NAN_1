# Monitoring — Prometheus, Grafana, node-exporter

La stack de monitoring est déployée via un seul chart Helm (`kube-prometheus-stack`) qui installe en une fois Prometheus, Grafana, Alertmanager, kube-state-metrics et node-exporter, le tout orchestré par `prometheus-operator`.

## Architecture des composants

```mermaid
flowchart LR
    user[🌐 Utilisateur\nnavigateur] -->|/grafana/ /prometheus/| gw
    gw[Gateway public-gateway] --> grafanaRoute[HTTPRoute grafana]
    gw --> promRoute[HTTPRoute prometheus]

    subgraph worker1[node: worker1]
        grafanaSvc[Service ClusterIP\ngrafana :80]
        promSvc[Service ClusterIP\nprometheus :9090]
        grafana[Grafana Pod]
        prom[Prometheus Pod]
        alert[Alertmanager Pod]
        operator[prometheus-operator]
        ksm[kube-state-metrics]
        grafanaRoute --> grafanaSvc --> grafana
        promRoute --> promSvc --> prom
    end

    subgraph allNodes[tous les nœuds]
        ne1[node-exporter]
        ne2[node-exporter]
        ne3[node-exporter]
    end

    prom -->|scrape| ne1
    prom -->|scrape| ne2
    prom -->|scrape| ne3
    prom -->|scrape| ksm
    grafana -->|datasource| prom
    prom --> alert
```

## Composants installés

| Composant            | Rôle                                                                     | Localisation                          |
| -------------------- | ------------------------------------------------------------------------ | ------------------------------------- |
| Prometheus           | Collecte et stocke les métriques du cluster                              | worker1 (`nodeSelector`)              |
| Grafana              | Interface web pour visualiser les métriques via des dashboards           | worker1                               |
| Alertmanager         | Gère les alertes générées par Prometheus                                 | worker1                               |
| prometheus-operator  | Gère le cycle de vie des ressources Prometheus/Alertmanager              | worker1                               |
| kube-state-metrics   | Expose l'état des objets Kubernetes (pods, deployments, etc.) en métriques | worker1                             |
| node-exporter        | Expose les métriques système (CPU, RAM, disque, réseau) de chaque nœud   | DaemonSet sur **tous** les nœuds      |

> Note : le nom du nœud worker1 est résolu depuis `inventory.yml` (IP interne `10.0.3.198`). `local-path-provisioner` est aussi épinglé sur worker1 pour que les PVC monitoring soient provisionnés au bon endroit.

## Déploiement via Ansible (recommandé)

Le déploiement est entièrement automatisé par le rôle Ansible `monitoring`. Le playbook s'exécute sur le host `k8s_master` qui possède le kubeconfig admin (`/etc/kubernetes/admin.conf`).

```bash
cd ansible
ansible-playbook -i inventory.yml deploy_monitoring.yml
```

Le playbook effectue les étapes suivantes :

1. Vérifie que `kubectl` et `helm` sont installés (installe Helm si nécessaire).
2. Installe **local-path-provisioner** si la StorageClass `local-path` n'existe pas, et la marque comme StorageClass par défaut.
3. Ajoute le repo Helm `prometheus-community` puis met à jour les repos.
4. Génère le fichier `values.yaml` à partir du template et installe le chart `kube-prometheus-stack`.
5. Applique les HTTPRoutes (`infra/monitoring/`) vers le Gateway public.

Déploiement complet (cluster + gateway + monitoring + headlamp) :

```bash
ansible-playbook deploy_all.yml
```

> Note : la StorageClass `local-path` est nécessaire pour fournir des PersistentVolumes à Prometheus (rétention de 15 jours, 20 Gi), Grafana (5 Gi) et Alertmanager (2 Gi).

## Variables principales (`ansible/group_vars/all.yml`)

| Variable                          | Valeur par défaut         | Description                                      |
| --------------------------------- | ------------------------- | ------------------------------------------------ |
| `monitoring_namespace`            | `monitoring`              | Namespace dans lequel la stack est déployée      |
| `monitoring_chart_version`        | `85.0.3`                  | Version du chart `kube-prometheus-stack`         |
| `monitoring_storage_class`        | `local-path`              | StorageClass utilisée pour les PVC               |
| `monitoring_prometheus_pvc_size`  | `20Gi`                    | Taille du volume Prometheus                      |
| `monitoring_prometheus_retention` | `15d`                     | Durée de rétention des métriques Prometheus      |
| `grafana_admin_secret_name`       | `grafana-admin-credentials` | Secret admin Grafana (via SealedSecret)        |

> ⚠️ **Important** : Générer `infra/monitoring/grafana-sealedsecret.yaml` avec `./scripts/seal-grafana-secret.sh` (voir `docs/sealed-secrets.md`). Aucun mot de passe en clair dans le dépôt.

## Accès via Gateway (après `deploy_gateway.yml`)

| Service    | URL (depuis Internet)              |
| ---------- | ---------------------------------- |
| Grafana    | `http://<IP_master>/grafana/`      |
| Prometheus | `http://<IP_master>/prometheus/`   |

Prérequis : port **TCP 80** ouvert sur le security group du master.

## Authentification Grafana

Identifiants par défaut :

- **utilisateur** : `admin`
- **mot de passe** : valeur scellée dans `grafana-admin-credentials` (défini lors de `seal-grafana-secret.sh`)

À la première connexion, Grafana propose de changer le mot de passe. Prometheus est exposé **sans authentification** ; ne pas l'exposer publiquement sans protection supplémentaire (reverse-proxy, security group restrictif).
