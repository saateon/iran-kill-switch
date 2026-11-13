@echo off
rem Reopens the Claude Code session in which this project was designed and built.
rem Needs the Claude Code CLI (claude) and the original session data on this PC.
rem The session was started in the folder above this repo, so it is resumed from there.
title Iran Kill Switch - Claude Code session
cd /d "%~dp0.."
where claude >nul 2>&1
if %errorlevel% neq 0 (
  echo Claude Code CLI was not found. Install it: npm install -g @anthropic-ai/claude-code
  pause
  exit /b 1
)
claude --resume 1850bb7e-17fa-434f-9846-6f3766ae6408
