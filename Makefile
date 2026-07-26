.PHONY: help up down reload restart logs ps init backup check update

DC := docker compose

help:
	@echo "Stack Postiz — cibles disponibles :"
	@echo ""
	@echo "  make up        demarre la stack"
	@echo "  make down      arrete la stack (les donnees restent dans ./data et les volumes)"
	@echo "  make reload    down + up : A UTILISER apres toute modification du .env"
	@echo "  make restart   redemarre les conteneurs SANS relire le .env (rarement ce qu'on veut)"
	@echo "  make logs      suit les logs de postiz"
	@echo "  make ps        etat des conteneurs (healthy ?)"
	@echo ""
	@echo "  make init      configure la sauvegarde borg (cle SSH, depot BWH, cron)"
	@echo "  make backup    lance une sauvegarde maintenant"
	@echo "  make check     verifie que la derniere sauvegarde est restaurable"
	@echo ""
	@echo "  make update    sauvegarde, puis met Postiz a jour (bump POSTIZ_VERSION dans .env avant)"

up:
	$(DC) up -d

down:
	$(DC) --profile debug down

# Toujours passer par down+up et non par un simple `up -d` apres avoir touche au
# .env : recreer le conteneur postiz pendant que Postgres/Redis/Temporal tournent
# deja declenche un blocage au demarrage de l'orchestrator (voir README,
# "Demarrage de l'orchestrator"). down sans -v ne perd aucune donnee.
reload:
	$(DC) --profile debug down
	$(DC) up -d

restart:
	$(DC) restart

logs:
	$(DC) logs -f postiz

ps:
	$(DC) ps

init:
	@bash scripts/init_backup.sh

backup:
	@bash scripts/backup_postiz.sh

check:
	@bash scripts/check_backup.sh

update:
	@bash scripts/update_postiz.sh
