# Guide Complet — Déploiement Kubernetes avec Ansible, Helm et Headlamp

> **Public cible** : débutant sachant *à quoi sert* Kubernetes, Ansible et Helm, mais n'en connaissant pas les mécanismes internes.
> Ce document détaille **tout** ce qui a été fait dans ce projet, pourquoi, et comment le reproduire.

---

## Table des matières

1. [Vue d'ensemble du projet](#1-vue-densemble-du-projet)
2. [Concepts fondamentaux](#2-concepts-fondamentaux)
   - 2.1 [Kubernetes — les principes](#21-kubernetes--les-principes)
   - 2.2 [Ansible — les principes](#22-ansible--les-principes)
   - 2.3 [Helm — les principes](#23-helm--les-principes)
3. [Architecture de l'infrastructure](#3-architecture-de-linfrastructure)
4. [Arborescence du projet](#4-arborescence-du-projet)
5. [Partie 1 — Déploiement du cluster Kubernetes avec Ansible](#5-partie-1--déploiement-du-cluster-kubernetes-avec-ansible)
   - 5.1 [Prérequis](#51-prérequis)
   - 5.2 [Configuration Ansible](#52-configuration-ansible)
   - 5.3 [L'inventaire (inventory.yml)](#53-linventaire-inventoryyml)
   - 5.4 [Les variables globales (group_vars/all.yml)](#54-les-variables-globales-group_varsallyml)
   - 5.5 [Le playbook principal (setup_cluster_playbook.yml)](#55-le-playbook-principal-setup_cluster_playbookyml)
   - 5.6 [Rôle k8s_common — Installation commune à tous les nœuds](#56-rôle-k8s_common--installation-commune-à-tous-les-nœuds)
   - 5.7 [Rôle k8s_master — Initialisation du control-plane](#57-rôle-k8s_master--initialisation-du-control-plane)
   - 5.8 [Rôle k8s_worker — Jonction des workers au cluster](#58-rôle-k8s_worker--jonction-des-workers-au-cluster)
   - 5.9 [Lancer le déploiement](#59-lancer-le-déploiement)
6. [Partie 2 — Déploiement d'une application avec Helm](#6-partie-2--déploiement-dune-application-avec-helm)
   - 6.1 [Structure du Helm Chart (charts/sample-app/)](#61-structure-du-helm-chart-chartssample-app)
   - 6.2 [Chart.yaml — la carte d'identité](#62-chartyaml--la-carte-didentité)
   - 6.3 [values.yaml — les variables paramétrables](#63-valuesyaml--les-variables-paramétrables)
   - 6.4 [Les templates détaillés](#64-les-templates-détaillés)
   - 6.5 [Le mécanisme de Helm Hook (migration-job)](#65-le-mécanisme-de-helm-hook-migration-job)
   - 6.6 [Les secrets](#66-les-secrets)
   - 6.7 [Commandes Helm pour déployer](#67-commandes-helm-pour-déployer)
7. [Partie 3 — Installation de Headlamp (Dashboard Kubernetes)](#7-partie-3--installation-de-headlamp-dashboard-kubernetes)
   - 7.1 [Qu'est-ce que Headlamp ?](#71-quest-ce-que-headlamp-)
   - 7.2 [Architecture du déploiement Headlamp](#72-architecture-du-déploiement-headlamp)
   - 7.3 [Les ressources Kustomize (infra/headlamp/)](#73-les-ressources-kustomize-infraheadlamp)
   - 7.4 [Le rôle Ansible headlamp](#74-le-rôle-ansible-headlamp)
   - 7.5 [Accéder à l'interface Headlamp](#75-accéder-à-linterface-headlamp)
   - 7.6 [Authentification par token](#76-authentification-par-token)
8. [CI/CD — GitHub Actions](#8-cicd--github-actions)
9. [Résumé des commandes](#9-résumé-des-commandes)
10. [Glossaire](#10-glossaire)

---

## 1. Vue d'ensemble du projet

Ce projet déploie **un cluster Kubernetes** sur des instances **AWS EC2** (Amazon Linux) de manière **entièrement automatisée** grâce à **Ansible**. Une fois le cluster opérationnel :

- Une **application Laravel** est empaquetée et déployée via un **Helm Chart**.
- Un **dashboard web (Headlamp)** est installé pour visualiser le cluster depuis un navigateur.
- Une **CI/CD GitHub Actions** construit l'image Docker et teste la connectivité.

```
┌─────────────────────────────────────────────────────────────┐
│                    Ton PC (contrôleur)                       │
│                                                             │
│  ansible-playbook ──SSH──► EC2 Master (control-plane)       │
│                            │          ├── Calico (CNI)      │
│                            │          ├── Headlamp          │
│                            │          └── Helm              │
│                            │                                │
│                       kubeadm join                          │
│                     ┌──────┼──────┐                         │
│                     ▼      ▼      ▼                         │
│                  Worker1 Worker2 Worker3                     │
│                  (pods)  (pods)  (pods)                      │
└─────────────────────────────────────────────────────────────┘
```

---

## 2. Concepts fondamentaux

### 2.1 Kubernetes — les principes

Kubernetes (K8s) orchestre des conteneurs. Voici les concepts clés utilisés dans ce projet :

| Concept | Description |
|---|---|
| **Cluster** | Ensemble de machines (nœuds) qui exécutent des conteneurs gérés par Kubernetes. |
| **Node (nœud)** | Une machine (physique ou VM). Il y a deux types : **Master** et **Worker**. |
| **Master (control-plane)** | Le cerveau du cluster. Il contient l'**API Server** (point d'entrée de toutes les commandes), **etcd** (base de données du cluster), le **Scheduler** (décide quel nœud exécute quel pod), et le **Controller Manager**. |
| **Worker** | La machine qui exécute réellement les conteneurs (les pods). |
| **Pod** | La plus petite unité déployable. Un pod = un ou plusieurs conteneurs qui partagent le même réseau et stockage. |
| **Deployment** | Décrit l'état souhaité d'une application (combien de réplicas du pod, quelle image Docker, etc.). Kubernetes se charge de maintenir cet état. |
| **Service** | Expose un ensemble de pods sous une seule adresse réseau stable. Types : `ClusterIP` (interne), `NodePort` (port fixe sur chaque nœud), `LoadBalancer`. |
| **Namespace** | Cloisonnement logique au sein du cluster (ex: `headlamp`, `default`). |
| **Job** | Tâche ponctuelle qui s'exécute une fois (ex: migration de BDD). |
| **DaemonSet** | Garantit qu'un pod tourne sur chaque nœud (utilisé par Calico). |
| **Secret** | Objet Kubernetes qui stocke des données sensibles (mot de passe, clé API) encodées en base64. |
| **RBAC** | (Role-Based Access Control) Système de permissions : qui a le droit de faire quoi sur quelles ressources. |
| **CNI** | (Container Network Interface) Plugin réseau qui permet aux pods de communiquer entre eux. Ici : **Calico**. |
| **kubeadm** | Outil officiel pour initialiser et configurer un cluster Kubernetes. |
| **kubelet** | Agent qui tourne sur chaque nœud et s'assure que les pods sont en cours d'exécution. |
| **kubectl** | CLI (ligne de commande) pour interagir avec le cluster. |
| **KUBECONFIG** | Fichier contenant les certificats et l'URL de l'API server pour que `kubectl` sache à quel cluster se connecter. |
| **NodePort** | Type de Service qui ouvre un port fixe (30000-32767) sur **tous** les nœuds du cluster. |
| **Kustomize** | Outil intégré à `kubectl` pour personnaliser des manifestes YAML sans templates. On liste les fichiers dans un `kustomization.yaml`. |

#### Flux de déploiement d'un pod
```
Utilisateur → kubectl apply → API Server → Scheduler → Kubelet (sur le worker) → Conteneur démarré
```

#### Pourquoi désactiver le swap ?
Kubernetes exige que le swap soit désactivé. Le scheduler estime les ressources disponibles sur chaque nœud ; si le swap est actif, ces estimations deviennent fausses et les pods peuvent être tués de manière imprévisible.

#### Pourquoi Calico ?
Sans plugin CNI, les pods ne peuvent pas communiquer entre eux ni avec l'extérieur. Calico fournit le routage pod-to-pod et la gestion des NetworkPolicies (règles de pare-feu entre pods).

---

### 2.2 Ansible — les principes

Ansible est un outil d'**automatisation IT**. Il se connecte en SSH à des machines distantes et y exécute des tâches.

| Concept | Description |
|---|---|
| **Contrôleur** | Ta machine locale d'où tu lances `ansible-playbook`. Rien n'est installé sur les cibles sauf SSH. |
| **Inventaire** | Fichier qui liste les machines cibles, leurs adresses IP, et les regroupe (ex: `k8s_master`, `k8s_workers`). |
| **Playbook** | Fichier YAML décrivant une série de « plays » à exécuter sur des groupes de machines. |
| **Play** | Association d'un groupe d'hôtes + une liste de rôles ou tâches. |
| **Rôle** | Un module réutilisable contenant des tâches. Structure : `roles/<nom>/tasks/main.yml`. |
| **Tâche (task)** | Une action unitaire (installer un paquet, copier un fichier, lancer une commande). |
| **Module** | Brique Ansible prédéfinie (`dnf`, `copy`, `shell`, `systemd`, `lineinfile`, etc.). |
| **Facts** | Informations collectées automatiquement sur les machines (OS, RAM, IP…) via `gather_facts: yes`. |
| **become** | Équivalent de `sudo` : exécuter les tâches en tant que root. |
| **group_vars** | Variables partagées par un groupe de machines. |
| **handler** | Tâche déclenchée uniquement quand une autre tâche a modifié quelque chose (non utilisé ici). |
| **Idempotence** | Principe fondamental : relancer le même playbook 2 fois donne le même résultat. Les tâches vérifient l'état actuel avant d'agir. |

#### Comment Ansible se connecte aux machines ?
```
Ton PC ──SSH──► Master (IP publique 15.237.15.14)
                  │
                  ├──SSH proxy──► Worker1 (IP privée 10.0.3.198)
                  ├──SSH proxy──► Worker2 (IP privée 10.0.3.187)
                  └──SSH proxy──► Worker3 (IP privée 10.0.3.77)
```
Les workers n'ont **pas d'IP publique**. Ansible utilise un **ProxyCommand SSH** : il se connecte d'abord au master, puis « rebondit » vers le worker via le réseau privé AWS (VPC).

---

### 2.3 Helm — les principes

Helm est le **gestionnaire de paquets** de Kubernetes (comme `apt` pour Ubuntu ou `npm` pour Node.js).

| Concept | Description |
|---|---|
| **Chart** | Un « paquet » Helm = un dossier contenant tout ce qu'il faut pour déployer une application sur Kubernetes. |
| **Release** | Une instance d'un chart déployé. On peut déployer le même chart plusieurs fois sous des noms différents. |
| **values.yaml** | Fichier de variables. Permet de personnaliser le chart sans modifier les templates. |
| **Templates** | Fichiers YAML avec des placeholders Go `{{ .Values.xxx }}` qui sont remplacés par les valeurs lors du déploiement. |
| **Chart.yaml** | Métadonnées du chart (nom, version, dépendances). |
| **Dépendance (subchart)** | Un chart peut dépendre d'un autre chart (ici: `pxc-db` pour la base de données Percona). |
| **Hook** | Tâche spéciale exécutée à un moment précis du cycle de vie (avant install, après upgrade…). |
| **helm install** | Déploie le chart sur le cluster (première fois). |
| **helm upgrade** | Met à jour un déploiement existant. |
| **helm upgrade --install** | Installe si absent, met à jour si présent (idempotent). |
| **helm template** | Génère les YAML finaux **sans rien déployer** (utile pour vérifier). |
| **helm lint** | Vérifie la syntaxe du chart. |

#### Flux Helm
```
values.yaml ─┐
              ├──► Moteur de templates Helm ──► YAML Kubernetes finaux ──► kubectl apply
templates/ ──┘
```

---

## 3. Architecture de l'infrastructure

```
                    ┌──────────────────────────────────────────┐
                    │              AWS VPC (10.0.0.0/16)       │
                    │                                          │
 Internet ────────► │  Master (15.237.15.14 / 10.0.3.214)     │
                    │     ├── API Server (:6443)               │
                    │     ├── etcd                             │
                    │     ├── Scheduler                        │
                    │     ├── Controller Manager               │
                    │     └── Calico control                   │
                    │                                          │
                    │  Worker1 (10.0.3.198)                    │
                    │     ├── kubelet                          │
                    │     ├── Pods applicatifs                 │
                    │     └── Headlamp Pod (:4466)             │
                    │                                          │
                    │  Worker2 (10.0.3.187)                    │
                    │     ├── kubelet                          │
                    │     └── Pods applicatifs                 │
                    │                                          │
                    │  Worker3 (10.0.3.77)                     │
                    │     ├── kubelet                          │
                    │     └── Pods applicatifs                 │
                    └──────────────────────────────────────────┘
```

- **1 Master** : possède une **IP publique** (accessible depuis Internet) + une IP privée.
- **3 Workers** : n'ont que des **IP privées** (accessibles uniquement via le VPC ou via le master en jump host).
- Toutes les machines tournent sur **Amazon Linux 2023** (basé RHEL, utilise `dnf`).
- La clé SSH utilisée : `~/.ssh/kubequest.pem`.

---

## 4. Arborescence du projet

```
T-CLO-902-NAN_1/
├── ansible/                          # Automatisation du déploiement
│   ├── ansible.cfg                   # Configuration globale Ansible
│   ├── inventory.yml                 # Liste des machines (master + workers)
│   ├── group_vars/
│   │   └── all.yml                   # Variables partagées (versions K8s, Calico…)
│   ├── setup_cluster_playbook.yml    # Playbook principal : installe le cluster K8s
│   ├── deploy_headlamp.yml           # Playbook : déploie Headlamp
│   ├── test_connectivity.yml         # Playbook : teste la connexion SSH
│   └── roles/
│       ├── k8s_common/tasks/main.yml # Tâches communes à master + workers
│       ├── k8s_master/tasks/main.yml # Initialisation du control-plane
│       ├── k8s_worker/tasks/main.yml # Jonction des workers au cluster
│       ├── headlamp/                 # Installation Headlamp via Helm + Kustomize
│       │   ├── defaults/main.yml     # Variables par défaut du rôle
│       │   └── tasks/main.yml        # Tâches du rôle
│       └── test_connectivity/        # Rôle de test de connectivité
│           └── tasks/main.yml
│
├── charts/                           # Helm Charts
│   └── sample-app/                   # Chart de l'application Laravel
│       ├── Chart.yaml                # Métadonnées + dépendances
│       ├── Chart.lock                # Verrouillage des dépendances
│       ├── values.yaml               # Variables paramétrables
│       ├── secrets.example.yaml      # Modèle pour les secrets
│       └── templates/                # Templates Kubernetes
│           ├── _helpers.tpl          # Fonctions Go réutilisables
│           ├── deployment.yaml       # Déploiement de l'app
│           ├── service.yaml          # Service réseau
│           ├── secrets.yaml          # Secrets K8s
│           ├── migration-job.yaml    # Job de migration BDD (Helm Hook)
│           ├── serviceaccount.yaml   # Compte de service
│           ├── hpa.yaml              # Autoscaling (désactivé)
│           ├── ingress.yaml          # Ingress (désactivé)
│           ├── httproute.yaml        # HTTPRoute (désactivé)
│           └── NOTES.txt             # Message affiché après helm install
│
├── infra/                            # Ressources complémentaires
│   └── headlamp/                     # Manifestes Kustomize pour Headlamp
│       ├── kustomization.yaml        # Liste des ressources Kustomize
│       ├── serviceaccount.yaml       # ServiceAccount headlamp-admin
│       ├── clusterrole.yaml          # ClusterRole headlamp-viewer (lecture seule)
│       ├── clusterrolebinding.yaml   # Lie le ServiceAccount au ClusterRole
│       └── service-nodeport.yaml     # Service NodePort :30080
│
├── resources/                        # Code source de l'application
│   └── sample-app-master/            # Application Laravel + Dockerfile
│
├── docs/                             # Documentation
│   ├── initialize_vms.md             # Guide d'installation manuelle K8s
│   ├── helm.md                       # Guide Helm
│   ├── headlamp.md                   # Guide Headlamp
│   └── GUIDE_COMPLET.md              # ← CE FICHIER
│
└── .github/workflows/                # CI/CD
    ├── docker-build.yml              # Build + push image Docker
    └── test-connectivity.yml         # Test connectivité + validation manifestes
```

---

## 5. Partie 1 — Déploiement du cluster Kubernetes avec Ansible

### 5.1 Prérequis

Sur **ta machine locale** (le contrôleur Ansible) :
- **Ansible** installé (`pip install ansible` ou via le gestionnaire de paquets de ton OS)
- La **clé SSH** `~/.ssh/kubequest.pem` (fournie par AWS lors de la création des instances EC2)
- Accès réseau au master (IP publique `15.237.15.14`)

Sur les **instances EC2** (déjà provisionné via AWS) :
- Amazon Linux 2023
- SSH accessible
- Un utilisateur `ec2-user` avec droits sudo

### 5.2 Configuration Ansible

Fichier : `ansible/ansible.cfg`

```ini
[defaults]
inventory = inventory.yml          # Inventaire par défaut
host_key_checking = False          # Ne pas vérifier les clés SSH des hôtes (pratique sur EC2)
timeout = 30                       # Timeout SSH de 30s
forks = 10                         # Exécuter sur 10 machines en parallèle max
log_path = ./ansible.log           # Fichier de log local

[ssh_connection]
ssh_args = -o ControlMaster=auto -o ControlPersist=300s -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
pipelining = True                  # Optimise les performances SSH
```

**Explication des options SSH :**
- `ControlMaster=auto` : Réutilise une connexion SSH existante plutôt que d'en ouvrir une nouvelle à chaque tâche (gros gain de performance).
- `ControlPersist=300s` : La connexion SSH reste ouverte 5 minutes après la dernière utilisation.
- `StrictHostKeyChecking=no` + `UserKnownHostsFile=/dev/null` : N'enregistre pas les fingerprints SSH. Les IP EC2 changent souvent, cela évite les erreurs.
- `pipelining = True` : Envoie plusieurs commandes via la même connexion SSH au lieu d'ouvrir/fermer pour chaque tâche.

### 5.3 L'inventaire (inventory.yml)

L'inventaire est **le fichier le plus important** d'Ansible. Il dit : « voici mes machines, voici comment s'y connecter ».

```yaml
all:
  vars:                                    # Variables communes à TOUTES les machines
    ansible_user: ec2-user                 # L'utilisateur SSH
    ansible_become: yes                    # Exécuter en sudo automatiquement
    ansible_become_method: sudo
    ansible_become_user: root
    ansible_ssh_private_key_file: ~/.ssh/kubequest.pem  # Clé SSH

  children:
    k8s_master:                            # GROUPE : le master
      hosts:
        master:
          ansible_host: 15.237.15.14       # IP publique (accessible depuis Internet)
          internal_ip: 10.0.3.214          # IP privée dans le VPC

    k8s_workers:                           # GROUPE : les workers
      hosts:
        worker1:
          ansible_host: 10.0.3.198         # IP privée (pas d'IP publique)
          ansible_ssh_common_args: >-      # On passe par le master pour atteindre ce worker
            -o ProxyCommand="ssh -i ~/.ssh/kubequest.pem
            -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
            -W %h:%p ec2-user@15.237.15.14"
        worker2:
          ansible_host: 10.0.3.187
          ansible_ssh_common_args: '...'   # Même ProxyCommand
        worker3:
          ansible_host: 10.0.3.77
          ansible_ssh_common_args: '...'   # Même ProxyCommand

    k8s_cluster:                           # GROUPE parent = master + workers
      children:
        k8s_master:
        k8s_workers:
```

**Le ProxyCommand expliqué** :
```
Ton PC ──SSH──► master (15.237.15.14) ──tunnel──► worker1 (10.0.3.198)
```
`-W %h:%p` : Crée un tunnel TCP vers l'hôte et le port cible. Concrètement, Ansible se connecte d'abord au master en SSH, puis utilise cette connexion comme « pont » pour atteindre le worker sur le réseau privé AWS.

### 5.4 Les variables globales (group_vars/all.yml)

```yaml
k8s_version: "v1.35"                                          # Version de Kubernetes
k8s_master_config: "/etc/kubernetes/admin.conf"                # Kubeconfig du master
k8s_worker_config: "/etc/kubernetes/kubelet.conf"              # Kubeconfig des workers
calico_version: "v3.31.4"                                      # Version de Calico (CNI)
calico_manifest_url: "https://raw.githubusercontent.com/.../calico.yaml"  # URL du manifeste
containerd_config_dir: "/etc/containerd"                       # Répertoire config containerd
containerd_config_file: "config.toml"                          # Fichier config containerd
```

Ces variables sont accessibles depuis **tous** les rôles via `{{ k8s_version }}`, `{{ calico_version }}`, etc.

### 5.5 Le playbook principal (setup_cluster_playbook.yml)

Ce fichier orchestre les 3 phases du déploiement :

```yaml
# Phase 1 : Installation commune (master + workers)
- name: "Installation de Kubernetes"
  hosts: k8s_cluster          # = master + tous les workers
  roles:
    - k8s_common              # Rôle : prépare chaque machine

# Phase 2 : Initialisation du master
- name: "Installation de Kubernetes Master"
  hosts: k8s_master           # = master uniquement
  roles:
    - k8s_master              # Rôle : kubeadm init + Calico

# Phase 3 : Jonction des workers
- name: "Installation de Kubernetes Worker"
  hosts: k8s_workers          # = worker1, worker2, worker3
  roles:
    - k8s_worker              # Rôle : kubeadm join
```

**Ordre d'exécution crucial** : common → master → worker. Les workers doivent attendre que le master soit initialisé pour s'y joindre.

### 5.6 Rôle k8s_common — Installation commune à tous les nœuds

Fichier : `ansible/roles/k8s_common/tasks/main.yml`

Ce rôle s'exécute sur **toutes** les machines (master + workers). Voici ce qu'il fait, étape par étape :

#### Étape 1 : Désactiver le swap
```yaml
- name: "Désactivation du swap"
  command: swapoff -a                      # Désactive le swap immédiatement

- name: "Désactivation du swap au démarrage"
  lineinfile:
    path: /etc/fstab                       # Fichier qui monte les disques au boot
    regexp: '^\s*[^#].*\bswap\b'           # Cherche les lignes avec "swap"
    state: absent                          # Les supprime
```
**Pourquoi** : Kubernetes refuse de fonctionner si le swap est actif (cf. section 2.1).

#### Étape 2 : Charger les modules noyau
```yaml
- name: "Charger les modules du noyau nécessaires"
  modprobe:
    name: "{{ item }}"
  with_items:
    - br_netfilter    # Permet à iptables de voir le trafic des bridges réseau
    - overlay          # Système de fichiers pour les conteneurs
```
**Pourquoi** :
- `br_netfilter` : Les conteneurs utilisent des bridges réseau virtuels. Sans ce module, le trafic inter-pods est invisible pour les règles iptables de Kubernetes.
- `overlay` : Le runtime de conteneurs (containerd) utilise le filesystem overlay pour empiler les couches d'images Docker.

#### Étape 3 : Persister les modules au redémarrage
```yaml
- name: "Assurer que les modules du noyau sont chargés au démarrage"
  copy:
    dest: /etc/modules-load.d/k8s.conf
    content: |
      br_netfilter
      overlay
```

#### Étape 4 : Configurer les paramètres réseau (sysctl)
```yaml
- name: "Configurer les paramètres sysctl pour Kubernetes au démarrage"
  copy:
    dest: /etc/sysctl.d/k8s.conf
    content: |
      net.bridge.bridge-nf-call-iptables = 1     # Le trafic bridge passe par iptables (IPv4)
      net.bridge.bridge-nf-call-ip6tables = 1    # Idem pour IPv6
      net.ipv4.ip_forward = 1                     # Permet le routage de paquets entre interfaces
```
**Pourquoi** : Sans `ip_forward = 1`, un nœud ne peut pas router le trafic vers les pods d'un autre nœud. Les deux paramètres `bridge-nf-call-*` permettent aux règles de filtrage réseau de Kubernetes (kube-proxy) de s'appliquer au trafic des conteneurs.

#### Étape 5 : Installer containerd
```yaml
- name: "Installation de containerd"
  dnf:
    name: containerd
    state: present

- name: "Générer le fichier de configuration de containerd"
  command: "containerd config default > /etc/containerd/config.toml"

- name: "Activer SystemdCgroup dans la configuration de containerd"
  lineinfile:
    path: /etc/containerd/config.toml
    regexp: 'SystemdCgroup = false'
    line: 'SystemdCgroup = true'
```
**Pourquoi containerd** : C'est le runtime de conteneurs. Il télécharge les images, crée et exécute les conteneurs. Kubernetes ne fait pas ça directement, il délègue à containerd.

**Pourquoi SystemdCgroup = true** : Le kubelet utilise systemd pour gérer les cgroups (limites de ressources CPU/mémoire). Il faut que containerd utilise le même driver, sinon des conflits surviennent et les pods crashent.

#### Étape 6 : Installer Kubernetes
```yaml
- name: "Ajouter le dépôt de Kubernetes"
  copy:
    dest: /etc/yum.repos.d/kubernetes.repo
    content: |
      [kubernetes]
      name=Kubernetes
      baseurl=https://pkgs.k8s.io/core:/stable:/v1.35/rpm/
      ...

- name: "Installer kubelet, kubeadm et kubectl"
  dnf:
    name: [kubelet, kubeadm, kubectl]
    state: present
    disable_excludes: kubernetes

- name: "Démarrer et activer kubelet"
  systemd:
    name: kubelet
    state: started
    enabled: yes
```
Les 3 binaires installés :
- **kubelet** : L'agent sur chaque nœud. Il reçoit les instructions de l'API Server et démarre/arrête les conteneurs localement.
- **kubeadm** : L'outil de bootstrap. Utilisé pour `kubeadm init` (master) et `kubeadm join` (workers).
- **kubectl** : La CLI pour interagir avec le cluster (optionnel sur les workers, utile pour le debug).

### 5.7 Rôle k8s_master — Initialisation du control-plane

Fichier : `ansible/roles/k8s_master/tasks/main.yml`

#### Étape 1 : Initialiser le cluster (si pas déjà fait)
```yaml
- name: "[MASTER] Vérifier si le cluster est déjà initialisé"
  stat:
    path: /etc/kubernetes/admin.conf      # Ce fichier existe seulement après kubeadm init
  register: kubeadm_init_done

- name: "[MASTER] Initialiser le control-plane avec kubeadm"
  command: kubeadm init
  when: not kubeadm_init_done.stat.exists  # Idempotent : ne relance pas si déjà fait
```
**`kubeadm init` fait tout ça automatiquement :**
1. Génère les certificats TLS (dans `/etc/kubernetes/pki/`)
2. Démarre etcd (base de données du cluster)
3. Démarre l'API Server, le Scheduler, le Controller Manager
4. Crée le fichier `admin.conf` (kubeconfig de l'admin)
5. Génère un token pour que les workers puissent rejoindre le cluster

**Le `when:` est crucial** : c'est le mécanisme d'**idempotence**. Si on relance le playbook, `kubeadm init` ne sera pas ré-exécuté car `admin.conf` existe déjà.

#### Étape 2 : Configurer KUBECONFIG
```yaml
- name: "[MASTER] Exporter KUBECONFIG dans .bashrc (root)"
  lineinfile:
    path: /root/.bashrc
    line: "export KUBECONFIG=/etc/kubernetes/admin.conf"
```
Sans cette variable, `kubectl` cherche à se connecter sur `127.0.0.1:8080` (par défaut), ce qui échoue. Le fichier `admin.conf` contient l'URL de l'API Server + les certificats admin.

#### Étape 3 : Installer Calico (CNI)
```yaml
- name: "[CALICO] Attendre que l'API server soit disponible"
  wait_for:
    host: 127.0.0.1
    port: 6443               # Port de l'API Server
    timeout: 120

- name: "[CALICO] Vérifier si Calico est déjà déployé"
  shell: kubectl get daemonset calico-node -n kube-system 2>/dev/null
  register: calico_check
  failed_when: false

- name: "[CALICO] Déployer le CNI Calico"
  shell: kubectl apply -f {{ calico_manifest_url }}
  when: calico_check.rc != 0   # Seulement si Calico n'est pas déjà là
```
`kubectl apply -f <URL>` télécharge le manifeste YAML Calico depuis GitHub et l'applique au cluster. Cela crée :
- Un **DaemonSet** `calico-node` (un pod Calico sur chaque nœud)
- Les **IPPools** (plages d'IP pour les pods)
- Les ConfigMaps et CRDs nécessaires

#### Étape 4 : Générer la commande join pour les workers
```yaml
- name: "[MASTER] Récupérer la commande kubeadm join"
  shell: kubeadm token create --print-join-command
  register: join_command

- name: "[MASTER] Sauvegarder la commande join dans un fact partagé"
  set_fact:
    kubeadm_join_command: "{{ join_command.stdout }}"
```
**Mécanisme clé** : Le master génère une commande du type :
```
kubeadm join 10.0.3.214:6443 --token abc123 --discovery-token-ca-cert-hash sha256:xyz789
```
Cette commande est stockée dans un **fact Ansible** (`kubeadm_join_command`). Les workers la récupéreront ensuite via `hostvars`.

### 5.8 Rôle k8s_worker — Jonction des workers au cluster

Fichier : `ansible/roles/k8s_worker/tasks/main.yml`

```yaml
- name: "[WORKER] Vérifier si le noeud est déjà joint au cluster"
  stat:
    path: /etc/kubernetes/kubelet.conf     # Existe seulement après un kubeadm join réussi
  register: worker_joined

- name: "[WORKER] Récupérer la commande join depuis le master"
  set_fact:
    kubeadm_join_command: "{{ hostvars[groups['k8s_master'][0]]['kubeadm_join_command'] }}"
```

**`hostvars` expliqué** :
- `groups['k8s_master'][0]` → le premier (et seul) hôte du groupe `k8s_master`, soit `master`.
- `hostvars['master']['kubeadm_join_command']` → la variable stockée lors du play précédent sur le master.
- C'est comme ça que les données circulent d'un play (master) à un autre (workers) dans Ansible.

```yaml
- name: "[WORKER] Joindre le cluster Kubernetes"
  shell: "{{ kubeadm_join_command }}"
  when: not worker_joined.stat.exists       # Ne rejoint pas si déjà fait
```

Après cette étape, le worker :
1. Contacte l'API Server du master (port 6443)
2. Valide le token + le hash du certificat CA
3. Reçoit sa configuration kubelet
4. Démarre son kubelet qui s'enregistre comme nœud dans le cluster

### 5.9 Lancer le déploiement

```bash
cd ansible
ansible-playbook -i inventory.yml setup_cluster_playbook.yml
```

**Options utiles :**
```bash
# Exécuter seulement le rôle k8s_common (tag)
ansible-playbook -i inventory.yml setup_cluster_playbook.yml --tags common

# Exécuter seulement sur le master
ansible-playbook -i inventory.yml setup_cluster_playbook.yml --tags master

# Mode verbose (debug)
ansible-playbook -i inventory.yml setup_cluster_playbook.yml -vvv

# Mode dry-run (vérifier sans exécuter)
ansible-playbook -i inventory.yml setup_cluster_playbook.yml --check
```

**Tester la connectivité avant de déployer :**
```bash
ansible-playbook -i inventory.yml test_connectivity.yml
```
Ce playbook utilise le rôle `test_connectivity` qui vérifie :
- Le ping SSH vers chaque machine
- Le hostname de chaque machine
- L'OS détecté

---

## 6. Partie 2 — Déploiement d'une application avec Helm

### 6.1 Structure du Helm Chart (charts/sample-app/)

Ce chart déploie une **application Laravel** (PHP) avec une **base de données MySQL** (Percona XtraDB Cluster).

```
charts/sample-app/
├── Chart.yaml              # Carte d'identité du chart
├── Chart.lock              # Versions verrouillées des dépendances
├── values.yaml             # Variables par défaut
├── secrets.example.yaml    # Modèle pour les secrets (à copier en secrets.yaml)
└── templates/              # Les templates YAML Kubernetes
    ├── _helpers.tpl        # Fonctions Go réutilisables (nommage)
    ├── deployment.yaml     # Le Deployment de l'app
    ├── service.yaml        # Le Service réseau
    ├── secrets.yaml        # Les Secrets Kubernetes
    ├── migration-job.yaml  # Job de migration BDD (Helm Hook)
    ├── serviceaccount.yaml # Compte de service
    ├── hpa.yaml            # Autoscaling horizontal (désactivé)
    ├── ingress.yaml        # Ingress (désactivé)
    ├── httproute.yaml      # HTTPRoute Gateway API (désactivé)
    └── NOTES.txt           # Message affiché après `helm install`
```

### 6.2 Chart.yaml — la carte d'identité

```yaml
apiVersion: v2
name: sample-app
description: Helm chart pour l'application "sample-app" du projet T-CLO-902
type: application           # (vs "library" qui est un chart réutilisable sans déploiement)
version: 0.1.0              # Version du CHART (pas de l'app)
appVersion: "1.0.0"         # Version de l'APPLICATION

dependencies:
  - name: pxc-db                                              # Percona XtraDB Cluster
    version: 1.19.0
    repository: https://percona.github.io/percona-helm-charts/
```

**La dépendance `pxc-db`** : C'est un sous-chart (subchart). Quand on exécute `helm install`, Helm déploie automatiquement Percona XtraDB Cluster (un MySQL haute disponibilité) en plus de l'app Laravel. On n'a pas à gérer le déploiement de la BDD manuellement.

Pour télécharger la dépendance :
```bash
helm dependency update charts/sample-app
```
Cela génère le fichier `Chart.lock` et télécharge le `.tgz` du subchart dans `charts/sample-app/charts/`.

### 6.3 values.yaml — les variables paramétrables

```yaml
replicaCount: 2                    # 2 pods de l'app (haute disponibilité)

image:
  repository: "ghcr.io/epitechmscpropromo2026/sample-app"  # Image Docker (GitHub Container Registry)
  pullPolicy: IfNotPresent         # Ne re-télécharge que si l'image n'est pas en cache
  tag: "latest"                    # Tag de l'image

service:
  type: ClusterIP                  # Accessible uniquement au sein du cluster
  port: 80

app:
  env: "production"
  debug: false
  key: ""                          # ⚠️ À remplir via secrets.yaml

database:
  host: "t-clo-902-db-cluster"    # Nom du Service Kubernetes de la BDD Percona
  name: "laravel"
  user: "sample_app_user"
  password: ""                     # ⚠️ À remplir via secrets.yaml
```

**Comment surcharger les valeurs :**
1. Créer `secrets.yaml` à partir de `secrets.example.yaml` :
   ```yaml
   app:
     key: "base64:votre_clé_laravel"
   database:
     password: "votre_mot_de_passe_bdd"
   ```
2. Passer les deux fichiers lors du `helm install` :
   ```bash
   helm install my-app charts/sample-app -f charts/sample-app/secrets.yaml
   ```
   Le fichier `-f` surcharge les valeurs de `values.yaml`.

### 6.4 Les templates détaillés

#### _helpers.tpl — Les fonctions réutilisables

Ce fichier définit des fonctions Go Template utilisées dans tous les autres templates :

- **`sample-app.name`** : Retourne le nom du chart (`sample-app`), tronqué à 63 caractères (limite DNS de Kubernetes).
- **`sample-app.fullname`** : Combine le nom de la release + le nom du chart (ex: `my-app-sample-app`).
- **`sample-app.labels`** : Génère les labels standards Kubernetes appliqués à toutes les ressources.
- **`sample-app.selectorLabels`** : Labels utilisés par le Deployment pour identifier ses pods.
- **`sample-app.serviceAccountName`** : Nom du ServiceAccount.

#### deployment.yaml — Le Deployment

C'est le cœur du déploiement. Il crée des pods avec l'image Docker de l'app Laravel.

Points importants :
- `replicas: {{ .Values.replicaCount }}` → 2 pods par défaut.
- L'image est `ghcr.io/epitechmscpropromo2026/sample-app:latest`.
- Les variables d'environnement (`APP_ENV`, `APP_KEY`, `DB_HOST`, `DB_PASSWORD`…) sont injectées dans le conteneur.
- `APP_KEY` et `DB_PASSWORD` viennent d'un **Secret Kubernetes** (pas en clair dans le YAML).
- Le conteneur écoute sur le port 80 (HTTP).

#### service.yaml — Le Service

```yaml
spec:
  type: ClusterIP           # Accessible uniquement à l'intérieur du cluster
  ports:
    - port: 80              # Port du Service
      targetPort: http      # Redirige vers le port "http" du conteneur (80)
  selector:                 # Sélectionne les pods par leurs labels
    app.kubernetes.io/name: sample-app
    app.kubernetes.io/instance: my-app
```

Le Service crée une **adresse IP virtuelle stable** dans le cluster. Même si les pods sont recréés (nouvelle IP), le Service garde la même adresse.

### 6.5 Le mécanisme de Helm Hook (migration-job)

Fichier : `templates/migration-job.yaml`

```yaml
metadata:
  annotations:
    "helm.sh/hook": pre-install,pre-upgrade       # S'exécute AVANT l'install ou l'upgrade
    "helm.sh/hook-weight": "-5"                     # Priorité (plus négatif = plus tôt)
    "helm.sh/hook-delete-policy": hook-succeeded,before-hook-creation
```

**Comment ça marche :**
1. Tu exécutes `helm install my-app charts/sample-app`
2. Helm voit l'annotation `pre-install` sur le Job
3. **Avant** de créer le Deployment et le Service, Helm crée le Job de migration
4. Le Job lance un pod temporaire qui exécute `php artisan migrate --force`
5. La migration crée/met à jour les tables dans la BDD
6. Une fois terminé avec succès, le Job est supprimé (`hook-succeeded`)
7. Helm continue et crée le Deployment, le Service, etc.

**`hook-delete-policy` expliqué :**
- `hook-succeeded` : Supprime le Job après succès (ne laisse pas de ressources orphelines)
- `before-hook-creation` : Supprime un ancien Job du même nom avant d'en créer un nouveau (utile lors d'un `helm upgrade`)

### 6.6 Les secrets

Fichier : `templates/secrets.yaml`

```yaml
apiVersion: v1
kind: Secret
type: Opaque
data:
  app-key: {{ .Values.app.key | b64enc | quote }}
  db-password: {{ .Values.database.password | b64enc | quote }}
```

Les secrets Kubernetes stockent les données en **base64** (pas chiffré, juste encodé). La fonction `b64enc` de Helm encode automatiquement la valeur.

Le Deployment référence ces secrets via `secretKeyRef` :
```yaml
env:
  - name: APP_KEY
    valueFrom:
      secretKeyRef:
        name: my-app-sample-app-app-secrets
        key: app-key
```

**Le fichier `secrets.yaml` est dans le `.gitignore`** → il ne doit jamais être commité.

### 6.7 Commandes Helm pour déployer

```bash
# 1. Télécharger les dépendances (Percona)
helm dependency update charts/sample-app

# 2. Vérifier la syntaxe
helm lint charts/sample-app

# 3. Prévisualiser les YAML générés (sans rien déployer)
helm template my-laravel-app charts/sample-app -f charts/sample-app/secrets.yaml

# 4. Déployer
helm install my-laravel-app charts/sample-app -f charts/sample-app/secrets.yaml

# 5. Mettre à jour (après changement de values ou nouvelle image)
helm upgrade my-laravel-app charts/sample-app -f charts/sample-app/secrets.yaml

# 6. Voir les releases déployées
helm ls

# 7. Supprimer
helm uninstall my-laravel-app
```

---

## 7. Partie 3 — Installation de Headlamp (Dashboard Kubernetes)

### 7.1 Qu'est-ce que Headlamp ?

Headlamp est une **interface web open-source** pour Kubernetes. Elle permet de visualiser dans un navigateur :
- Les pods, deployments, services, namespaces
- Les logs des conteneurs
- L'état des nœuds
- Les ressources RBAC

C'est un **tableau de bord** pour visualiser le cluster sans taper de commandes `kubectl`.

### 7.2 Architecture du déploiement Headlamp

```
┌─────────────────────────────────────────────────────────┐
│                  Navigateur (ton PC)                     │
│                       │                                  │
│              HTTP :30080 (NodePort)                       │
│                       │                                  │
│  ┌────────────────────▼────────────────────────┐        │
│  │           Namespace: headlamp               │        │
│  │                                              │        │
│  │  Service NodePort ────► Headlamp Pod (:4466) │        │
│  │  (headlamp-nodeport)     │                   │        │
│  │                          │                   │        │
│  │                ServiceAccount                │        │
│  │               (headlamp-admin)               │        │
│  └──────────────────┬──────────────────────────┘        │
│                     │                                    │
│          ClusterRoleBinding                              │
│          (headlamp-admin)                                │
│                     │                                    │
│            ClusterRole                                   │
│          (headlamp-viewer)                               │
│          get/list/watch only                             │
│                     │                                    │
│           Kubernetes API Server                          │
└─────────────────────────────────────────────────────────┘
```

Le déploiement combine **2 outils** :
1. **Helm** : installe le chart officiel Headlamp (crée le Deployment + Pod)
2. **Kustomize** : applique les ressources complémentaires (ServiceAccount, RBAC, Service NodePort)

### 7.3 Les ressources Kustomize (infra/headlamp/)

#### kustomization.yaml
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - serviceaccount.yaml
  - clusterrole.yaml
  - clusterrolebinding.yaml
  - service-nodeport.yaml
```
Ce fichier liste simplement les manifestes à appliquer. `kubectl apply -k infra/headlamp/` les applique tous d'un coup.

#### serviceaccount.yaml
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: headlamp-admin
  namespace: headlamp
```
Un **ServiceAccount** est une identité utilisée par un pod pour s'authentifier auprès de l'API Server. Headlamp utilise ce compte pour lire les ressources du cluster.

#### clusterrole.yaml — Les permissions
```yaml
kind: ClusterRole
metadata:
  name: headlamp-viewer
rules:
  - apiGroups: [""]
    resources: [configmaps, endpoints, events, namespaces, nodes, pods, pods/log, services, ...]
    verbs: ["get", "list", "watch"]    # LECTURE SEULE
  - apiGroups: ["apps"]
    resources: [daemonsets, deployments, replicasets, statefulsets]
    verbs: ["get", "list", "watch"]
  # ... idem pour batch, autoscaling, networking, storage, policy, rbac
```

**Points de sécurité importants :**
- Uniquement `get`, `list`, `watch` → **aucune écriture** possible.
- Les **Secrets** sont **volontairement exclus** → Headlamp ne peut pas lire les secrets du cluster (vecteur de risque inutile via une UI web).

#### clusterrolebinding.yaml — Le lien
```yaml
kind: ClusterRoleBinding
metadata:
  name: headlamp-admin
roleRef:
  kind: ClusterRole
  name: headlamp-viewer          # Le ClusterRole défini ci-dessus
subjects:
  - kind: ServiceAccount
    name: headlamp-admin         # Le ServiceAccount créé ci-dessus
    namespace: headlamp
```
Le **ClusterRoleBinding** fait le lien : « le ServiceAccount `headlamp-admin` a les permissions du ClusterRole `headlamp-viewer` ».

#### service-nodeport.yaml — L'exposition réseau
```yaml
kind: Service
metadata:
  name: headlamp-nodeport
  namespace: headlamp
spec:
  type: NodePort
  selector:
    app.kubernetes.io/name: headlamp     # Cible le pod Headlamp
  ports:
    - port: 80
      targetPort: 4466                    # Port du conteneur Headlamp
      nodePort: 30080                     # Port ouvert sur CHAQUE nœud
```

**NodePort** signifie que le port 30080 est ouvert sur **chaque nœud** du cluster (master + workers). Même si le pod Headlamp tourne uniquement sur worker1, tu peux y accéder via `http://<IP_MASTER>:30080` car Kubernetes route le trafic vers le bon pod.

### 7.4 Le rôle Ansible headlamp

Fichier : `ansible/roles/headlamp/tasks/main.yml`

Ce rôle automatise tout le déploiement. Voici les étapes :

#### 1. Installer Helm sur le master (si absent)
```yaml
- name: "[HEADLAMP] Vérifier que Helm est disponible"
  command: helm version
  register: helm_version
  failed_when: false

- name: "[HEADLAMP] Installer Helm (si absent)"
  when: helm_version.rc != 0
  block:
    - get_url:
        url: "https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3"
        dest: /tmp/get-helm-3
    - command: /tmp/get-helm-3
```

#### 2. Ajouter le dépôt Helm Headlamp
```yaml
- shell: |
    helm repo add headlamp https://headlamp-k8s.github.io/headlamp/ 2>/dev/null || true
    helm repo update
```
`helm repo add` enregistre un dépôt de charts. `helm repo update` rafraîchit l'index des charts disponibles.

#### 3. Résoudre le nom de nœud Kubernetes pour forcer le pod sur worker1
```yaml
- shell: |
    target_ip="{{ hostvars[headlamp_target_worker].ansible_host }}"
    kubectl get nodes \
      -o 'custom-columns=NAME:.metadata.name,IP:.status.addresses[?(@.type=="InternalIP")].address' \
      --no-headers \
      | awk -v ip="$target_ip" '$2 == ip { print $1 }'
  register: headlamp_target_node_name
```
**Explication** : L'inventaire Ansible connaît l'IP privée de worker1 (`10.0.3.198`). Mais Kubernetes donne souvent un nom différent aux nœuds (ex: `ip-10-0-3-198.eu-west-3.compute.internal`). Cette tâche fait la correspondance IP → nom Kubernetes.

#### 4. Déployer Headlamp via Helm
```yaml
- shell: |
    helm upgrade --install headlamp headlamp/headlamp \
      --namespace headlamp \
      --create-namespace \
      --set "nodeSelector.kubernetes\\.io/hostname=${target_node}"
```
- `--create-namespace` : Crée le namespace `headlamp` s'il n'existe pas.
- `--set "nodeSelector..."` : Force le pod Headlamp à être schedulé sur worker1 uniquement.
- `upgrade --install` : Idempotent — installe si absent, met à jour si présent.

#### 5. Copier et appliquer les manifestes Kustomize
```yaml
- name: "Copier les manifests Kustomize sur le master"
  copy:
    src: "{{ headlamp_kustomize_src }}/"      # infra/headlamp/ (côté contrôleur)
    dest: /tmp/kubequest/infra/headlamp/      # Copié sur le master

- name: "Appliquer les ressources complémentaires"
  shell: kubectl apply -k /tmp/kubequest/infra/headlamp/
```
Les fichiers YAML (ServiceAccount, ClusterRole, etc.) sont d'abord copiés sur le master via SSH, puis appliqués avec `kubectl apply -k`.

#### Variable par défaut
Fichier `roles/headlamp/defaults/main.yml` :
```yaml
headlamp_kustomize_src: "{{ playbook_dir }}/../infra/headlamp"
```
`playbook_dir` est une variable Ansible qui pointe vers le dossier contenant le playbook (ici `ansible/`). Donc le chemin résolu est `ansible/../infra/headlamp` = `infra/headlamp` à la racine du projet.

#### Lancer le déploiement Headlamp
```bash
cd ansible
ansible-playbook -i inventory.yml deploy_headlamp.yml
```

### 7.5 Accéder à l'interface Headlamp

Le pod Headlamp écoute sur le port 4466, exposé via un **NodePort 30080** sur tous les nœuds.

**Problème** : Les workers n'ont que des IP privées → inaccessibles depuis Internet.

**Solution 1 — Tunnel SSH (recommandé)** :
```bash
ssh -i ~/.ssh/kubequest.pem -N -L 30080:127.0.0.1:30080 ec2-user@15.237.15.14
```
Puis ouvrir : **http://localhost:30080**

**Explication du tunnel** :
- `-N` : Ne pas ouvrir de shell, juste le tunnel.
- `-L 30080:127.0.0.1:30080` : Tout ce qui arrive sur le port 30080 de ton PC est redirigé vers `127.0.0.1:30080` **sur le master**. Et comme le NodePort 30080 écoute sur tous les nœuds (y compris le master), ça fonctionne.

**Solution 2 — Security Group AWS** :
Ouvrir le port TCP 30080 en entrée dans le Security Group de l'instance EC2, puis accéder via l'IP publique : `http://15.237.15.14:30080`.

### 7.6 Authentification par token

Headlamp demande un **token** pour se connecter. Ce token est lié au ServiceAccount `headlamp-admin`.

**Générer un token (sur le master)** :
```bash
sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl create token headlamp-admin -n headlamp --duration=48h
```

- `--duration=48h` : Le token expire après 48h (bonne pratique de sécurité).
- Coller le token dans l'interface web de Headlamp.
- **Ne jamais** commiter ou partager ce token.

**Pourquoi le playbook ne génère pas le token ?** Pour des raisons de sécurité : le token n'apparaît ni dans les logs Ansible, ni dans la CI, ni dans un fichier sur le serveur. On le génère manuellement, à la demande.

---

## 8. CI/CD — GitHub Actions

Le projet dispose de 2 workflows GitHub Actions :

### docker-build.yml — Build de l'image Docker
- **Trigger** : Push sur n'importe quelle branche modifiant `resources/sample-app-master/`
- **Runner** : `self-hosted` (exécuté sur une de vos machines)
- **Actions** :
  1. Checkout du code
  2. Build de l'image Docker depuis `resources/sample-app-master/Dockerfile`
  3. Push vers GitHub Container Registry (`ghcr.io/epitechmscpropromo2026/sample-app`)
  4. Tag `latest` sur `main`, hash du commit sur les autres branches

### test-connectivity.yml — Tests et déploiement
- **Trigger** : Push ou PR merged sur `main`
- **Job 1 — test-connectivity** :
  1. Valide les manifestes Kustomize (`kubectl kustomize infra/headlamp/`)
- **Job 2 — deploy** (seulement sur push, après succès du job 1) :
  1. Installe Ansible
  2. Configure la clé SSH (depuis un secret GitHub `EC2_SSH_KEY`)
  3. Lance `ansible-playbook test_connectivity.yml` pour vérifier les instances

---

## 9. Résumé des commandes

### Cluster Kubernetes (Ansible)
```bash
# Tester la connectivité
cd ansible
ansible-playbook -i inventory.yml test_connectivity.yml

# Déployer le cluster complet
ansible-playbook -i inventory.yml setup_cluster_playbook.yml

# Déployer Headlamp
ansible-playbook -i inventory.yml deploy_headlamp.yml
```

### Application (Helm)
```bash
# Télécharger les dépendances
helm dependency update charts/sample-app

# Vérifier la syntaxe
helm lint charts/sample-app

# Prévisualiser sans déployer
helm template my-app charts/sample-app -f charts/sample-app/secrets.yaml

# Déployer
helm install my-app charts/sample-app -f charts/sample-app/secrets.yaml

# Mettre à jour
helm upgrade my-app charts/sample-app -f charts/sample-app/secrets.yaml

# Supprimer
helm uninstall my-app
```

### Vérification du cluster (kubectl)
```bash
# État des nœuds
kubectl get nodes -o wide

# Tous les pods
kubectl get pods -A -o wide

# Pods Headlamp
kubectl get pods,svc,endpoints -n headlamp -o wide

# Générer un token Headlamp
kubectl create token headlamp-admin -n headlamp --duration=48h
```

### Accès Headlamp
```bash
# Tunnel SSH
ssh -i ~/.ssh/kubequest.pem -N -L 30080:127.0.0.1:30080 ec2-user@15.237.15.14
# Puis ouvrir http://localhost:30080
```

---

## 10. Glossaire

| Terme | Définition |
|---|---|
| **API Server** | Point d'entrée central de Kubernetes. Toutes les commandes (`kubectl`, kubelet, dashboard) passent par lui. |
| **etcd** | Base de données clé-valeur distribuée qui stocke tout l'état du cluster. |
| **CNI** | Container Network Interface — standard pour les plugins réseau des conteneurs. |
| **Calico** | Plugin CNI qui gère le réseau entre les pods et les NetworkPolicies. |
| **containerd** | Runtime de conteneurs. Télécharge les images et exécute les conteneurs (remplaçant de Docker dans K8s). |
| **cgroup** | Control Group — mécanisme Linux pour limiter les ressources (CPU, mémoire) d'un processus. |
| **systemd** | Système d'init de Linux. Gère les services (démarrage, arrêt, redémarrage). |
| **sysctl** | Outil pour modifier les paramètres du noyau Linux à chaud. |
| **modprobe** | Charge un module du noyau Linux. |
| **fstab** | Fichier Linux qui définit les disques montés automatiquement au démarrage. |
| **VPC** | Virtual Private Cloud — réseau privé virtuel dans AWS. |
| **Security Group** | Pare-feu virtuel AWS attaché aux instances EC2. |
| **NodePort** | Type de Service K8s qui ouvre un port fixe (30000-32767) sur tous les nœuds. |
| **ClusterIP** | Type de Service K8s accessible uniquement depuis l'intérieur du cluster. |
| **RBAC** | Role-Based Access Control — système de permissions Kubernetes. |
| **Kustomize** | Outil de personnalisation de manifestes YAML sans templates (intégré à kubectl). |
| **Helm Hook** | Mécanisme pour exécuter des actions à des moments précis du cycle de vie Helm. |
| **ProxyCommand** | Option SSH pour passer par une machine intermédiaire (jump host). |
| **Idempotence** | Propriété d'une opération qui produit le même résultat qu'elle soit exécutée 1 ou N fois. |
| **DaemonSet** | Objet K8s qui garantit qu'un pod tourne sur chaque nœud du cluster. |
| **HPA** | Horizontal Pod Autoscaler — ajuste automatiquement le nombre de réplicas selon la charge. |
