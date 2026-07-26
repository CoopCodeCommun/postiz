.PHONY: help up down restart logs ps init backup check update

DC := docker compose

help:
	@echo "Stack Postiz — cibles disponibles :"
	@echo ""
	@echo "  make up        demarre la stack"
	@echo "  make down      arrete la stack (les donnees restent dans ./data)"
	@echo "  make restart   redemarre la stack"
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
