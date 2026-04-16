# Connexion en SSH aux machines distantes

- ``ProxyCommand="ssh -i ~/.ssh/kubequest.pem -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -W %h:%p ec2-user@15.237.15.14"``
Permet de lancer une connexion SSH intermédiaire vers le serveur Proxy plus communément appeler Bastion permettant d'ouvrir un tunnel TCP vers le serveur cible.
Les informations de connexion vers le serveur cible sont données via ``%h``=host et ``%p`` = port

- ``StrictHostKeyChecking=no``
Permet de désactiver la vérification interactive de clé d'hôte, question de vérification généralement posée lors de la première connexion à une machine.
Se procéder est généralement utilisé pour l'automatisation des déploiements auto-gérés par Ansible par exemple.

- ``UserKnownHostsFile=/dev/null``
Permet d'indiquer au service SSH qu'il n'est pas nécessaire d'interprêter le fichier ``known_hosts``.
Le fichier ``known_hosts`` est une base de données interne des hôtes connus par le client SSH via des connexions déjà établies.
Dans ce cas, les clés d'hôtes ne sont pas sauvegardées de ce fait aucune vérification ne seraient fait lors des connexions.

Voici un exemple de la commande à exécuter afin d'initier une connexion entre la machine client et la machine distance :
```bash
ssh -i ~/.ssh/kubequest.pem -o ProxyCommand="ssh -i ~/.ssh/kubequest.pem -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -W %h:%p ec2-user@15.237.15.14" ec2-user@10.0.3.198
```