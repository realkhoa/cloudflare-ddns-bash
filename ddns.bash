#!/usr/bin/env bash

CONFIG_FILE_PATH="./config.conf"
LAST_IP_FILE="./last_ip.txt"
LOG_FILE="./ddns.log"

# ===== Logging =====
log() {
    local msg="$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $msg" | tee -a "$LOG_FILE"
}

notify_discord() {
    local message="$1"

    if [[ "$DISCORD_NOTIFY" == "true" && -n "$DISCORD_WEBHOOK" ]]; then
        curl -s -H "Content-Type: application/json" \
            -X POST -d "{\"content\": \"$message\"}" "$DISCORD_WEBHOOK" >/dev/null 2>&1
    fi
}

# ===== Helper Function =====
create_cloudflare_config() {
    CONFIG_FILE="config.conf"

    echo "⚙️ Let's set up your Cloudflare DDNS config."
    echo "You will be asked for:"
    echo " - API Token"
    echo " - Zone ID"
    echo " - DNS Record Name (e.g., sub.example.com)"
    echo " - Proxied (true/false)"
    echo

    while true; do
        read -rp "Enter Cloudflare API Token: " API_TOKEN
        if validate_token "$API_TOKEN"; then
            break
        else
            echo "Please try again."
        fi
    done

    while true; do
        read -rp "Enter Cloudflare Zone ID: " ZONE_ID
        if validate_zone "$API_TOKEN" "$ZONE_ID"; then
            break
        else
            echo "Please try again."
        fi
    done

    read -rp "Enter DNS Record Name (e.g. sub.example.com): " DNS_RECORD_NAME
    choose_proxied

    cat > "$CONFIG_FILE" <<EOF
API_TOKEN="$API_TOKEN"
ZONE_ID="$ZONE_ID"
DNS_RECORD_NAME="$DNS_RECORD_NAME"
PROXIED=$PROXIED
DISCORD_NOTIFY=false
DISCORD_WEBHOOK=123
EOF

    log "✅ Config saved to $CONFIG_FILE"
}

validate_token() {
    local token=$1
    local response
    response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/user/tokens/verify" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json")

    if echo "$response" | grep -q '"status":"active"'; then
        log "✅ Cloudflare API token is valid."
        return 0
    else
        log "❌ Invalid Cloudflare API token! Response: $response"
        return 1
    fi
}

validate_zone() {
    local token=$1
    local zone=$2
    local response
    response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$zone" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json")

    if echo "$response" | grep -q '"success":true'; then
        local name
        name=$(echo "$response" | sed -n 's/.*"name":"\([^"]*\)".*/\1/p')
        log "✅ Zone ID is valid. Domain: $name"
        return 0
    else
        log "❌ Invalid Zone ID! Response: $response"
        return 1
    fi
}

choose_proxied() {
    local options=("true" "false")
    local selected=0
    local key

    while true; do
        clear
        echo "Proxy through Cloudflare? Use ↑ ↓ arrows and Enter to select:"
        for i in "${!options[@]}"; do
            if [[ $i -eq $selected ]]; then
                echo -e " > \e[7m${options[i]}\e[0m"
            else
                echo "   ${options[i]}"
            fi
        done

        IFS= read -rsn1 key
        if [[ $key == $'\x1b' ]]; then
            read -rsn2 key
            case $key in
                "[A") ((selected--)) ;; # Up
                "[B") ((selected++)) ;; # Down
            esac
            ((selected < 0)) && selected=$((${#options[@]} - 1))
            ((selected >= ${#options[@]})) && selected=0
        elif [[ $key == "" ]]; then
            PROXIED=${options[$selected]}
            break
        fi
    done

    log "✅ Selected proxied: $PROXIED"
}

check_curl() {
    if ! command -v curl >/dev/null 2>&1; then
        log "❌ curl is not installed. Please install it first."
        exit 1
    fi
}

get_public_ip() {
    local ip
    ip=$(curl -s https://api.ipify.org)
    if [[ -n "$ip" ]]; then
        echo "$ip"
    else
        log "❌ Failed to get public IP"
        notify_discord "❌ Failed to get public IP"
        return 1
    fi
}

get_dns_record_id() {
    local response
    response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?name=$DNS_RECORD_NAME" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json")

    echo "$response" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | head -n1
}

get_dns_record() {
    local response
    response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?name=$DNS_RECORD_NAME" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json")

    RECORD_ID=$(echo "$response" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | head -n1)
    RECORD_IP=$(echo "$response" | sed -n 's/.*"content":"\([^"]*\)".*/\1/p' | head -n1)

    if [[ -z "$RECORD_ID" || -z "$RECORD_IP" ]]; then
        log "❌ Failed to fetch DNS record info. Response: $response"
        notify_discord "❌ Failed to fetch DNS record for $DNS_RECORD_NAME"
        return 1
    fi

    echo "$RECORD_ID|$RECORD_IP"
}

update_dns_record() {
    local record_id=$1
    local ip=$2

    local response
    response=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$record_id" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"A\",\"name\":\"$DNS_RECORD_NAME\",\"content\":\"$ip\",\"ttl\":120,\"proxied\":$PROXIED}")

    if echo "$response" | grep -q '"success":true'; then
        log "✅ DNS record updated: $DNS_RECORD_NAME → $ip"
        echo "$ip" > "$LAST_IP_FILE"
        notify_discord "✅ DNS updated: $DNS_RECORD_NAME → $ip"
    else
        log "❌ Failed to update DNS record. Response: $response"
        notify_discord "❌ Failed to update DNS record for $DNS_RECORD_NAME"
        return 1
    fi
}

main() {
    check_curl

    if [ ! -f "$CONFIG_FILE_PATH" ]; then
        log "❌ Config file not found: $CONFIG_FILE_PATH"
        log "Attempting to create one..."
        create_cloudflare_config
    fi

    source "$CONFIG_FILE_PATH"

    CURRENT_IP=$(get_public_ip) || exit 1
    log "🌍 Current public IP: $CURRENT_IP"

    record_info=$(get_dns_record) || exit 1
    RECORD_ID=$(echo "$record_info" | cut -d'|' -f1)
    RECORD_IP=$(echo "$record_info" | cut -d'|' -f2)

    log "🔎 Cloudflare record $DNS_RECORD_NAME currently points to: $RECORD_IP"

    if [[ "$CURRENT_IP" == "$RECORD_IP" ]]; then
        log "ℹ️ IP unchanged ($CURRENT_IP). Skipping update."
        exit 0
    fi

    update_dns_record "$RECORD_ID" "$CURRENT_IP"
}

main
