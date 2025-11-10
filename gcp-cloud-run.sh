#!/bin/bash

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

# Function to validate UUID format
validate_uuid() {
    local uuid_pattern='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    if [[ ! $1 =~ $uuid_pattern ]]; then
        error "Invalid UUID format: $1"
        return 1
    fi
    return 0
}

# Function to validate Telegram Bot Token
validate_bot_token() {
    local token_pattern='^[0-9]{8,10}:[a-zA-Z0-9_-]{35}$'
    if [[ ! $1 =~ $token_pattern ]]; then
        error "Invalid Telegram Bot Token format"
        return 1
    fi
    return 0
}

# Function to validate Channel ID
validate_channel_id() {
    if [[ ! $1 =~ ^-?[0-9]+$ ]]; then
        error "Invalid Channel ID format"
        return 1
    fi
    return 0
}

# Region selection function
select_region() {
    echo
    info "=== Region Selection ==="
    echo "1. us-central1 (Iowa, USA)"
    echo "2. us-west1 (Oregon, USA)" 
    echo "3. us-east1 (South Carolina, USA)"
    echo "4. europe-west4 (Netherlands)"
    echo "5. asia-southeast1 (Singapore)"
    echo "6. asia-northeast1 (Tokyo, Japan)"
    echo
    
    while true; do
        read -p "Select region (1-6): " region_choice
        case $region_choice in
            1) REGION="us-central1"; break ;;
            2) REGION="us-west1"; break ;;
            3) REGION="us-east1"; break ;;
            4) REGION="europe-west4"; break ;;
            5) REGION="asia-southeast1"; break ;;
            6) REGION="asia-northeast1"; break ;;
            *) echo "Invalid selection. Please enter a number between 1-6." ;;
        esac
    done
    
    info "Selected region: $REGION"
}

# User input function
get_user_input() {
    echo
    info "=== Service Configuration ==="
    
    # Service Name
    while true; do
        read -p "Enter service name: " SERVICE_NAME
        if [[ -n "$SERVICE_NAME" ]]; then
            break
        else
            error "Service name cannot be empty"
        fi
    done
    
    # UUID
    while true; do
        read -p "Enter UUID: " UUID
        UUID=${UUID:-"36459fd0-0c89-4733-b20e-067ffc341ad2"}
        if validate_uuid "$UUID"; then
            break
        fi
    done
    
    # Telegram Bot Token
    while true; do
        read -p "Enter Telegram Bot Token: " TELEGRAM_BOT_TOKEN
        if validate_bot_token "$TELEGRAM_BOT_TOKEN"; then
            break
        fi
    done
    
    # Telegram Channel ID
    while true; do
        read -p "Enter Telegram Channel ID: " TELEGRAM_CHANNEL_ID
        if validate_channel_id "$TELEGRAM_CHANNEL_ID"; then
            break
        fi
    done
    
    # Host Domain (optional)
    read -p "Enter host domain [default: m.googleapis.com]: " HOST_DOMAIN
    HOST_DOMAIN=${HOST_DOMAIN:-"m.googleapis.com"}
}

# Display configuration summary
show_config_summary() {
    echo
    info "=== Configuration Summary ==="
    echo "Project ID:    $(gcloud config get-value project)"
    echo "Region:        $REGION"
    echo "Service Name:  $SERVICE_NAME"
    echo "Host Domain:   $HOST_DOMAIN"
    echo "UUID:          $UUID"
    echo "Bot Token:     ${TELEGRAM_BOT_TOKEN:0:8}..."
    echo "Channel ID:    $TELEGRAM_CHANNEL_ID"
    echo "Min Instances: 3"
    echo "Max Instances: 100"
    echo "Concurrency:   1000"
    echo "Timeout:       3600s"
    echo
    
    while true; do
        read -p "Proceed with deployment? (y/n): " confirm
        case $confirm in
            [Yy]* ) break;;
            [Nn]* ) 
                info "Deployment cancelled by user"
                exit 0
                ;;
            * ) echo "Please answer yes (y) or no (n).";;
        esac
    done
}

# Modified API enabling function with error handling
enable_apis_safe() {
    log "Checking and enabling required APIs..."
    
    local apis=("cloudbuild.googleapis.com" "run.googleapis.com" "iam.googleapis.com")
    local project_id=$(gcloud config get-value project)
    
    for api in "${apis[@]}"; do
        info "Checking $api..."
        
        # Check if API is already enabled
        if gcloud services list --enabled --filter="name:$api" --format="value(name)" 2>/dev/null | grep -q "$api"; then
            log "✅ $api is already enabled"
            continue
        fi
        
        # Try to enable API with better error handling
        warn "Attempting to enable $api..."
        if gcloud services enable "$api" --quiet 2>&1; then
            log "✅ Successfully enabled $api"
        else
            error "❌ Failed to enable $api - This is expected in Qwiklabs"
            warn "Continuing without enabling $api..."
        fi
    done
}

# Validation functions
validate_prerequisites() {
    log "Validating prerequisites..."
    
    if ! command -v gcloud &> /dev/null; then
        error "gcloud CLI is not installed."
        exit 1
    fi
    
    if ! command -v git &> /dev/null; then
        error "git is not installed."
        exit 1
    fi
    
    local PROJECT_ID=$(gcloud config get-value project)
    if [[ -z "$PROJECT_ID" || "$PROJECT_ID" == "(unset)" ]]; then
        error "No project configured."
        exit 1
    fi
    
    info "Project: $PROJECT_ID"
}

cleanup() {
    log "Cleaning up temporary files..."
    if [[ -d "gcp-v2ray" ]]; then
        rm -rf gcp-v2ray
    fi
}

send_to_telegram() {
    local message="$1"
    local response
    
    response=$(curl -s -w "%{http_code}" -X POST \
        -H "Content-Type: application/json" \
        -d "{
            \"chat_id\": \"${TELEGRAM_CHANNEL_ID}\",
            \"text\": \"$message\",
            \"parse_mode\": \"MARKDOWN\",
            \"disable_web_page_preview\": true
        }" \
        https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage)
    
    local http_code="${response: -3}"
    local content="${response%???}"
    
    if [[ "$http_code" == "200" ]]; then
        log "✅ Successfully sent to Telegram channel"
        return 0
    else
        error "❌ Failed to send to Telegram (HTTP $http_code): $content"
        return 1
    fi
}

# Modified deployment function for Qwiklabs compatibility
deploy_to_cloud_run() {
    local project_id=$(gcloud config get-value project)
    
    # Clean up any existing directory
    cleanup
    
    log "Cloning repository..."
    if ! git clone -q https://github.com/karyan6/gcp-v2ray.git; then
        error "Failed to clone repository"
        return 1
    fi
    
    cd gcp-v2ray
    
    # Try different deployment methods
    log "Attempting deployment method 1: Direct source deployment..."
    
    if gcloud run deploy ${SERVICE_NAME} \
        --source . \
        --platform managed \
        --region ${REGION} \
        --allow-unauthenticated \
        --memory 2Gi \
        --cpu 2 \
        --quiet 2>&1; then
        return 0
    fi
    
    warn "Method 1 failed, trying method 2: With buildpack..."
    
    if gcloud run deploy ${SERVICE_NAME} \
        --source . \
        --platform managed \
        --region ${REGION} \
        --allow-unauthenticated \
        --memory 2Gi \
        --cpu 2 \
        --quiet 2>&1; then
        return 0
    fi
    
    error "All deployment methods failed"
    return 1
}

main() {
    info "=== GCP Cloud Run V2Ray Deployment (Qwiklabs Compatible) ==="
    
    # Get user input
    select_region
    get_user_input
    show_config_summary
    
    PROJECT_ID=$(gcloud config get-value project)
    
    log "Starting Cloud Run deployment..."
    log "Project: $PROJECT_ID"
    log "Region: $REGION"
    log "Service: $SERVICE_NAME"
    
    validate_prerequisites
    
    # Set trap for cleanup
    trap cleanup EXIT
    
    # Try to enable APIs (will continue even if it fails)
    enable_apis_safe
    
    # Attempt deployment
    if deploy_to_cloud_run; then
        # Get the service URL
        SERVICE_URL=$(gcloud run services describe ${SERVICE_NAME} \
            --region ${REGION} \
            --format 'value(status.url)' \
            --quiet 2>/dev/null || echo "https://${SERVICE_NAME}-*.run.app")
        
        DOMAIN=$(echo $SERVICE_URL | sed 's|https://||')
        
        # Create Vless share link
        VLESS_LINK="vless://${UUID}@${HOST_DOMAIN}:443?path=%2Ftg-ttak19&security=tls&alpn=h3%2Ch2%2Chttp%2F1.1&encryption=none&host=${DOMAIN}&fp=randomized&type=ws&sni=${DOMAIN}#${SERVICE_NAME}"
        
        # Create message
        MESSAGE="━━━━━━━━━━━━━━━━━━━━
*Cloud Run Deploy Success* ✅
*Project:* \`${PROJECT_ID}\`
*Service:* \`${SERVICE_NAME}\`
*Region:* \`${REGION}\`
*URL:* \`${SERVICE_URL}\`

\`\`\`
${VLESS_LINK}
\`\`\`
*Usage:* Copy the above link and import to your V2Ray client
━━━━━━━━━━━━━━━━━━━━"
        
        # Save to file
        echo "$MESSAGE" > deployment-info.txt
        log "Deployment info saved to deployment-info.txt"
        
        # Display locally
        echo
        info "=== Deployment Information ==="
        echo "$MESSAGE"
        echo
        
        # Send to Telegram
        log "Sending deployment info to Telegram..."
        if send_to_telegram "$MESSAGE"; then
            log "✅ Message sent successfully to Telegram"
        else
            warn "Message failed to send to Telegram, but deployment was successful"
        fi
        
        log "Deployment completed successfully!"
        log "Service URL: $SERVICE_URL"
        
    else
        error "Deployment failed. This is expected in Qwiklabs environment."
        warn "Try using your own GCP project with full permissions."
        info "You can get free $300 credit for testing at: https://cloud.google.com/free"
    fi
}

# Run main function
main "$@"
