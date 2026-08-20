#!/usr/bin/env bash
# A deploy key opens only the repository it belongs to, and ssh stops offering
# keys once one authenticates, so two of them in one agent cannot both work.
# adcnet-rs is cloned here with its own key and patched in by path, leaving
# anymone as the only fetch cargo makes over ssh.
set -euo pipefail

: "${ADCNET_DEPLOY_KEY:?}"

mkdir -p ~/.ssh
chmod 700 ~/.ssh
printf '%s\n' "$ADCNET_DEPLOY_KEY" >~/.ssh/adcnet
chmod 600 ~/.ssh/adcnet
ssh-keyscan github.com >>~/.ssh/known_hosts 2>/dev/null

# Whatever Cargo.lock resolved, so the clone cannot drift from anymone's pin.
rev=$(grep -om1 'adcnet-rs?rev=[0-9a-f]\{40\}' Cargo.lock | cut -d= -f2)
GIT_SSH_COMMAND="ssh -i ~/.ssh/adcnet -o IdentitiesOnly=yes" \
  git clone --quiet ssh://git@github.com/flashbots/adcnet-rs ../adcnet-rs
git -C ../adcnet-rs checkout --quiet "$rev"

# Absolute: a relative path in a config-file patch resolves against the config
# file, not the workspace.
mkdir -p .cargo
cat >>.cargo/config.toml <<EOF

[patch."ssh://git@github.com/flashbots/adcnet-rs"]
adcnet = { path = "$(cd ../adcnet-rs && pwd)" }
EOF
