# metrics-server & autoscaling (HPA)

`metrics-server` collecte les métriques CPU/RAM des nœuds et des pods et les expose via l'API
`metrics.k8s.io`. C'est un **prérequis** de `kubectl top` et des **HorizontalPodAutoscaler (HPA)**.

## Déploiement (Ansible)

Le rôle `metrics_server` est installé sur le **master** (`deploy_metrics_server.yml`), et inclus
dans `deploy_all.yml` (tags `metrics-server`, `cluster`).

```bash
cd ansible
ansible-playbook -i inventory.yml deploy_metrics_server.yml
# ou
ansible-playbook -i inventory.yml deploy_all.yml --tags metrics-server
```

Étapes du rôle :

1. Applique le **manifeste officiel** `components.yaml` (pas de Helm).
2. Patche le Deployment pour ajouter **`--kubelet-insecure-tls`** (idempotent).
3. Attend le rollout (`rollout status`, timeout configurable).
4. Vérifie que l'API Metrics répond (`kubectl top nodes`, avec retries).

> **Pourquoi `--kubelet-insecure-tls` ?** Les certificats kubelet générés par `kubeadm` sont
> auto-signés (SAN sur IP, pas de DNS). Sans ce flag, metrics-server ne peut pas vérifier le
> certificat des kubelets et reste en erreur.

## Paramètres (`roles/metrics_server/defaults/main.yml`)

| Variable | Valeur par défaut |
| -------- | ----------------- |
| `metrics_server_namespace` | `kube-system` |
| `metrics_server_manifest_url` | `…/metrics-server/releases/download/v0.7.2/components.yaml` |
| `metrics_server_rollout_timeout` | `120s` |

Version installée : **v0.7.2**.

## Vérification

Sur le master :

```bash
sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl top nodes
sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl top pods -A
sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get apiservice v1beta1.metrics.k8s.io
```

`kubectl top nodes` doit afficher la consommation CPU/RAM. Si l'API n'est pas prête, le rôle
affiche en sortie les logs de `metrics-server` pour diagnostic.

## Autoscaling de `sample-app` (HPA)

Le chart `sample-app` peut déployer un HPA si `autoscaling.enabled: true`
(template `charts/sample-app/templates/hpa.yaml`). Deux prérequis :

1. **metrics-server** opérationnel (ce document).
2. Des **CPU requests** sur les pods de l'app (`resources.requests.cpu`), nécessaires pour
   calculer le pourcentage d'utilisation ciblé.

```bash
kubectl get hpa -n sample-app
kubectl describe hpa app-sample-app -n sample-app
```

Sans metrics-server ou sans `requests.cpu`, le HPA affiche `cpu: <unknown>/70%` et ne scale pas.

Voir aussi : [Déploiement avec Helm](helm.md), [Provisioning du cluster](cluster-setup.md).
