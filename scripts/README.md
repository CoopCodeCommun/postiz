# Scripts de sauvegarde de la stack Postiz

| Script | Cible Makefile | Rôle |
|---|---|---|
| [`init_backup.sh`](./init_backup.sh) | `make init` | Configure la sauvegarde : clé SSH dédiée, dépôt borgwarehouse, `.env`, cron |
| [`backup_postiz.sh`](./backup_postiz.sh) | `make backup` | Dump PostgreSQL + tout le dossier de la stack → borgwarehouse |
| [`check_backup.sh`](./check_backup.sh) | `make check` | Vérifie que la dernière sauvegarde est **restaurable** |
| [`update_postiz.sh`](./update_postiz.sh) | `make update` | Sauvegarde → `pull` → `up -d` → attente du healthcheck |

**Aucun script ne contient de secret.** Tous lisent le `.env` de la stack, que git
ignore. Modèle repris de [`ghost/scripts`](https://github.com/CoopCodeCommun/ghost)
(même mainteneur), adapté à PostgreSQL au lieu de MySQL — la bibliothèque générique
[borgwarehouse](https://github.com/CoopCodeCommun/borgwarehouse) ne couvre pas le cas
"dockerisé avec dump via `docker compose exec`", d'où ces scripts dédiés.

## Ce que contient une archive

Le dump PostgreSQL est déposé dans `scripts/pg-dump-<prefix>/`, puis **tout le
dossier de la stack** part dans une seule archive : le dump, `./data/uploads`,
`./data/config`, le `.env` et le `docker-compose.yml`. Une archive suffit à remonter
la stack de zéro, et tout y est cohérent au même instant.

Quatre exclusions :

| Exclusion | Pourquoi |
|---|---|
| `data/postgres/` | Fichiers PostgreSQL à chaud. Les copier donnerait une base corrompue — le dump `pg_dump` est la seule forme fiable. |
| `scripts/.ssh/` | La clé privée du dépôt : on ne met pas la clé du coffre dans le coffre. |
| `.git/` | Contrôle de version, pas l'état runtime. |
| `github/` | Clone amont du code source Postiz, en lecture seule et re-clonable — pas la peine de l'archiver. |

Le mot de passe PostgreSQL n'apparaît nulle part dans le script : il est lu **dans**
le conteneur `postiz-postgres` au moment du `pg_dump` (variables d'environnement déjà
définies par le `docker-compose.yml`). Le `.env` est en revanche archivé — sans
conséquence, puisqu'il faut déjà la passphrase borg pour ouvrir l'archive qui la
contient.

**Hors périmètre, délibérément** : la base PostgreSQL interne de Temporal
(régénérable, protégée par le filet de rattrapage `RUN_CRON` qui rescanne les posts
en retard de moins de 48h) et Redis (cache/queues, rien d'irremplaçable). Justification
complète dans `docs/superpowers/specs/2026-07-26-postiz-selfhost-design.md` — non
versionné (voir `.gitignore`), donc ce lien n'existe que sur la machine où le design a
été écrit.

## Deux protections discrètes

**Un verrou** (`flock`) sur `backup_postiz.sh` : sans lui, un lancement manuel
tombant pendant le cron partagerait le même dossier de dump temporaire — le premier
à finir le supprime pendant que l'autre archive encore, et on obtient une archive
**sans dump**, silencieusement.

**Le `prune` ne touche que les archives de cette stack** (`--glob-archives
"$PREFIX-*"`). Si un jour un autre projet partageait le même dépôt, sans ce filtre
les deux se rogneraient mutuellement leur rétention.

## Rétention

7 jours glissants, 30 quotidiennes, 12 hebdomadaires, puis **toutes** les mensuelles
et annuelles (`--keep-within=7d --keep-daily=30 --keep-weekly=12 --keep-monthly=-1
--keep-yearly=-1`) — la politique déjà en place sur les autres dépôts borgwarehouse
du mainteneur.

## Mise en place : `make init`

```bash
command -v borg || sudo apt install borgbackup
cp env_example .env   # si pas deja fait
make init
```

Enchaîne : génération de la clé SSH dédiée, création du dépôt via l'API BWH (token
`create` seul suffit), tirage d'une passphrase, `borg init`, export de la clé, pose
du cron, première sauvegarde et vérification. **Rejouable** sauf si le dépôt contient
déjà des archives (regénérer une passphrase les rendrait illisibles).

À la fin, `init_backup.sh` affiche la passphrase, la clé exportée (`borg key
export`) et l'adresse du dépôt : **à mettre dans un coffre-fort numérique tout de
suite**. C'est le seul maillon que la sauvegarde ne peut pas se sauvegarder
elle-même.

## Vérifier : `make check`

```bash
make check
```

Répond à la seule question qui compte — *est-ce restaurable ?* — sans rien
restaurer :

1. **Fraîcheur** : la dernière archive de cette stack date de moins de 25h (réglage
   `AGE_MAX_HEURES`, posé par `make init`).
2. **Contenu** : le dump, `./data/uploads`, `./data/config`, `docker-compose.yml` et
   le `.env` sont bien dans l'archive.
3. **Exploitabilité et schéma** : le dump est d'abord listé (`pg_restore -l`, rien
   n'est restauré) pour vérifier que les tables `Post` et `User` y sont bien —
   sans ça, un dump d'une base **vide** (mauvais chemin de bind mount, base
   réinitialisée par erreur) passerait quand même l'étape suivante. Puis il est
   extrait en streaming et déroulé entièrement dans `pg_restore -f /dev/null`,
   **dans le conteneur** `postiz-postgres` (mêmes outils/version que ceux qui l'ont
   produit — évite un faux négatif si l'hôte a une version de `pg_restore`
   différente). Un dump tronqué (disque plein, process tué en plein vol) a une
   taille crédible, se trouve bien dans l'archive, et échoue précisément à cette
   étape.

Sort en code non nul si quoi que ce soit cloche : utilisable tel quel dans un
monitoring.

**Ce que `make check` ne teste pas** : ta copie de coffre-fort. Il utilise le `.env`
de la machine, pas la passphrase archivée ailleurs — or c'est celle-là qui servira le
jour où la machine aura brûlé. Vérifie une fois, depuis une autre machine, qu'un
`borg list` passe avec les éléments du coffre.

## Restaurer

```bash
mkdir -p /tmp/postiz-restore && cd /tmp/postiz-restore
borg list "$BORG_REPO"                          # lister les archives
borg extract --list "$BORG_REPO::<archive>"
# borg restitue l'arborescence ABSOLUE d'origine sous le dossier courant, ex :
#   home/jonas/Gits/postiz/...   <- le dossier complet, .env compris
cd home/*/*/postiz   # ou le chemin exact affiche par --list ; a deplacer ensuite ou l'on veut

mkdir -p ./data/postgres && sudo chown 999:999 ./data/postgres
# data/postgres N'EST PAS dans l'archive (exclu volontairement, voir plus haut) :
# on repart d'un dossier vide, la base sera recreee puis reinjectee via le dump.

docker compose up -d postiz-postgres
docker compose exec -T postiz-postgres \
  sh -c 'exec pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean --if-exists' \
  < scripts/pg-dump-<prefix>/postiz.dump

docker compose up -d
```

La **clé SSH du dépôt** (`scripts/.ssh/`) n'est pas dans l'archive : en cas de perte
totale, en générer une nouvelle et l'ajouter au dépôt depuis l'interface
borgwarehouse.

## Surveillance

Deux filets, complémentaires :

- **`make check`** dit si la dernière sauvegarde est restaurable.
- **borgwarehouse** envoie un mail si le dépôt ne reçoit plus rien (alerte réglée par
  `make init`). C'est le seul mécanisme qui prévient qu'une sauvegarde **n'est pas
  arrivée** — un cron qui échoue en silence, c'est un backup qui n'existe pas.

Chaque script contient par ailleurs un hook **Sentry** commenté en tête, pour être
alerté si le script lui-même échoue.
