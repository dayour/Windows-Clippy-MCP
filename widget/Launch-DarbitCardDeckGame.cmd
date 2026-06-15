@echo off
setlocal
title Darbit Card Deck Game
REM Reads the Darbit agent card deck (cd), completes a card deck game run (cdg),
REM then writes evidence, review notes, and a grade.
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0darbit-card-deck-game.ps1" %*
