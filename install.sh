#!/bin/bash
# install.sh - FINALE VERSIE (MET UPLOAD LIMIET FIX)

set -e

# --- Installatie & Config (blijft hetzelfde) ---
echo "--- Server wordt voorbereid... ---"
apt-get update -y > /dev/null
apt-get install -y curl wget git nginx jq rsync > /dev/null
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash > /dev/null
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
nvm install 20 > /dev/null
nvm use 20 > /dev/null
npm install -g pm2 > /dev/null
read -p "Geef een naam voor je applicatie (bv. mijn-app): " APP_NAME
read -p "Welke domeinnaam ga je gebruiken (bv. jouwdomein.com): " DOMAIN
read -p "Voer een e-mailadres in voor SSL-notificaties: " EMAIL
read -p "Welke gebruikersnaam wil je voor deployments (default: root): " DEPLOY_USER
DEPLOY_USER=${DEPLOY_USER:-root}
APP_BASE_DIR="/var/www/${APP_NAME}"
if [ "$DEPLOY_USER" != "root" ] && ! id "$DEPLOY_USER" &>/dev/null; then useradd -m -s /bin/bash $DEPLOY_USER; fi
mkdir -p "${APP_BASE_DIR}/source" && mkdir -p "${APP_BASE_DIR}/persistent"
chown -R $DEPLOY_USER:$DEPLOY_USER $APP_BASE_DIR
echo "✅ Server voorbereiding voltooid."

# --- Genereer lokaal commando ---
SERVER_IP=$(curl -s ifconfig.me)
APP_SOURCE_PATH="${APP_BASE_DIR}/source"
CONFIG_JSON=$(jq -n --arg name "$APP_NAME" --arg user "$DEPLOY_USER" --arg host "$SERVER_IP" --arg domain "$DOMAIN" --arg path "$APP_BASE_DIR" --arg email "$EMAIL" \
'{servers: [{name: "production", user: $user, host: $host, domain: $domain, path: $path}], email: $email}')

ECOSYSTEM_JS_CONTENT=$(echo "module.exports = {apps:[{name:\"$APP_NAME\",script:\"$APP_SOURCE_PATH/.output/server/index.mjs\",cwd:\"$APP_SOURCE_PATH\",exec_mode:\"cluster\",instances:\"max\"}]};" | base64 -w 0)

DEPLOY_SH_RAW=$(cat << 'EOL'
#!/bin/bash
set -e
SERVER_NAME="production"
if [ ! -f deploy.config.json ]; then echo "Fout: deploy.config.json niet gevonden."; exit 1; fi
USER=$(jq -r ".servers[] | select(.name==\"$SERVER_NAME\") | .user" deploy.config.json)
HOST=$(jq -r ".servers[] | select(.name==\"$SERVER_NAME\") | .host" deploy.config.json)
DOMAIN=$(jq -r ".servers[] | select(.name==\"$SERVER_NAME\") | .domain" deploy.config.json)
APP_PATH=$(jq -r ".servers[] | select(.name==\"$SERVER_NAME\") | .path" deploy.config.json)
EMAIL=$(jq -r ".email" deploy.config.json)
SSH_ALIAS="$USER@$HOST"
echo "🚀 Deploying to '$SERVER_NAME'..."
rsync -avz --delete \
  --include="package-lock.json" --include=".env.deploy" \
  --exclude="node_modules" --exclude=".git" --exclude=".uploads" --exclude="pruvious.db" \
  . "$SSH_ALIAS:$APP_PATH/source/"
ssh $SSH_ALIAS << END_SSH
  set -e
  export NVM_DIR="\$HOME/.nvm"
  [ -s "\$NVM_DIR/nvm.sh" ] && \. "\$NVM_DIR/nvm.sh"
  
  cd "$APP_PATH/source"
  if [ -f .env.deploy ]; then mv -f .env.deploy .env; fi
  npm ci
  npm run build
  
  mkdir -p "$APP_PATH/persistent/.uploads" && touch "$APP_PATH/persistent/pruvious.db"
  ln -sfn "$APP_PATH/persistent/.uploads" "$APP_PATH/source/.uploads"
