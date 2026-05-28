# Migration d'Envoy Gateway vers Traefik

## Contexte

Le projet KubeQuest utilise la **Kubernetes Gateway API** pour exposer les services du cluster vers l'extérieur. Initialement, **Envoy Gateway** avait été choisi comme implémentation de référence de la Gateway API.

## Problèmes rencontrés avec Envoy Gateway

### 1. Dépendance à un Service LoadBalancer

Envoy Gateway crée automatiquement un **Service de type LoadBalancer** pour exposer le traffic entrant. Sur un cluster Kubernetes auto-géré sur AWS EC2 (sans cloud-controller-manager), ce Service reste en état `Pending` indéfiniment car aucun composant ne provisionne d'adresse IP externe.

### 2. Complexité de la solution de contournement

Pour pallier l'absence de LoadBalancer, plusieurs solutions ont été tentées :
- **NodePort + Nginx reverse proxy** : fonctionnel mais ajoutant une couche supplémentaire inutile
- **NodePort fixe (30080)** : nécessite d'ouvrir un port non-standard dans le Security Group AWS
- **hostNetwork sur le master** : Envoy Gateway ne supporte pas nativement le mode `hostNetwork` de manière simple dans sa configuration

### 3. Gestion des ressources EnvoyProxy

Envoy Gateway nécessite la création d'une ressource `EnvoyProxy` custom pour configurer le comportement du data plane (nodeSelector, tolerations, etc.), ce qui ajoute de la complexité et des ressources spécifiques au provider.

### 4. Incompatibilité avec les contraintes d'infrastructure

Les contraintes du projet sont :
- **Pas de création de ressources AWS supplémentaires** (pas de NLB, pas de modification de Security Groups)
- **Seul le port 80 est ouvert** sur l'IP publique du master (15.237.15.14)
- Le cluster est auto-géré sans cloud-controller

Envoy Gateway n'offre pas de moyen simple de binder directement le port 80 sur le noeud master via hostNetwork.

## Pourquoi Traefik ?

### 1. Support natif de hostNetwork

Traefik supporte nativement le mode `hostNetwork` via son Helm chart, permettant au pod de binder directement sur les ports de l'hôte (port 80) sans passer par un Service Kubernetes.

### 2. Provider Kubernetes Gateway intégré

Traefik implémente la Kubernetes Gateway API via son provider `kubernetesGateway`. Il suffit d'activer `providers.kubernetesGateway.enabled: true` dans les values Helm pour que Traefik programme les ressources Gateway, HTTPRoute, etc.

### 3. Configuration simplifiée

Avec Traefik :
- **Pas de Service LoadBalancer** nécessaire (`service.enabled: false`)
- **hostNetwork** configuré directement dans les values Helm
- **nodeSelector + tolerations** pour épingler le pod sur le master (control-plane)
- Le GatewayClass est créé automatiquement par le chart Helm

### 4. Maturité et communauté

Traefik est un reverse proxy / ingress controller mature, largement utilisé dans l'écosystème Kubernetes, avec une documentation complète et un Helm chart activement maintenu.

## Résumé de la migration

| Aspect | Envoy Gateway | Traefik |
|--------|---------------|---------|
| Service exposé | LoadBalancer (Pending) | Aucun (hostNetwork) |
| Port d'écoute | Port aléatoire NodePort | Port 80 directement |
| Configuration hostNetwork | Non supporté simplement | Natif via Helm values |
| Ressources custom | EnvoyProxy CRD | Aucune |
| Gateway API | Support complet | Support complet |
| Complexité | Élevée (contournements) | Faible (configuration directe) |
