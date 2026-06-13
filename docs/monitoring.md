# Monitoring — Prometheus, Grafana, node-exporter

La stack de monitoring est déployée via un seul chart Helm (`kube-prometheus-stack`) qui installe en une fois Prometheus, Grafana, Alertmanager, kube-state-metrics et node-exporter, le tout orchestré par `prometheus-operator`.

## Architecture des composants

```mermaid
flowchart LR
    user[🌐 Utilisateur\nnavigateur] -->|grafana.*.nip.io| gw
    gw[Gateway public-gateway\nns traefik-system] --> grafanaRoute[HTTPRoute grafana]

    subgraph worker1[node: worker1]
        grafanaSvc[Service ClusterIP\nkube-prometheus-grafana :80]
        promSvc[Service ClusterIP\nkube-prometheus-kube-prome-prometheus :9090]
        grafana[Grafana Pod]
        prom[Prometheus Pod]
        alert[Alertmanager Pod]
        operator[prometheus-operator]
        ksm[kube-state-metrics]
        grafanaRoute --> grafanaSvc --> grafana
        grafana -->|requêtes internes| promSvc --> prom
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

> Note : le `nodeSelector` worker1 est codé en dur (nom AWS `ip-10-0-3-198.eu-west-3.compute.internal`) dans les manifests statiques. `local-path-provisioner` est aussi épinglé sur worker1 (`infra/local-path-storage/`) pour que les PVC monitoring soient provisionnés au bon endroit.

## Déploiement via Ansible (recommandé)

Le déploiement est entièrement automatisé par le rôle Ansible `monitoring`. Le playbook s'exécute sur le host `k8s_master` qui possède le kubeconfig admin (`/etc/kubernetes/admin.conf`).

```bash
cd ansible
ansible-playbook -i inventory.yml deploy_monitoring.yml
```

Le playbook effectue les étapes suivantes :

1. Applique **local-path-provisioner** via `kubectl apply -k infra/local-path-storage/` (manifest amont vendorisé + patches kustomize : épinglage worker1, StorageClass par défaut), puis attend que le Deployment soit `Ready`.
2. Ajoute le repo Helm `prometheus-community` puis met à jour le cache des repos.
3. Crée le namespace `monitoring` (`infra/monitoring/namespace.yaml`) et applique les `SealedSecret` Grafana / OAuth **avant** Helm.
4. Installe le chart `kube-prometheus-stack` avec `infra/monitoring/values.yaml`.
5. Installe les CRD Gateway API si elles sont absentes.
6. Applique le reste des manifests (`infra/monitoring/`, via Kustomize : HTTPRoutes, NetworkPolicies) vers le Gateway `public-gateway`.

Déploiement complet (connectivité + cluster + metrics-server + sealed-secrets + Traefik + monitoring + headlamp + app) :

```bash
ansible-playbook deploy_all.yml
```

> Note : la StorageClass `local-path` est nécessaire pour fournir des PersistentVolumes à Prometheus (rétention de 15 jours, 20 Gi), Grafana (5 Gi) et Alertmanager (2 Gi).

## Configuration

La **configuration applicative** de la stack (Grafana SSO/datasources, tailles et rétention des PVC, hostnames, ciblage worker1) vit dans `infra/monitoring/values.yaml` — **source unique, statique**, partagée avec ArgoCD. Le rôle Ansible se contente de **copier `infra/monitoring/` sur le master** puis lancer `helm ... -f infra/monitoring/values.yaml` et `kubectl apply -k`.

| Réglage                           | Valeur                    | Où                                               |
| --------------------------------- | ------------------------- | ------------------------------------------------ |
| Taille volume Prometheus          | `20Gi`                    | `infra/monitoring/values.yaml`                   |
| Rétention métriques Prometheus    | `15d`                     | `infra/monitoring/values.yaml`                   |
| Secret admin Grafana              | `grafana-admin-credentials` | `infra/monitoring/values.yaml` (via SealedSecret) |
| Ciblage des pods stateful         | `nodeSelector` sur le nom AWS de worker1 (`ip-10-0-3-198.eu-west-3.compute.internal`) | `infra/monitoring/values.yaml` |

> ⚠️ Le `nodeSelector` est codé en dur sur le nom du node worker1. Si le node est recréé ou change d'IP interne, mettre à jour les 6 occurrences dans `infra/monitoring/values.yaml` **ainsi que** le patch `infra/local-path-storage/kustomization.yaml` (sinon pods `Pending`). Nom courant : `kubectl get nodes -o wide`.

Le **stockage** (local-path-provisioner) est lui aussi entièrement déclaratif dans `infra/local-path-storage/` : manifest amont `v0.0.36` vendorisé + patches kustomize (épinglage worker1, annotation StorageClass par défaut). Ansible applique simplement `kubectl apply -k`.

Les **variables Ansible résiduelles** (`ansible/roles/monitoring/defaults/main.yml`) ne couvrent plus que la **mécanique de déploiement** : `monitoring_namespace`, `monitoring_release_name`, coordonnées/version du chart (`85.0.3`), `monitoring_storage_class`, `local_path_storage_kustomize_src`, `local_path_provisioner_rollout_timeout`, `monitoring_kustomize_src`.

> ⚠️ **Important** : le `SealedSecret` Grafana est versionné dans `infra/monitoring/grafana-sealedsecret.yaml` (données chiffrées). Pour le (re)générer, suivre la procédure de `docs/sealed-secrets.md`. Aucun mot de passe en clair dans le dépôt.

## Accès via Gateway (après `deploy_traefik.yml`)

Le routage se fait **par hostname** (un HTTPRoute dédié, chemin `/`). Le hostname est dérivé de l'IP publique du master via [nip.io](https://nip.io) (`monitoring_nip_suffix` = `<IP_master_avec_tirets>.nip.io`).

| Service    | Accès                                                                 |
| ---------- | --------------------------------------------------------------------- |
| Grafana    | `http://grafana.<IP_master_tirets>.nip.io/` (depuis Internet)         |
| Prometheus | **Interne uniquement** — pas d'HTTPRoute (voir ci-dessous)            |

> Exemple avec l'IP `15.237.15.14` : `http://grafana.15-237-15-14.nip.io/`.

**Prometheus n'est volontairement pas exposé publiquement** (aucune authentification native). Grafana l'interroge via le service ClusterIP interne. Pour y accéder ponctuellement :

```bash
kubectl port-forward -n monitoring svc/kube-prometheus-kube-prome-prometheus 9090:9090
# puis http://localhost:9090
```

Prérequis : port **TCP 80** ouvert sur le security group du master, et Gateway `public-gateway` (namespace `traefik-system`) déployé via `deploy_traefik.yml`.

## Authentification Grafana

Identifiants par défaut :

- **utilisateur** : `admin`
- **mot de passe** : valeur scellée dans `grafana-admin-credentials` (voir `docs/sealed-secrets.md`)

À la première connexion, Grafana propose de changer le mot de passe. Prometheus est exposé **sans authentification** ; ne pas l'exposer publiquement sans protection supplémentaire (reverse-proxy, security group restrictif).

### SSO via Dex (OAuth)

Grafana propose en plus une connexion **« Sign in with Dex »** (OAuth générique) adossée aux
comptes locaux Dex — le mapping de rôle se fait par email (admin → `Admin`, sinon `Viewer`).
Le formulaire admin natif ci-dessus reste actif comme accès de secours. Détails et mise en
place : [docs/dex.md](dex.md).

## Segmentation réseau (NetworkPolicy)

Par défaut, **tout pod du cluster** peut joindre Prometheus, Alertmanager ou kube-state-metrics
(trafic est-ouest ouvert). Pour limiter ces services à leurs seuls interlocuteurs légitimes, le
manifest [`infra/monitoring/networkpolicy.yaml`](../infra/monitoring/networkpolicy.yaml) applique
(via **Calico**) des NetworkPolicies **ciblées** :

| Service cible | Ingress autorisé depuis |
| ------------- | ----------------------- |
| Prometheus `:9090` | Grafana (requêtes) + Prometheus (self-scrape) |
| Alertmanager `:9093` | Prometheus (alertes + scrape) + Grafana (data source + health check) + peers Alertmanager (`:9094`) |
| kube-state-metrics `:8080` | Prometheus |

Tout le reste (ex. un pod `sample-app`) est **refusé**. Les policies sont ciblées (sélecteur de
pod) plutôt qu'un *default-deny* de namespace, pour ne pas casser les scrapes internes ni le flux
Traefik (hostNetwork) → Grafana. Elles sont appliquées par `kubectl apply -k infra/monitoring/`
(rôle `monitoring`).

> **Caveat `kubectl port-forward`** : le port-forward vers Prometheus provient du nœud (kubelet),
> pas d'un pod ; selon Calico il peut être bloqué par la policy. Si c'est le cas, ajouter un
> `from: [{ ipBlock: { cidr: <IP_nœud>/32 } }]` sur la policy Prometheus.

### node-exporter (hostNetwork) — restriction au niveau hôte

node-exporter tourne en **`hostNetwork: true`** (port **9100** sur l'IP de chaque nœud). Les
NetworkPolicy Kubernetes **ne s'y appliquent pas**. Pour restreindre l'accès à `:9100` au seul
Prometheus, il faut agir au niveau **hôte** :

- **AWS Security Group** : n'autoriser `:9100` que depuis l'IP/SG du nœud qui héberge Prometheus
  (worker1) ; ou
- **Calico `GlobalNetworkPolicy` + `HostEndpoints`** : politique sur les interfaces hôte
  (configuration plus avancée — un `HostEndpoint` mal défini peut couper la connectivité du nœud,
  à tester prudemment).

node-exporter n'expose que des **métriques système en lecture seule**, sur le réseau des nœuds
(non routé depuis l'extérieur) — sa sensibilité est moindre que celle de Prometheus.
