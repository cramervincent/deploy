#!/bin/bash
# install.sh - FINALE VERSIE MET BEPROEFDE NUXT 3 NGINX CONFIG

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
  --include="package-lock.json" \
  --exclude="node_modules" \
  --exclude=".git" \
  --exclude=".uploads" \
  --exclude="pruvious.db" \
  . "$SSH_ALIAS:$APP_PATH/source/"
ssh $SSH_ALIAS << END_SSH
  set -e
  export NVM_DIR="\$HOME/.nvm"
  [ -s "\$NVM_DIR/nvm.sh" ] && \. "\$NVM_DIR/nvm.sh"
  
  cd "$APP_PATH/source"
  npm ci
  npm run build
  
  mkdir -p "$APP_PATH/persistent/.uploads"
  touch "$APP_PATH/persistent/pruvious.db"
  ln -sfn "$APP_PATH/persistent/.uploads" "$APP_PATH/source/.uploads"
  ln -sfn "$APP_PATH/persistent/pruvious.db" "$APP_PATH/source/pruvious.db"
  
  pm2 startOrRestart ecosystem.config.cjs --env production
  
  NGINX_CONF_PATH="/etc/nginx/sites-available/$DOMAIN"
  
  if [ ! -f /etc/letsencrypt/live/$DOMAIN/fullchain.pem ]; then
    echo "🔍 First deployment: Setting up Nginx & SSL for $DOMAIN..."
    sudo tee \$NGINX_CONF_PATH > /dev/null <<'END_NGINX_TEMP'
server {
    listen 80;
    server_name $DOMAIN www.$DOMAIN;
    location / {
        proxy_pass http://localhost:3000;
        proxy_set_header Host \$host;
    }
}
END_NGINX_TEMP
    sudo ln -sfn \$NGINX_CONF_PATH /etc/nginx/sites-enabled/
    sudo nginx -t && sudo systemctl reload nginx
    sudo certbot --nginx -d $DOMAIN -d www.$DOMAIN --non-interactive --agree-tos -m $EMAIL --redirect
  fi
  
  # --- HIER IS DE DEFINITIEVE NGINX CONFIGURATIE ---
  echo "⚙️  Updating Nginx configuration for Nuxt..."
  APP_PUBLIC_PATH="$APP_PATH/source/.output/public"
  
  sudo tee \$NGINX_CONF_PATH > /dev/null <<'END_NGINX_FINAL'
server {
    listen 80;
    server_name \$DOMAIN www.\$DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name \$DOMAIN www.\$DOMAIN;

    ssl_certificate /etc/letsencrypt/live/\$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/\$DOMAIN/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    # De proxy naar je Nuxt-app
    location / {
        proxy_pass http://localhost:3000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
END_NGINX_FINAL
  
  sudo sed -i "s/\\\$DOMAIN/$DOMAIN/g" \$NGINX_CONF_PATH
  sudo nginx -t && sudo systemctl reload nginx
  
END_SSH
echo "✅ Deployment to '$SERVER_NAME' was successful!"
EOL
)
DEPLOY_SH_CONTENT=$(echo "$DEPLOY_SH_RAW" | base64 -w 0)
FINAL_COMMAND=$(cat << EOL
echo "🚀 Lokale bestanden worden aangemaakt..."
echo '$CONFIG_JSON' | jq '.' > deploy.config.json
echo '$ECOSYSTEM_JS_CONTENT' | base64 --decode > ecosystem.config.cjs
echo '$DEPLOY_SH_CONTENT' | base64 --decode > deploy.sh
chmod +x deploy.sh
if [ -f package.json ]; then
  jq '.scripts.deploy = "./deploy.sh"' package.json > package.json.tmp && mv package.json.tmp package.json
fi
echo "🎉 Lokale setup is voltooid!"
EOL
)

echo "✅ Server setup is compleet!"
echo "========================================================================================"
echo "ACTION REQUIRED: Kopieer en voer het onderstaande commando lokaal uit:"
echo "========================================================================================"
echo
echo -e "\033[1;32mbash -c \"\$(echo '$(echo "$FINAL_COMMAND" | base64 -w 0)' | base64 --decode)\"\033[0m"
echo
echo "========================================================================================"
