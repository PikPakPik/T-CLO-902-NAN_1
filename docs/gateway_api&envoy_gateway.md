2. Pourquoi Envoy Gateway ?
   C'est l'implémentation de référence de Gateway API — c'est le premier contrôleur à implémenter pleinement la spécification Gateway API (initiée par la communauté Kubernetes elle-même).

Avantages par rapport à l'Ingress classique :

Modèle orienté rôles : séparation claire entre infrastructure (Gateway) et applications (HTTPRoute)
Multi-tenancy : un Gateway peut servir plusieurs équipes avec des namespaces isolés
Plus expressif : filtres, redirections, réécritures, load balancing avancé, mirroring de trafic
Standard CNCF : portable entre fournisseurs cloud (AWS, GCP, Azure)
Pourquoi pas NGINX Ingress ? L'Ingress traditionnel utilise des annotations propriétaires qui varient d'un contrôleur à l'autre. Gateway API est une API unifiée, nativement supportée par Envoy, Cilium, Istio, etc.
