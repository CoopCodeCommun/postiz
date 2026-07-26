#!/bin/bash
set -euo pipefail

##### INSTRUCTION
#
# Verifie que la derniere sauvegarde Postiz est REELLEMENT restaurable, sans
# rien restaurer. Trois questions, dans l'ordre :
#   1. Une archive recente existe-t-elle ? (sinon : le cron est mort)
#   2. Contient-elle le dump, ./data/uploads, ./data/config, docker-compose.yml
#      et le .env ?
#   3. Le dump pg_dump est-il exploitable et COMPLET (schema Postiz present,
#      pas juste une base vide) ?
#
# Le point 3 est verifie DANS le conteneur postiz-postgres (pg_restore -l puis
# pg_restore -f /dev/null, en streaming depuis `borg extract --stdout`), pas
# avec un outil de l'hote : le dump est produit par Postgres 17 (dans le
# conteneur), un pg_restore d'hote plus ancien pourrait le refuser et fausser
# ce test.
#
# Sort en code non nul si quoi que ce soit cloche : utilisable tel quel dans
# un monitoring.
#####

## Surveillance optionnelle via Sentry :
# export SENTRY_DSN=''
# eval "$(sentry-cli bash-hook)"

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
POSTIZ_DIR="${POSTIZ_DIR:-$(dirname "$SCRIPT_DIR")}"
COMPOSE_FILE="$POSTIZ_DIR/docker-compose.yml"
ENV_FILE="${ENV_FILE:-$POSTIZ_DIR/.env}"

# Age maximum tolere pour la derniere archive. 25 h = la sauvegarde
# quotidienne d'hier, plus une heure de marge. C'est aussi le reglage de
# l'alerte BWH (pose par make init). Valeur reprise plus bas, apres lecture
# du .env (voir AGE_MAX_HEURES) : un override d'environnement explicite est
# prioritaire sur le .env, lui-meme prioritaire sur ce defaut de 25.

ok()      { echo "  [ok]   $*"; }
ko()      { echo "  [KO]   $*" >&2; ERREURS=$((ERREURS + 1)); }
erreur()  { echo "[check] ERREUR : $*" >&2; exit 2; }
ERREURS=0

[ -f "$ENV_FILE" ] || erreur ".env introuvable : $ENV_FILE"

# On n'ouvre PAS tout le .env comme du bash (`. "$ENV_FILE"`) : une valeur non
# quotee avec un espace y serait executee comme une commande. On n'extrait que
# les variables dont ce script a besoin, via sed -- meme principe que
# valeur_env() dans init_backup.sh.
valeur_env() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$ENV_FILE" | tail -n1 | tr -d "'\""; }
BORG_PREFIX="${BORG_PREFIX:-$(valeur_env BORG_PREFIX)}"
BORG_REPO="${BORG_REPO:-$(valeur_env BORG_REPO)}"
BORG_PASSPHRASE="${BORG_PASSPHRASE:-$(valeur_env BORG_PASSPHRASE)}"
AGE_MAX_HEURES="${AGE_MAX_HEURES:-$(valeur_env AGE_MAX_HEURES)}"
AGE_MAX_HEURES="${AGE_MAX_HEURES:-25}"
# L'export est INDISPENSABLE : borg lit BORG_PASSPHRASE dans son ENVIRONNEMENT,
# pas dans le shell. Sans lui, borg reclame la passphrase au clavier -- donc
# `make check` bloque en interactif et echoue depuis un monitoring.
export BORG_REPO BORG_PASSPHRASE

: "${BORG_PREFIX:?BORG_PREFIX absent du .env — la sauvegarde n'est pas configuree (make init)}"
: "${BORG_REPO:?BORG_REPO absent du .env — la sauvegarde n'est pas configuree (make init)}"
: "${BORG_PASSPHRASE:?BORG_PASSPHRASE absent du .env}"
command -v borg >/dev/null || erreur "borg introuvable dans le PATH."

SSH_KEY="${SSH_KEY:-$SCRIPT_DIR/.ssh/${BORG_PREFIX}_ed25519}"
[ -f "$SSH_KEY" ] && export BORG_RSH="/usr/bin/ssh -oStrictHostKeyChecking=accept-new -oIdentitiesOnly=yes -i $SSH_KEY"

echo "[check] depot : $BORG_REPO"
echo


#### 1. UNE ARCHIVE RECENTE EXISTE-T-ELLE ? ####
echo "1. Fraicheur"

# --glob-archives : on ne regarde QUE les archives de cette stack.
DERNIERE="$(borg list --glob-archives "$BORG_PREFIX-*" --last 1 \
  --format '{archive}{TAB}{time:%Y-%m-%d %H:%M:%S}{NL}' "$BORG_REPO")"
[ -n "$DERNIERE" ] || erreur "aucune archive '$BORG_PREFIX-*' dans le depot. La sauvegarde n'a jamais tourne."

ARCHIVE="${DERNIERE%%	*}"
DATE_ARCHIVE="${DERNIERE#*	}"

AGE_SECONDES=$(( $(date +%s) - $(date -d "$DATE_ARCHIVE" +%s) ))
AGE_HEURES=$(( AGE_SECONDES / 3600 ))

if [ "$AGE_HEURES" -le "$AGE_MAX_HEURES" ]; then
  ok "derniere archive : $ARCHIVE (il y a ${AGE_HEURES} h)"
else
  ko "derniere archive : $ARCHIVE — ${AGE_HEURES} h, soit plus de ${AGE_MAX_HEURES} h."
  ko "le cron ne tourne plus. Verifie : crontab -l"
fi


#### 2. L'ARCHIVE CONTIENT-ELLE CE QU'IL FAUT ? ####
echo
echo "2. Contenu de l'archive"

CONTENU="$(borg list --format '{path}{NL}' "$BORG_REPO::$ARCHIVE")"

CHEMIN_DUMP="$(printf '%s\n' "$CONTENU" | grep -E '/pg-dump-[^/]+/postiz\.dump$' | head -n1 || true)"
if [ -n "$CHEMIN_DUMP" ]; then
  ok "dump Postgres present : ${CHEMIN_DUMP##*/}"
else
  ko "aucun dump Postgres dans l'archive."
fi

if grep -qE '/data/uploads(/|$)' <<< "$CONTENU"; then
  ok "uploads presents (./data/uploads)"
else
  ko "./data/uploads absent de l'archive."
fi

if grep -qE '/data/config(/|$)' <<< "$CONTENU"; then
  ok "config presente (./data/config)"
else
  ko "./data/config absent de l'archive."
fi

if grep -qE '/docker-compose\.yml$' <<< "$CONTENU"; then
  ok "docker-compose.yml present"
else
  ko "docker-compose.yml absent de l'archive."
fi

if grep -qE '/\.env$' <<< "$CONTENU"; then
  ok ".env present (la stack est remontable telle quelle)"
else
  ko ".env absent : une restauration demanderait de resaisir les secrets."
fi


#### 3. LE DUMP EST-IL EXPLOITABLE, ET COMPLET ? ####
echo
echo "3. Le dump est-il restaurable ?"

if [ -z "$CHEMIN_DUMP" ]; then
  ko "pas de dump a verifier."
elif [ ! -f "$COMPOSE_FILE" ] || [ -z "$(docker compose -f "$COMPOSE_FILE" ps -q postiz-postgres 2>/dev/null)" ]; then
  ko "conteneur postiz-postgres introuvable/arrete — impossible de verifier avec pg_restore (memes outils que la prod). Demarrer la stack (make up) puis relancer make check."
else
  # Schema attendu : on liste la table des matieres du dump (rien n'est
  # restaure) et on y cherche les tables Post et User. Sans ce test, un
  # pg_dump d'une base VIDE (mauvais chemin de bind mount, base reinitialisee
  # par erreur) est un fichier valide de quelques ko qui passerait quand meme
  # le seul test "pg_restore -f /dev/null reussit" plus bas.
  TOC="$(borg extract --stdout "$BORG_REPO::$ARCHIVE" "$CHEMIN_DUMP" \
      | docker compose -f "$COMPOSE_FILE" exec -T postiz-postgres pg_restore -l || true)"

  if grep -qE 'TABLE public Post[[:space:]]' <<< "$TOC" \
     && grep -qE 'TABLE public User[[:space:]]' <<< "$TOC"; then
    ok "schema Postiz retrouve (tables Post et User)"
  else
    ko "le dump ne contient pas le schema Postiz attendu (base vide ou dump invalide)."
  fi

  # On lit tout le flux en streaming, rien n'est ecrit sur le disque. Verifie
  # DANS le conteneur (memes outils/version que ceux qui ont produit le
  # dump), pas sur l'hote qui pourrait avoir une version pg_restore differente.
  if borg extract --stdout "$BORG_REPO::$ARCHIVE" "$CHEMIN_DUMP" \
      | docker compose -f "$COMPOSE_FILE" exec -T postiz-postgres pg_restore -f /dev/null; then
    ok "dump restaurable (pg_restore -f /dev/null, dans le conteneur, en streaming)"
  else
    ko "pg_restore a signale une erreur sur ce dump — restauration douteuse."
  fi
fi


#### VERDICT ####
echo
if [ "$ERREURS" -eq 0 ]; then
  echo "[check] La derniere sauvegarde est restaurable."
  exit 0
fi
echo "[check] $ERREURS probleme(s). Cette sauvegarde n'est pas fiable." >&2
exit 1
