# Installation de Kubernetes

## Désactivation de la SWAP
```bash
swapoff -a
sed -i '/swap/d' /etc/fstab
```
- ``swapoff -a`` : Désactive immédiatement toutes les partitions/ fichiers d'échange (swap). Kubernetes exige le swap désactivé pour assurer le bon fonctionnement du scheduler.
- ``sed -i '/swap/d' /etc/fstab`` : Supprime les entrées de swap dans fstab pour empêcher le rétablissement du swap au redémarrage.

## Activation de fonctionnalité (Pilote, Driver)
```bash
modprobe br_netfilter
modprobe overlay
```
- ``modprobe br_netfilter`` : Charge le module br_netfilter (nécessaire pour que les paquets traversant les bridges soient visibles par iptables).
- ``modprobe overlay`` : Charge le module overlay utilisé par de nombreux runtimes de conteneurs pour les systèmes de fichiers superposés.

## Construire l'auto-démarrage de k8s
```bash
cat <<EOF | tee /etc/modules-load.d/k8s.conf
br_netfilter
overlay
EOF
```

## Paramétrage réseau
```bash
tee /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF

sysctl --system
```
- Activer le passage des paquets bridge via iptables et le routage IPv4
- ``sysctl --system`` : Recharge tous les paramètres sysctl persistants pour appliquer immédiatement les changements.

## Installation de containerd
```bash
dnf install -y containerd
mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml

sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

systemctl enable --now containerd
```
- ``dnf install -y containerd`` : Installe containerd, runtime de conteneurs recommandé pour Kubernetes.
- ``mkdir -p /etc/containerd`` : Crée le répertoire de configuration si nécessaire.
- ``containerd config default | tee /etc/containerd/config.toml`` : Génère la configuration par défaut de containerd et l'enregistre dans ``config.toml``
- ``sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml`` : Modifie la config pour utiliser systemd comme cgroup driver (alignement requis avec kubelet sur de nombreuses distributions).
- ``systemctl enable --now containerd`` : Activation et démarrage de ``containerd``

## Ajout du dépôt Kubernetes
```bash
cat <<EOF | tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.35/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.35/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF

dnf install -y kubelet kubeadm kubectl --disableexcludes=kubernetes

systemctl enable --now kubelet
```
- Ajoute le repo RPM officiel pour installer des paquets Kubernetes (ici ciblé v1.35).
- ``dnf install -y kubelet kubeadm kubectl --disableexcludes=kubernetes`` : Installe ``kubelet`` (agent node), ``kubeadm`` (outil d'initialisation) et ``kubectl`` (CLI). ``--disableexcludes=kubernetes`` permet d'outrepasser d'éventuelles exclusions.

# Commande à faire uniquement sur le serveur maître

## Instancier le control-plane
```bash
kubeadm init
```
- ``kubeadm init`` : Initialise le cluster Kubernetes sur le noeud maître : crée control-plane, etcd, certificats, et génère un fichier ``admin.conf`` pour accéder au cluster.

## Installation du plugin réseau - Calico
```bash
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.31.4/manifests/calico.yaml
```
- ``kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.31.4/manifests/calico.yaml``: Applique le manifeste officiel de Calico pour déployer le CNI et ses composants (DaemonSet ``calico-node``, contrôleurs, ConfigMaps, IPPools, etc.). Ce déploiement configure le routage entre pod-to-pod, active la gestion des NetworkPolicies et crée les ressources réseau nécessaires au cluster.
> Remarque: Le CNI doit être installé après kubeadm init pour que les noeuds passent à l'état Ready.

> CNI => Container Network Interface

## Vérification des connexions établie MASTER --> WORKER
```bash
kubectl get nodes -o wide
kubectl get pods -A -o wide
```
- ``kubectl get nodes -o wide`` : Vérifie l'état des noeuds et affiche des informations détaillées.
- ``kubectl get pods -A -o wide`` : Contrôle tous les pods dans tous les namespaces pour suivre leur démarrage et détecter les erreurs (notamment les pods CNI et control-plane).

## Sourcer la configuration Kubernetes pour éviter les erreurs "dial 127.0.0.1:8080: connection refused"
### Master
```bash
echo "export KUBECONFIG=/etc/kubernetes/admin.conf" >> /root/.bashrc
source /root/.bashrc
```
- ``echo "export KUBECONFIG=/etc/kubernetes/admin.conf" >> /root/.bashrc`` : Contient les certificats et identifiants de l’administrateur du cluster. En l’exportant, ``kubectl`` utilise automatiquement les credentials admin pour communiquer avec l’API server et on évite l’erreur ``dial 127.0.0.1:8080: connection refused`` causée par l’absence de configuration.
- ``source /root/.bashrc``: Permet de recharger la configuration shell dans la session en cours, évitant la reconnexion de l'utilisateur pour appliquer la configuration.

> Le fichier ``admin.conf`` donne des privilèges élevés, il est donc important de limiter la diffusion de celui-ci.

### Worker
```bash
echo "export KUBECONFIG=/etc/kubernetes/kubelet.conf" >> /root/.bashrc
source /root/.bashrc
```
- ``echo "export KUBECONFIG=/etc/kubernetes/kubelet.conf" >> /root/.bashrc`` : Fichier utilisé par le ``kubelet`` contenant des credentials liés au noeud. En l’exportant, on peut utiliser ``kubectl`` localement pour diagnostiquer les ressources du noeud (pods locaux, logs, etc.) sans exposer les credentials admin.
- ``source /root/.bashrc``: Permet de recharger la configuration shell dans la session en cours, évitant la reconnexion de l'utilisateur pour appliquer la configuration.

> Le fichier ``kubelet.conf`` donne des privilèges limitées, pour toutes manipulations d'un noeud ou pod il est vivement recommander de passer par le Maître.

> Au lieu de sourcer les configurations à chaque connexion, il est possible d'utiliser ``kubectl --kubeconfig=/etc/kubernetes/kubelet.conf ...``

## Connaitre les pods en fonctionnement sur un Worker
```bash
kubectl get pods -A --field-selector spec.nodeName=$HOSTNAME
```
- ``kubectl get pods``: Ne fonctionne pas sur les workers, car celle-ci retourne l'entièreté des pods en fonctionnement pour le cluster. Kubernetes cloisonne volontairement celle-ci pour éviter les erreurs.
Cependant, il reste possible de connaître les pods en fonctionnement sur un worker en stipulant l'argument ``--field-selector spec.nodeName=$HOSTNAME``

# Sources
- https://medium.com/@miteshpatidar25/kubernetes-cluster-setup-on-amazon-linux-2023-rhel-using-kubeadm-56f96f1d6372
- https://www.linkedin.com/pulse/install-kubeadm-cluster-amazon-linux-2023-dr-bl-radhakrishnan--57rdc/
- https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/