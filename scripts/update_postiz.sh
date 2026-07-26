#!/bin/bash
set -euo pipefail

##### INSTRUCTION
#
# Mise a jour de la stack Postiz, avec sauvegarde prealable.
#
#   sauvegarde borg -> docker compose pull -> up -d -> attente du healthcheck
#
# IMPORTANT : l'image postiz est EPINGLEE (POSTIZ_VERSION dans .env), PAS
# "latest". "docker compose pull" ne ramenera RIEN de nouveau tant que
# POSTIZ_VERSION n'a pas ete change a la main dans .env AVANT de lancer ce
# script. Releases : https://github.com/gitroomhq/postiz-app/releases
#
# ATTENTION : Postiz execute `prisma db push --accept-data-loss` a CHAQUE
# demarrage (pas seulement au premier boot d'une version neuve). En cas
# d'echec, ne JAMAIS se contenter de redescendre POSTIZ_VERSION vers l'ancien
# tag : la base a deja potentiellement migre vers le schema de la nouvelle
# version, et un Postiz plus ancien peut soit refuser de demarrer dessus, soit
# la re-migrer a l'envers de facon destructive. La procedure sure est de
# restaurer la base depuis la sauvegarde (voir README, section Restauration),
# pas de rejouer un tag anterieur sur la base telle quelle.
#
# Usage :
#   ./update_postiz.sh              # backup puis mise a jour
#   ./update_postiz.sh --no-backup  # mise a jour seule (a eviter)
#
# Prerequis : backup_postiz.sh configure (voir son en-tete).
#####

## Surveillance optionnelle via Sentry :
# export SENTRY_DSN=''
# eval "$(sentry-cli bash-hook)"

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
POSTIZ_DIR="${POSTIZ_DIR:-$(dirname "$SCRIPT_DIR")}"
COMPOSE_FILE="$POSTIZ_DIR/docker-compose.yml"
ENV_FILE="${ENV_FILE:-$POSTIZ_DIR/.env}"

# Duree max d'attente du retour au vert de postiz, en secondes. Genereux car
# le healthcheck lui-meme (docker-compose.yml) a un budget de 90s de
# start_period + 10 x 30s de retries = 390s avant de pouvoir dire "unhealthy" ;
# en dessous de ca, ce script conclurait a tort a un echec sur une mise a
# jour qui est simplement encore en train de demarrer (migrations Prisma,
# premier boot pm2).
HEALTH_TIMEOUT=600

[ -f "$COMPOSE_FILE" ] || { echo "[postiz-update] compose introuvable : $COMPOSE_FILE" >&2; exit 1; }
[ -f "$ENV_FILE" ] || { echo "[postiz-update] .env introuvable : $ENV_FILE" >&2; exit 1; }

compose() { docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" "$@"; }

VERSION_CONFIGUREE="$(sed -n "s/^[[:space:]]*POSTIZ_VERSION[[:space:]]*=[[:space:]]*//p" "$ENV_FILE" | tail -n1)"
echo "[postiz-update] version configuree dans .env : ${VERSION_CONFIGUREE:-non definie}"

# Image reellement en cours d'execution AVANT la mise a jour (peut differer
# de VERSION_CONFIGUREE si .env a ete edite sans encore relancer la stack).
CONTENEUR_AVANT="$(docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" ps -q postiz 2>/dev/null || true)"
if [ -n "$CONTENEUR_AVANT" ]; then
  IMAGE_AVANT="$(docker inspect --format '{{.Config.Image}}' "$CONTENEUR_AVANT" 2>/dev/null || echo 'inconnue')"
  echo "[postiz-update] image actuellement en cours d'execution : $IMAGE_AVANT"
fi

#### 1. SAUVEGARDE ####
if [ "${1:-}" = "--no-backup" ]; then
  echo "[postiz-update] sauvegarde IGNOREE (--no-backup)"
else
  echo "[postiz-update] sauvegarde avant mise a jour..."
  bash "$SCRIPT_DIR/backup_postiz.sh"
fi

#### 2. MISE A JOUR ####
echo "[postiz-update] recuperation de l'image ${VERSION_CONFIGUREE:-actuelle}..."
compose pull postiz

echo "[postiz-update] redemarrage de la stack..."
compose up -d

#### 3. VERIFICATION ####
echo "[postiz-update] attente du healthcheck postiz (max ${HEALTH_TIMEOUT}s)..."
# On resout l'ID du conteneur via compose : son nom depend du
# COMPOSE_PROJECT_NAME de cette instance.
CONTENEUR="$(compose ps -q postiz)"
[ -n "$CONTENEUR" ] || { echo "[postiz-update] conteneur postiz introuvable" >&2; exit 1; }

ATTENTE=0
ETAT="inconnu"
while [ "$ATTENTE" -lt "$HEALTH_TIMEOUT" ]; do
  ETAT="$(docker inspect --format '{{.State.Health.Status}}' "$CONTENEUR" 2>/dev/null || echo 'absent')"
  case "$ETAT" in
    healthy)
      IMAGE_APRES="$(docker inspect --format '{{.Config.Image}}' "$CONTENEUR" 2>/dev/null || echo 'inconnue')"
      echo "[postiz-update] OK — postiz est en bonne sante."
      echo "[postiz-update] ${IMAGE_AVANT:-?} -> $IMAGE_APRES"
      exit 0
      ;;
    unhealthy)
      break
      ;;
  esac
  sleep 5
  ATTENTE=$((ATTENTE + 5))
done

echo "[postiz-update] ECHEC : postiz n'est pas revenu en bonne sante (etat : $ETAT)." >&2
echo "[postiz-update] Derniers logs :" >&2
compose logs --tail 50 postiz >&2 || true
echo "[postiz-update] Sauvegarde disponible dans borgwarehouse. Voir README (Restauration)." >&2
exit 1
