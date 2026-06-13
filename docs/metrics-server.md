# metrics-server & autoscaling (HPA)

`metrics-server` collecte les métriques CPU/RAM des noeuds et des pods et les expose via l'API `metrics.k8s.io`. C'est un **prérequis** de `kubectl top` et des **HorizontalPodAutoscaler (HPA)**.

## Déploiement (Ansible)

Le rôle `metrics_server` est installé sur le **master** (`deploy_metrics_server.yml`), et inclus dans `deploy_all.yml` (tags `metrics-server`, `cluster`).

```bash
cd ansible
ansible-playbook -i ansible/inventory.yml ansible/deploy_metrics_server.yml
# ou
ansible-playbook -i ansible/inventory.yml ansible/deploy_all.yml --tags metrics-server
```

Étapes du rôle :

1. Copie `infra/metrics-server/` sur le master, puis applique `kubectl apply -k` : les **manifestes officiels vendorisés** (Deployment, Service, APIService, RBAC) + le patch déclaratif ajoutant **`--kubelet-insecure-tls`** (pas de Helm, plus de `kubectl patch` impératif).
2. Attend le rollout (`rollout status`, timeout configurable).
3. Vérifie que l'API Metrics répond (`kubectl top nodes`, avec retries).

> La config (manifeste + patch) vit dans `infra/metrics-server/` **source unique, statique**, appliquée à l'identique par Ansible et par ArgoCD (même modèle que Dex, monitoring et sealed-secrets).

> **Pourquoi `--kubelet-insecure-tls` ?** Les certificats kubelet générés par `kubeadm` sont
> auto-signés (SAN sur IP, pas de DNS). Sans ce flag, metrics-server ne peut pas vérifier le
> certificat des kubelets et reste en erreur.

## Paramètres (`roles/metrics_server/defaults/main.yml`)

| Variable | Valeur par défaut |
| -------- | ----------------- |
| `metrics_server_namespace` | `kube-system` |
| `metrics_server_kustomize_src` | `infra/metrics-server` (manifeste vendorisé + patch) |
| `metrics_server_rollout_timeout` | `120s` |

Version installée : **v0.7.2** (image `registry.k8s.io/metrics-server/metrics-server:v0.7.2` épinglée dans `infra/metrics-server/deployment.yaml`).

## Vérification

Sur le master :

```bash
sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl top nodes
sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl top pods -A
sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get apiservice v1beta1.metrics.k8s.io
```

`kubectl top nodes` doit afficher la consommation CPU/RAM. Si l'API n'est pas prête, le rôle affiche en sortie les logs de `metrics-server` pour diagnostic.

## Autoscaling de `sample-app` (HPA)

Le chart `sample-app` peut déployer un HPA si `autoscaling.enabled: true` (template `charts/sample-app/templates/hpa.yaml`). Deux prérequis :

1. **metrics-server** opérationnel (ce document).
2. Des **CPU requests** sur les pods de l'app (`resources.requests.cpu`), nécessaires pour calculer le pourcentage d'utilisation ciblé.

```bash
kubectl get hpa -n sample-app
kubectl describe hpa app-sample-app -n sample-app
```

Sans metrics-server ou sans `requests.cpu`, le HPA affiche `cpu: <unknown>/70%` et ne scale pas.

Voir aussi : [Déploiement avec Helm](helm.md), [Provisioning du cluster](cluster-setup.md).
