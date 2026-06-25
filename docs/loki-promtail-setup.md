# Loki + Promtail - Stack de logging

## Vue d'ensemble

La stack de logging complète la stack de monitoring déjà en place (Prometheus + Grafana) en ajoutant la collecte et la consultation des **logs applicatifs et système**.

Prometheus collecte des métriques numériques (CPU, RAM, requêtes/sec). Loki collecte des logs textuels (messages d'erreur, traces applicatives, événements système). Les deux se visualisent dans Grafana.

```
┌──────────────────────────────────────────────────────────┐
│                       Grafana (UI)                        │
│            Métriques (Prometheus) + Logs (Loki)           │
└──────────────┬───────────────────────┬───────────────────┘
               │                       │
       ┌───────▼───────┐       ┌───────▼───────┐
       │  Prometheus   │       │     Loki      │
       │  (métriques)  │       │    (logs)     │
       └───────▲───────┘       └───────▲───────┘
               │                       │
       ┌───────┴───────┐       ┌───────┴───────┐
       │ node-exporter │       │   Promtail    │
       │  1 par noeud  │       │  1 par noeud  │
       └───────────────┘       └───────────────┘
```

## Pourquoi ces choix

### Loki plutôt qu'Elasticsearch/EFK

Loki est conçu par Grafana Labs spécifiquement pour Kubernetes. Contrairement à Elasticsearch (stack EFK), Loki n'indexe pas le contenu complet des logs il indexe uniquement les labels (namespace, pod, container). Cela le rend beaucoup plus léger en ressources (RAM, CPU, stockage), ce qui est adapté à notre cluster de 4 noeuds EC2 t4g.medium avec des ressources limitées. De plus, Loki s'intègre nativement avec Grafana, qui est déjà installé via kube-prometheus-stack.

### Promtail plutôt que Fluentd/Fluent Bit

Promtail est le collecteur natif de Loki. Il est déployé en DaemonSet (un pod par noeud), lit les fichiers de logs des conteneurs directement sur le disque de chaque noeud, et les envoie à Loki avec les labels Kubernetes enrichis automatiquement (namespace, pod, container, node). Pas besoin de configuration complexe il détecte automatiquement tous les pods.

### Mode SingleBinary

Loki peut s'exécuter en mode distribué (read, write, backend séparés) ou en mode SingleBinary (tout dans un seul pod). Pour notre cluster de 4 noeuds, le mode SingleBinary est suffisant et beaucoup plus simple à opérer.

### Stockage filesystem avec persistance

Les logs sont stockés sur un PersistentVolume de 5 Gi. Cela garantit que les logs survivent à un redémarrage du pod Loki. Pour un environnement de production à plus grande échelle, on utiliserait du stockage objet (S3), mais le filesystem est adapté à notre contexte.

> Note : le pod Loki est epingle sur **worker1** via `singleBinary.nodeSelector` (`kubernetes.io/hostname: ip-10-0-3-198.eu-west-3.compute.internal`, dans `infra/loki/values.yaml`). Son PVC de 5 Gi depend donc de `local-path` sur worker1 : si le node est recree ou change d'IP interne, mettre a jour ce nodeSelector (sinon le pod reste `Pending`).

## Installation

### Prérequis

Helm installé sur le master, namespace monitoring existant (créé par kube-prometheus-stack).

### Via Ansible (recommandé)

```bash
ansible-playbook deploy_loki.yml
```

Ou dans le déploiement complet :

```bash
ansible-playbook deploy_all.yml --tags logging
```

### Vérification

```bash
# Vérifier que Loki tourne (1/1 Running)
kubectl get pods -n monitoring | grep loki

# Vérifier que Promtail tourne (1 pod par noeud)
kubectl get pods -n monitoring | grep promtail

# Vérifier que Loki est prêt
kubectl exec -n monitoring loki-0 -- wget -qO- http://localhost:3100/ready
```

### Configurer Grafana

1. Ouvrir Grafana
2. Aller dans Connections > Data sources > Add data source
3. Sélectionner Loki
4. URL : http://loki.monitoring.svc.cluster.local:3100
5. Authentication : No Authentication
6. Cliquer Save & test

## Utilisation - Requêtes LogQL

### Requêtes de base

- `{namespace="sample-app"}` Tous les logs de l'application
- `{namespace="kube-system"}` Logs du control plane Kubernetes
- `{namespace="monitoring", container="grafana"}` Logs d'un conteneur spécifique

### Filtres sur le contenu

- `{namespace="sample-app"} |= "error"` Lignes contenant "error"
- `{namespace="sample-app"} != "debug"` Exclure les lignes "debug"
- `{namespace="sample-app"} |~ "error|warning"` Regex : error OU warning

### Pour la soutenance

Pendant la démo d'auto-scaling et de rollback :

```logql
{namespace="sample-app", container="sample-app"} |= "error"
```

## Versions installées

- Loki : 3.6.7 (chart grafana/loki 7.0.0)
- Promtail : 3.5.1 (chart grafana/promtail 6.17.1)

> Note : seules les versions de **chart** sont epinglees dans le depot (loki 7.0.0, promtail 6.17.1, dans `roles/loki/defaults/main.yml`). Les versions applicatives (Loki 3.6.7 / Promtail 3.5.1) sont les valeurs par defaut de ces charts et ne sont **pas** forcees ici : elles peuvent varier selon la version reelle du chart resolue par Helm.

## Désinstallation

```bash
helm uninstall promtail -n monitoring
helm uninstall loki -n monitoring
kubectl delete pvc -n monitoring -l app.kubernetes.io/name=loki
```