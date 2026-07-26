# Postiz — auto-hébergement

Stack Postiz (publication programmée sur réseaux sociaux) derrière un Traefik
existant, avec sauvegarde borgwarehouse. Le code source de Postiz est cloné pour
référence dans `github/` (gitignoré, jamais modifié ni versionné ici) — ce dépôt ne
contient que la configuration de déploiement.

Design complet : `docs/superpowers/specs/2026-07-26-postiz-selfhost-design.md`
(non versionné, voir `.gitignore`).

## Prérequis sur le serveur

- Docker et le plugin `compose`, et `make`.
- Un Traefik déjà en place, avec un réseau Docker externe nommé `frontend` et un
  certresolver nommé `myresolver`. (Si tes noms diffèrent, adapte les `labels` et le
  bloc `networks` du `docker-compose.yml`.)
- Un enregistrement DNS A pointant `POSTIZ_DOMAIN` vers le serveur.
- `borg` installé sur l'hôte, et un serveur borgwarehouse joignable.
- Vérifier que le port `TEMPORAL_UI_PORT` (8233 par défaut) n'est pas déjà utilisé par
  un autre service de cet hôte avant de démarrer `temporal-ui` (profile `debug`).

Un `make` sans argument liste tout ce qu'on peut faire sur cette stack.

## Installation

```bash
git clone <ce depot> /opt/postiz
cd /opt/postiz

cp env_example .env && chmod 600 .env
openssl rand -hex 32        # pour JWT_SECRET
openssl rand -hex 32        # pour POSTGRES_PASSWORD
nano .env                   # POSTIZ_DOMAIN, secrets, email si utilise

mkdir -p ./data/config ./data/uploads ./data/postgres
sudo chown 999:999 ./data/postgres   # voir note UID plus bas
```

**Avant le tout premier `make up`**, pré-créer les attributs de recherche Temporal
dans le bon type (voir la ligne "Elasticsearch" du tableau ci-dessous pour le
pourquoi) :

```bash
docker compose up -d temporal-postgresql temporal
docker compose logs -f temporal   # attendre que le namespace "default" soit pret
docker compose --profile debug run --rm temporal-admin-tools \
  temporal operator search-attribute create --address temporal:7233 --namespace default \
  --name postId --type Keyword --name organizationId --type Keyword
```

(Syntaxe à vérifier au premier déploiement — `temporal operator search-attribute
create --help` dans le conteneur si la commande a changé entre-temps. Si cette étape
est sautée, Postiz créera lui-même ces attributs mais dans un type moins adapté ; une
fois créés, un attribut ne peut plus changer de type, donc autant bien faire dès le
départ.)

Puis démarrer le reste :

```bash
make up && make logs
```

Se rendre sur `https://<POSTIZ_DOMAIN>` pour créer le compte admin — **avant** de
renseigner `EMAIL_PROVIDER` dans `.env` (dès qu'un provider email est configuré,
l'activation par email devient obligatoire pour les comptes locaux, voir plus bas).

Vérifier que tout est vert :

```bash
make ps        # postiz, postiz-postgres, postiz-redis doivent etre "healthy"
```

Puis configurer la sauvegarde : `make init` (voir [`scripts/README.md`](./scripts/README.md)) —
**la stack doit déjà tourner** (`make up`), les scripts de sauvegarde passent par
`docker compose exec`. Une stack sans sauvegarde n'est pas en production.

## Ce qui diffère du compose officiel Postiz (et pourquoi)

| Point | Ce dépôt | Pourquoi |
|---|---|---|
| Image `postiz` | Épinglée `POSTIZ_VERSION` (`v2.22.1`), jamais `:latest` | Évite qu'un `pull` de routine saute une version majeure sans prévenir. **`version.txt` du dépôt amont n'est pas fiable** (il retarde toujours d'une version ou plus sur le vrai tag git) — se fier uniquement au tag git réel. La stack Temporal (orchestrator, `RUN_CRON`, `/health/status`) n'existe qu'à partir des versions 2.x : ne jamais épingler une version antérieure avec ce compose |
| `./data/config`, `./data/uploads`, `./data/postgres` | Bind mounts (pas de volumes Docker nommés) | Permet la sauvegarde borg de tout le dossier en une archive, et protège `./data/postgres` d'un `docker compose down -v` accidentel |
| `container_name`, noms de routers/services Traefik | Aucun `container_name` ; labels Traefik dérivés de `${COMPOSE_PROJECT_NAME}` | Les noms de conteneurs Docker et les noms de routers/services Traefik sont tous les deux globaux (à l'hôte Docker, et à l'instance Traefik respectivement), pas namespacés par projet — évite les collisions avec d'autres stacks du même serveur |
| Elasticsearch (Temporal) | Retiré (`ENABLE_ES=false`), visibilité SQL à la place | Évite une dépendance à un réglage noyau (`vm.max_map_count`) et économise ~700 Mo de RAM. **Point à surveiller** : Postiz recherche les workflows par l'attribut `postId` (pour annuler un post supprimé) — cet attribut est enregistré par défaut en type `Text`, qui ne se comporte pas comme un `Keyword` sur une égalité exacte en visibilité SQL. D'où l'étape "pré-créer les attributs" de l'installation ci-dessus. Après le premier déploiement, supprimer un post programmé de test et confirmer qu'il ne part pas quand même |
| `postiz` : `depends_on: temporal` | Ajouté (absent de l'officiel) | Sans ça, le backend peut crash-looper (sous pm2) au tout premier démarrage à froid, le temps que Temporal crée son schéma dans une base neuve |
| `temporal-ui`, `temporal-admin-tools` | `profiles: ["debug"]`, jamais démarrés par défaut, port loopback uniquement, réseau `debug-access` dédié | Aucun des deux n'a d'authentification native. Le réseau `debug-access` (non-internal) est nécessaire : un conteneur uniquement rattaché à des réseaux `internal: true` ne voit pas son port publié sur l'hôte sur les moteurs Docker récents. Démarrage à la demande : `docker compose --profile debug up -d temporal-ui` puis `ssh -L 8233:127.0.0.1:8233 user@serveur` (`make down` arrête aussi ce profile) |
| `RUN_CRON` | `true` | Filet de rattrapage qui rescanne les posts en retard de moins de 48h — nécessaire puisque la base Temporal n'est pas sauvegardée (régénérable par ailleurs) |
| Labels Traefik | `enable`/`docker.network`/`tls.certresolver`/`rule`/`loadbalancer.server.port` | Convention déjà en place sur les autres stacks de ce serveur, pas la syntaxe de la doc officielle Postiz |

**Non appliqué, à envisager selon la charge du serveur** : aucune limite `mem_limit`/`cpus`
n'est posée sur les services. Sur un hôte mutualisé, une fuite mémoire côté Postiz (ou
Elasticsearch si tu le réactives) peut déclencher l'OOM-killer du noyau, qui tue le plus
gros consommateur de RAM de la machine — pas forcément un conteneur de cette stack.
À dimensionner selon le serveur cible si plusieurs services lourds cohabitent dessus.
De même, pm2 écrit ses propres logs (`~/.pm2/logs/*` dans le conteneur `postiz`) qui ne
sont PAS couverts par la limite `logging: max-size` (celle-ci ne plafonne que le flux
stdout/stderr capté par Docker) — à surveiller si le disque du conteneur grossit de
façon inattendue.

## OAuth générique (Keycloak) — reporté

`POSTIZ_GENERIC_OAUTH` permettrait de déléguer la connexion à un Keycloak existant,
mais le provider `GENERIC` contourne `DISABLE_REGISTRATION` dans le code Postiz
(`auth.service.ts:24` — `canRegister` renvoie vrai pour ce provider quel que soit le
réglage) : n'importe quel compte du realm pourrait alors créer une organisation
Postiz. À activer uniquement avec un client Keycloak dédié à accès restreint
(rôle/groupe requis) — les variables sont présentes mais commentées dans
`env_example`, et **volontairement non câblées dans `docker-compose.yml`** tant que
la fonctionnalité est reportée (les décommenter seules dans `.env` ne suffira pas :
il faudra aussi les ajouter au compose).

## Sauvegarde et restauration

Voir [`scripts/README.md`](./scripts/README.md) pour le détail complet (mise en
place, vérification, restauration, rétention).

```bash
make init      # une seule fois : configure la sauvegarde (la stack doit tourner)
make backup    # sauvegarde manuelle
make check     # verifie que la derniere sauvegarde est restaurable
```

## Mise à jour

```bash
nano .env   # bumper POSTIZ_VERSION vers la nouvelle release
make update
```

`docker compose pull` seul ne ramène rien : l'image est épinglée par version exacte,
pas `:latest`. Voir les releases : https://github.com/gitroomhq/postiz-app/releases

`make update` sauvegarde automatiquement avant de mettre à jour (`--no-backup` pour
sauter cette étape, déconseillé), puis attend que `postiz` repasse en bonne santé
avant de rendre la main (jusqu'à 10 minutes : le healthcheck lui-même peut prendre
plusieurs minutes avant de savoir dire "en échec").

**En cas d'échec de mise à jour, ne PAS se contenter de redescendre `POSTIZ_VERSION`
vers l'ancien tag.** Postiz exécute `prisma db push --accept-data-loss` à chaque
démarrage, pas seulement au premier boot d'une version neuve : la base peut avoir
déjà migré vers un schéma que l'ancienne version ne sait plus lire, ou que la
redescente re-migrerait de façon destructive. La procédure sûre est de restaurer la
base depuis la sauvegarde prise juste avant (voir `scripts/README.md`), pas de
rejouer un ancien tag sur la base telle quelle.

## Dépannage

**`postiz` reste `unhealthy`** — `make logs`. Causes habituelles : variable
manquante dans `.env`, permissions sur `./data/uploads` ou `./data/config` (pas de
Dockerfile de production disponible pour confirmer l'UID exact de l'image — ajuster
l'ownership selon l'erreur observée dans les logs, ou simplement attendre : l'image
tourne apparemment en root d'après son Dockerfile de référence, donc l'écriture ne
devrait pas être bloquée).

**Erreur de connexion à la base** — vérifier qu'aucune variable `POSTGRES_*` n'a été
modifiée depuis l'initialisation de la base.

**`postiz-postgres` refuse de démarrer / erreurs de permission sur `./data/postgres`**
— le `chown 999:999` de l'installation vise l'UID interne habituel des images
`postgres` récentes ; si ça ne correspond pas exactement à celui de l'image utilisée,
sans conséquence grave : l'entrypoint officiel de l'image tourne en root au tout
premier démarrage et corrige lui-même la propriété du répertoire de données.

**Traefik ne route pas** — vérifier que le réseau `frontend` existe
(`docker network ls`) et que `postiz` y est bien attaché
(`docker inspect $(docker compose ps -q postiz)`).

**Certificat non émis** — le DNS doit pointer sur le serveur *avant* le premier
démarrage, sinon le certresolver échoue et retente avec un délai.

**Un post supprimé part quand même** — signe que la recherche de workflow par
`postId` ne fonctionne pas en visibilité SQL (retrait d'Elasticsearch, voir plus
haut) : vérifier d'abord que l'étape de pré-création des attributs en type `Keyword`
a bien été faite avant le premier démarrage de `postiz` — c'est le risque assumé
documenté dans le design.

**Compte admin créé mais jamais activé** — `EMAIL_PROVIDER` a été rempli avant que le
SMTP soit vérifié fonctionnel. Voir la section email de `env_example`.

## Ce qui n'a pas été activé (hors périmètre)

- **Cloudflare R2** : stockage local (bind mount) suffit pour l'instant.
- **OAuth générique / Keycloak** : reporté, voir plus haut.
- **Multi-instance sur le même serveur** : une seule instance Postiz est prévue ici
  (pas de `COMPOSE_PROJECT_NAME` dérivé pour cohabiter avec une deuxième instance).
