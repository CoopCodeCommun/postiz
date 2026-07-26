#!/bin/bash
set -euo pipefail

##### INSTRUCTION
#
# Sauvegarde de la stack Postiz vers un depot borgwarehouse (BWH).
#
# Principe : pg_dump coherent (format custom) depose dans scripts/, puis TOUT
# le dossier de la stack part dans UNE archive borg (dump + ./data/uploads +
# ./data/config + .env + docker-compose.yml). Une archive suffit a remonter
# la stack de zero, coherente au meme instant.
#
# Exclusions :
#   data/postgres/  fichiers Postgres a chaud — les copier donnerait une base
#                   corrompue, le dump pg_dump est la seule forme fiable
#   scripts/.ssh/   la cle privee du depot : on ne l'archive pas dans le
#                   depot qu'elle protege
#   .git/           controle de version, pas l'etat runtime
#   github/         clone amont en lecture seule, re-clonable
#
# HORS PERIMETRE (deliberement) : la base Postgres interne de Temporal
# (regenerable, filet de rattrapage RUN_CRON) et Redis (cache/queues). Voir
# docs/superpowers/specs/2026-07-26-postiz-selfhost-design.md
#
# CONFIGURATION : ce script ne contient AUCUN secret. Il lit BORG_PREFIX,
# BORG_REPO et BORG_PASSPHRASE dans le .env de la stack (le seul fichier que
# git ignore). Un script est fait pour etre copie/verse/partage : y ecrire une
# passphrase, c'est la pousser au premier `git add -A` distrait.
#
# 1- Ce script vit dans scripts/, a cote du docker-compose.yml de la stack.
# 2- Choisir un BORG_PREFIX, generer une cle SSH DEDIEE a ce depot :
#      mkdir -p ./.ssh && chmod 700 ./.ssh
#      ssh-keygen -t ed25519 -N '' -f ./.ssh/postiz_ed25519   # nom = $BORG_PREFIX
# 3- Creer un depot dans borgwarehouse, y coller ./.ssh/postiz_ed25519.pub
# 4- Renseigner le bloc SAUVEGARDE du .env (voir env_example), ou lancer
#    scripts/init_backup.sh qui automatise tout ca.
# 5- Initier le depot :   ./backup_postiz.sh --init
# 6- Sauvegarder :        ./backup_postiz.sh
# 7- Cron (a lancer par un utilisateur membre du groupe docker, ou root,
#    puisque ce script fait `docker compose exec`) :
#      @daily bash /chemin/vers/postiz/scripts/backup_postiz.sh >> $HOME/.postiz-backup-<prefix>.log 2>&1
#    (init_backup.sh pose cette ligne automatiquement, avec le bon chemin de log)
#
# Le mot de passe Postgres n'est PAS recopie ici : il est lu DANS le
# conteneur au moment du pg_dump (variables d'environnement du conteneur
# postiz-postgres, deja definies par le docker-compose.yml).
#####

## Surveillance optionnelle via Sentry :
# export SENTRY_DSN=''
# eval "$(sentry-cli bash-hook)"

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
POSTIZ_DIR="${POSTIZ_DIR:-$(dirname "$SCRIPT_DIR")}"
COMPOSE_FILE="$POSTIZ_DIR/docker-compose.yml"
ENV_FILE="${ENV_FILE:-$POSTIZ_DIR/.env}"

[ -f "$ENV_FILE" ] || { echo "[postiz-borg] .env introuvable : $ENV_FILE" >&2; exit 1; }

# On n'ouvre PAS tout le .env comme du bash (`. "$ENV_FILE"`) : une valeur non
# quotee avec un espace (EMAIL_FROM_NAME=Postiz Team, par exemple) y serait
# executee comme une commande et ferait planter ce script avec un code
# incomprehensible, chaque nuit, en silence. On n'extrait donc que les 4
# variables borg dont ce script a besoin, via sed -- meme principe que
# valeur_env() dans init_backup.sh.
valeur_env() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$ENV_FILE" | tail -n1 | tr -d "'\""; }
BORG_PREFIX="${BORG_PREFIX:-$(valeur_env BORG_PREFIX)}"
BORG_REPO="${BORG_REPO:-$(valeur_env BORG_REPO)}"
BORG_PASSPHRASE="${BORG_PASSPHRASE:-$(valeur_env BORG_PASSPHRASE)}"

PREFIX="${BORG_PREFIX:?BORG_PREFIX doit etre renseigne dans le .env}"
SSH_KEY="${SSH_KEY:-$SCRIPT_DIR/.ssh/${PREFIX}_ed25519}"
DUMP_DIR="${DUMP_DIR:-$SCRIPT_DIR/pg-dump-$PREFIX}"

#### PREPARATION ####
export BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK=yes
export BORG_RELOCATED_REPO_ACCESS_IS_OK=yes

# Un seul backup a la fois. Sans ce verrou, un lancement manuel qui tombe
# pendant le cron partagerait le meme DUMP_DIR : le premier a finir le
# supprime (trap EXIT) pendant que l'autre archive encore, et on obtient une
# archive SANS DUMP, silencieusement.
exec 9>"$SCRIPT_DIR/.backup-$PREFIX.lock"
flock -n 9 || { echo "[postiz-borg] une sauvegarde est deja en cours — abandon." >&2; exit 1; }

: "${BORG_REPO:?BORG_REPO doit etre renseigne dans le .env}"
: "${BORG_PASSPHRASE:?BORG_PASSPHRASE doit etre renseigne dans le .env}"
command -v borg   >/dev/null || { echo "[postiz-borg] borg introuvable dans le PATH" >&2; exit 1; }
command -v docker >/dev/null || { echo "[postiz-borg] docker introuvable dans le PATH" >&2; exit 1; }
command -v flock  >/dev/null || { echo "[postiz-borg] flock introuvable dans le PATH" >&2; exit 1; }
[ -f "$COMPOSE_FILE" ] || { echo "[postiz-borg] compose introuvable : $COMPOSE_FILE" >&2; exit 1; }

DATE_NOW=$(date +%Y-%m-%d-%H-%M)

# Force l'usage de CETTE cle (et pas une autre de l'agent SSH).
if [ -f "$SSH_KEY" ]; then
  chmod 600 "$SSH_KEY" 2>/dev/null || true
  export BORG_RSH="/usr/bin/ssh -oStrictHostKeyChecking=accept-new -oIdentitiesOnly=yes -i $SSH_KEY"
else
  echo "[postiz-borg] [INFO] aucune cle a $SSH_KEY — SSH utilisera la config systeme." >&2
fi

# Mode init : initialise le depot puis sort.
if [ "${1:-}" = "--init" ]; then
  echo "$DATE_NOW initialisation du depot borg ($BORG_REPO) avec repokey-blake2"
  borg init -e repokey-blake2 "$BORG_REPO"
  exit 0
fi

[ -d "$POSTIZ_DIR/data/uploads" ] || { echo "[postiz-borg] dossier uploads introuvable : $POSTIZ_DIR/data/uploads" >&2; exit 1; }

#### DUMP POSTGRES ####
# Nettoyage garanti du dump meme en cas d'erreur.
trap 'rm -rf "$DUMP_DIR"' EXIT
rm -rf "$DUMP_DIR"
mkdir -p "$DUMP_DIR"
DUMP_FILE="$DUMP_DIR/postiz.dump"

echo "$DATE_NOW dump de la base postiz (pg_dump, format custom)"
docker compose -f "$COMPOSE_FILE" exec -T postiz-postgres \
  sh -c 'exec pg_dump -U "$POSTGRES_USER" -Fc "$POSTGRES_DB"' \
  > "$DUMP_FILE"

# Garde-fou : un dump vide = on n'archive pas.
if [ ! -s "$DUMP_FILE" ]; then
  echo "[postiz-borg] dump vide ($DUMP_FILE) — abandon" >&2
  exit 1
fi

#### BORG CREATE ####
# Codes de sortie borg : 0 = succes, 1 = avertissement (fichier modifie ou
# illisible pendant l'archivage -- plausible ici, data/uploads est un dossier
# VIVANT que le conteneur postiz peut ecrire pendant le backup), 2 et plus =
# vraie erreur. Avec `set -e`, un simple avertissement tuerait le script
# AVANT le prune : on capture le code, on tolere 1, on n'echoue que sur >= 2.
# (Modele : borgwarehouse/scripts/backup_postgres_example.sh)
borg_tolerant() {
  local rc=0
  "$@" || rc=$?
  if [ "$rc" -ge 2 ]; then
    echo "[postiz-borg] ERREUR : '$1' a echoue (code $rc)" >&2
    exit "$rc"
  fi
  [ "$rc" -eq 1 ] && echo "[postiz-borg] (avertissement borg ignore, code 1)" >&2
  return 0
}

# On archive TOUT le dossier de la stack : le dump (depose dans scripts/), les
# uploads/config, mais aussi le .env et le docker-compose.yml. Une archive
# contient ainsi tout ce qu'il faut pour remonter la stack de zero.
echo "$DATE_NOW on cree l'archive borg (dossier complet de la stack)"
borg_tolerant borg create -vs --compression lz4 \
  --exclude "$POSTIZ_DIR/data/postgres" \
  --exclude "$POSTIZ_DIR/scripts/.ssh" \
  --exclude "$POSTIZ_DIR/.git" \
  --exclude "$POSTIZ_DIR/github" \
  "$BORG_REPO::$PREFIX-$DATE_NOW" \
  "$POSTIZ_DIR"

echo "$DATE_NOW on prune les vieux borg :"
# --glob-archives : le prune ne touche QUE les archives de cette stack.
borg_tolerant borg prune -v --list \
  --glob-archives "$PREFIX-*" \
  --keep-within=7d --keep-daily=30 --keep-weekly=12 --keep-monthly=-1 --keep-yearly=-1 \
  "$BORG_REPO"

echo "$DATE_NOW termine"
