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
# 1. Temporal seul (Postiz ne doit PAS encore demarrer)
docker compose up -d temporal-postgresql temporal

# 2. Attendre "Search attributes have been added" dans les logs (~20 s)
docker compose logs temporal | grep "Search attributes have been added"

# 3. Creer les deux attributs en type Keyword
#    --entrypoint temporal est INDISPENSABLE : l'entrypoint de l'image
#    admin-tools est "tini -- sleep infinity", qui avale silencieusement la
#    commande passee et reste bloque indefiniment.
#    -T aussi : le service declare tty: true, incompatible avec un pipe.
DBG="docker compose --profile debug run --rm -T --entrypoint temporal temporal-admin-tools"
$DBG operator search-attribute create --address temporal:7233 --namespace default --name postId --type Keyword
$DBG operator search-attribute create --address temporal:7233 --namespace default --name organizationId --type Keyword

# 4. Verifier : les deux doivent apparaitre en "Keyword"
$DBG operator search-attribute list --address temporal:7233 --namespace default | grep -E "postId|organizationId"
```

Si cette étape est sautée, Postiz créera lui-même ces attributs au premier
démarrage mais en type `Text`, moins adapté à la recherche par égalité exacte dont
il se sert pour annuler un post supprimé. Un attribut ne peut plus changer de type
après création, d'où l'ordre imposé ici. À l'inverse, si les attributs existent
déjà, Postiz les laisse tels quels (vérifié en préprod : ils sont restés `Keyword`
après le démarrage complet).

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

### Démarrage de l'orchestrator — à lire une fois

**Le passage au vert de `postiz` prend une à deux minutes, c'est normal.** À chaque
démarrage, l'orchestrator fait compiler par webpack un bundle de 3 Mo par file de
tâches de réseau social (~34), séquentiellement, **avant** d'ouvrir le port que
sonde le healthcheck. Le `start_period` du healthcheck est réglé large en
conséquence ; l'interface web, elle, répond bien avant ça.

Pour suivre l'avancement : `docker compose exec postiz tail -f /root/.pm2/logs/orchestrator-error.log`
(webpack y logue chaque bundle, avec le nom de la file de tâches). La ligne
`Orchestrator health check listening on port 3002` dans `orchestrator-out.log`
marque la fin.

**⚠️ Ne jamais faire `docker compose up -d` (ni `make up`) pour appliquer un
changement de `.env` sur une stack qui tourne — utiliser `make reload`.**
Recréer le conteneur `postiz` pendant que Postgres/Redis/Temporal tournent déjà
déclenche un blocage au démarrage de l'orchestrator : deadlock sur futex au
chargement de ses modules natifs. Reproduit 2 fois sur 2 en préprod avec `up`
seul, 0 fois sur 2 avec `down` puis `up`. C'est un bug de Postiz, pas de cette
configuration ; `make reload` évite simplement la course en laissant `postiz`
attendre les healthchecks de ses dépendances.

**Comment reconnaître ce blocage** (utile car il est totalement silencieux) :

| Signe | Valeur en cas de blocage |
|---|---|
| `make ps` | `postiz` reste `starting` puis passe `unhealthy`, indéfiniment |
| `docker compose exec postiz ss -tln \| grep 3002` | rien (le port ne s'ouvre jamais) |
| `docker compose exec postiz pm2 list` | `orchestrator` pourtant **`online`**, 0 redémarrage, 0 % CPU |
| `orchestrator-out.log` | s'arrête après la bannière npm, **aucune ligne NestJS** |
| `orchestrator-error.log` | aucun bundle webpack compilé |

Un `pm2 restart orchestrator` **ne suffit pas toujours** à s'en sortir (testé :
échec). La parade fiable est `make reload`. Conséquence importante : un
orchestrator bloqué signifie qu'**aucun post programmé ne partira**, alors que
l'interface web reste parfaitement fonctionnelle — d'où l'intérêt de surveiller
l'état `healthy` du conteneur et pas seulement la disponibilité du site.

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

**Empreinte mémoire mesurée** (préprod, v2.22.1, stack au repos), avec et sans
`EXCLUDE_QUEUE` (voir plus bas) :

| Conteneur | Sans `EXCLUDE_QUEUE` | Avec (1 seul réseau) |
|---|---|---|
| `postiz` (backend + frontend + orchestrator sous pm2) | 2,41 Gio | **1,25 Gio** |
| `temporal` | 189 Mio | 79 Mio |
| `temporal-postgresql` | 76 Mio | 86 Mio |
| `postiz-postgres` | 46 Mio | 31 Mio |
| `postiz-redis` | 3 Mio | 3 Mio |
| **total stack** | **~2,7 Gio** | **~1,45 Gio** |

Détail par processus dans le conteneur `postiz`, sans `EXCLUDE_QUEUE` : orchestrator
**1 585 Mo**, backend 535 Mo, frontend 228 Mo, plus ~500 Mo d'enveloppes `pnpm` qui ne
font qu'attendre (l'image lance `pnpm start` au lieu de `node` directement). Avec
`EXCLUDE_QUEUE`, l'orchestrator tombe à **497 Mo**.

Compter donc **2 Go de RAM libre minimum** avec `EXCLUDE_QUEUE` bien réglé, **4 Go**
sans, et davantage si tu utilises la génération d'images/vidéo. Le conteneur `postiz`
étant le plus gros consommateur de la machine, c'est lui que l'OOM-killer du noyau
désignera en cas de saturation — ou l'inverse, sa croissance peut faire tomber un autre
service de l'hôte. **Aucune limite `mem_limit`/`cpus` n'est posée** : à ajouter si
plusieurs services lourds cohabitent sur le serveur, pour cantonner le dégât à la stack.

### `EXCLUDE_QUEUE` — le principal levier d'empreinte

Non documenté en amont, trouvé dans le code (`temporal.module.ts`). Par défaut
l'orchestrator démarre **un worker Temporal par réseau social supporté (~33)**, qu'il
soit connecté ou non — chacun avec son bac à sable de workflow et son bundle webpack de
3 Mo, compilés séquentiellement au démarrage. Exclure les files inutilisées divise
l'empreinte par deux et le temps de démarrage aussi (90 s → 40 s, 33 bundles → 2).

⚠️ **Panne silencieuse** : si un canal est connecté plus tard alors que sa file est
exclue, l'interface acceptera de programmer des posts mais aucun worker ne les
traitera — **ils ne partiront jamais, sans message d'erreur**. Mettre la liste à jour à
chaque nouveau canal, et ne **jamais** exclure `main` (workflows généraux : rattrapage
`RUN_CRON`, emails). Voir `env_example` pour la liste des files et un exemple.

Vérifier ce qui tourne réellement après un démarrage :

```bash
docker compose exec postiz sh -c "grep -oE \"taskQueue: .[a-z]+\" /root/.pm2/logs/orchestrator-error.log | sort -u"
```
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

## CLI Postiz et skill Claude Code

Le [CLI officiel](https://github.com/gitroomhq/postiz-agent) (paquet npm `postiz`)
pilote l'instance par l'API publique `/public/v1`. Il couvre plus de choses que le
serveur MCP intégré : lister et supprimer des posts existants, changer leur statut,
lire les analytics, téléverser un fichier local — toutes opérations absentes du MCP.
En revanche il ne fait **aucune génération d'image ou de vidéo** ; ces fonctions-là
dépendent de `OPENAI_API_KEY`, non renseignée sur cette instance, et échouent en 500
aussi bien via le MCP que via l'interface web.

### Mise en route

```bash
cp env_postiz_cli_example .env.postiz-cli && chmod 600 .env.postiz-cli
nano .env.postiz-cli          # POSTIZ_API_KEY (Settings > Public API) et POSTIZ_API_URL
./scripts/postiz integrations:list
```

Si la dernière commande renvoie du JSON, tout est en place. Un 401 signale une clé
invalide ; du HTML au lieu du JSON signale un `POSTIZ_API_URL` sans le suffixe `/api`.

`analytics:platform` renvoie toujours `[]` sur cette instance, et ce n'est pas une
erreur de configuration : seuls dix providers implémentent la méthode `analytics()`
côté Postiz (Facebook, Instagram, Threads, X, LinkedIn Page, YouTube, TikTok,
Pinterest, GMB), et Mastodon n'en fait pas partie — `mastodon.provider.ts` ne
définit pas cette méthode. Rien ne remontera tant qu'un canal analytique ne sera pas
connecté.

### Pourquoi un wrapper plutôt que `npm install -g postiz`

`./scripts/postiz` appelle le CLI via `npx` à une version épinglée et charge
`.env.postiz-cli`. Rien n'est installé globalement : ce dépôt n'a pas de
`package.json`, et un `npm install` local y déposerait `package.json`,
`package-lock.json` et `node_modules/` sans rapport avec une stack docker-compose.
L'épinglage suit la même logique que `POSTIZ_VERSION` pour l'image Docker.

**Ne jamais lancer `postiz auth:login`.** Cette commande s'authentifie contre le
cloud Postiz (`cli-auth.postiz.com`, `api.postiz.com`), pas contre cette instance, et
écrit `~/.postiz/credentials.json`. Or le CLI lit ce fichier **en priorité** sur
`POSTIZ_API_KEY` et `POSTIZ_API_URL` (`src/config.ts` du dépôt `postiz-agent`) : une
fois créé, toutes les commandes partiraient silencieusement vers le cloud. Le wrapper
avertit si le fichier est présent, mais ne le supprime pas de lui-même.

### Skill Claude Code

`.claude/skills/postiz/SKILL.md` est le skill officiel, **adapté à ce dépôt** et
versionné à cet endroit (le `.gitignore` exclut `.claude/` sauf `skills/`). Trois
écarts par rapport à l'amont sont documentés en tête du fichier : passage par
`./scripts/postiz`, interdiction des commandes `auth:*`, indisponibilité des
fonctions IA. Le reste du fichier est le texte amont intact, ce qui permet de
rejouer la comparaison lors d'une mise à jour :

```bash
curl -s https://raw.githubusercontent.com/gitroomhq/postiz-agent/main/SKILL.md \
  | diff - .claude/skills/postiz/SKILL.md
```

L'installation passe volontairement par ce fichier plutôt que par
`npx skills add gitroomhq/postiz-agent` : le skill n'est qu'un Markdown, le copier
à la main le garde confiné au dépôt, versionné et lisible avant exécution.

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

**Les emails ne partent pas, sans aucune erreur** — vérifier d'abord dans les logs
quel provider a réellement été sélectionné :

```bash
docker compose logs postiz | grep -E "Email service provider|Missing environment variable"
```

Doit afficher `Email service provider: nodemailer`. Si c'est `empty`, `EMAIL_PROVIDER`
ne vaut pas exactement `nodemailer` ou `resend` — **toute autre valeur (y compris
`mailgun`, `smtp`, `gmail`…) retombe silencieusement sur un provider qui n'envoie
rien**. Mailgun/Brevo/OVH sont des *hôtes SMTP* : le provider reste `nodemailer`.
Attention aussi au nom exact des variables : le code lit `EMAIL_PASS`, pas
`EMAIL_PASSWORD`.

**`535 Authentication failed` dans les logs** — les identifiants SMTP sont refusés :

```bash
docker compose logs postiz | grep -iE "EAUTH|535|Email to .* failed"
```

Avant de soupçonner le mot de passe, **vérifier la région Mailgun** : un domaine créé
en région EU ne s'authentifie pas sur le point d'entrée US, et l'erreur est un `535`
indistinguable d'un mauvais mot de passe. `smtp.mailgun.org` = US,
`smtp.eu.mailgun.org` = EU. Pour trancher sans deviner, tester les quatre
combinaisons depuis le conteneur (le mot de passe n'est jamais affiché) :

```bash
docker compose exec -T postiz node -e '
const nm=require("/app/node_modules/nodemailer");
(async()=>{for(const h of ["smtp.mailgun.org","smtp.eu.mailgun.org"])
for(const c of [[465,true],[587,false]]){
 try{await nm.createTransport({host:h,port:c[0],secure:c[1],
  auth:{user:process.env.EMAIL_USER,pass:process.env.EMAIL_PASS},
  connectionTimeout:1e4}).verify();console.log("OK    "+h+":"+c[0]);}
 catch(e){console.log("ECHEC "+h+":"+c[0]+" -> "+(e.responseCode||e.code));}}})();'
```

Les envois passent par un workflow Temporal avec 3 tentatives : un échec laisse donc
trois traces dans les logs, puis `Email to <adresse> failed after 3 attempts`.

**Connecter un compte Mastodon** — le provider Mastodon exige trois variables
d'environnement, contrairement à Bluesky ou Nostr dont les identifiants se saisissent
dans l'interface. Il faut déclarer une application sur **ton** instance
(*Préférences → Développement → Nouvelle application*) avec :

| Champ | Valeur |
|---|---|
| URI de redirection | `https://<POSTIZ_DOMAIN>/integrations/social/mastodon` |
| Permissions | `write:statuses`, `profile`, `write:media` |

puis renseigner `MASTODON_URL` (l'URL de l'instance, ex. `https://piaille.fr`),
`MASTODON_CLIENT_ID`, `MASTODON_CLIENT_SECRET` et faire `make reload`.
`MASTODON_URL` étant une variable globale, **une instance Postiz ne peut se
connecter qu'à une seule instance Mastodon**. Le provider « M. Instance »
(`mastodon-custom`), qui déclarerait l'application tout seul et permettrait
plusieurs instances, existe dans le code mais est **désactivé en v2.22.1**
(`integration.manager.ts` : `// new MastodonCustomProvider()`).

## Ce qui n'a pas été activé (hors périmètre)

- **Cloudflare R2** : stockage local (bind mount) suffit pour l'instant.
- **OAuth générique / Keycloak** : reporté, voir plus haut.
- **Multi-instance sur le même serveur** : une seule instance Postiz est prévue ici
  (pas de `COMPOSE_PROJECT_NAME` dérivé pour cohabiter avec une deuxième instance).
