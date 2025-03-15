#!/bin/bash

# Function to print verbose messages
verbose() {
    echo "[INFO] $1"
}

# Function to print errors
error() {
    echo "[ERROR] $1" >&2
    exit 1
}

# Function to urlencode strings
urlencode() {
    local string="$1"
    [ -z "$string" ] && error "Empty string provided for URL encoding"
    
    # Use Python for reliable URL encoding if available
    if command -v python3 >/dev/null 2>&1; then
        echo -n "$string" | python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.stdin.read(), safe=""))'
        return
    fi
    
    # Fallback to perl if python is not available
    if command -v perl >/dev/null 2>&1; then
        echo -n "$string" | perl -MURI::Escape -ne 'print uri_escape($_)'
        return
    fi
    
    # If neither Python nor Perl is available, use a basic bash implementation
    local length="${#string}"
    for (( i = 0; i < length; i++ )); do
        local c="${string:i:1}"
        case $c in
            [a-zA-Z0-9.~_-]) printf "%s" "$c" ;;
            *) printf "%%%02X" "'$c" ;;
        esac
    done
    echo
}

# Function to check if XML response indicates success
check_response() {
    local xml="$1"
    if [ -z "$xml" ]; then
        error "No response received from server"
    fi
    
    local status=$(echo "$xml" | xmllint --xpath '//meta/status/text()' - 2>/dev/null)
    if [ $? -ne 0 ] || [ -z "$status" ]; then
        error "Invalid response from server or unable to parse XML"
    fi
    
    if [ "$status" != "ok" ]; then
        local message=$(echo "$xml" | xmllint --xpath '//meta/message/text()' - 2>/dev/null)
        error "API request failed: ${message:-Unknown error}"
    fi
}

# Function to show usage information
show_usage() {
    cat << EOF
Usage: $(basename "$0") [--do] <nextcloud_url> <username> <password> <group> <csv_file>

Create Nextcloud users from a CSV file.

Arguments:
    nextcloud_url     URL of the Nextcloud instance
    username         Admin username for Nextcloud
    password         Admin password for Nextcloud
    group           Group to assign new users to
    csv_file        Path to CSV file containing user data

Options:
    --do            Actually create the users (without this flag, runs in dry-run mode)
    -h, --help     Show this help message

The CSV file must contain the following columns:
    - FIRST NAME
    - LAST NAME
    - EMAIL ADDRESS

Configuration can also be provided in nextcloud_config.conf with the following variables:
    NC_URL          Nextcloud URL
    NC_USER         Admin username
    NC_PASS         Admin password
    NC_GROUP        Default group

Example:
    $(basename "$0") nextcloud.example.com admin password "Default Group" users.csv --do
EOF
    exit 1
}

# Default values
DO_CREATE=false
CONFIG_FILE="nextcloud_config.conf"

# Show usage if no arguments provided or help requested
case "$1" in
    ""|"-h"|"--help")
        show_usage
        ;;
esac

# Load configuration file if it exists
if [ -f "$CONFIG_FILE" ]; then
    verbose "Loading configuration from $CONFIG_FILE"
    source "$CONFIG_FILE"
fi

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --do)
            DO_CREATE=true
            shift
            ;;
        -h|--help)
            show_usage
            ;;
        *)
            if [ -z "$NC_URL" ]; then
                NC_URL="$1"
            elif [ -z "$NC_USER" ]; then
                NC_USER="$1"
            elif [ -z "$NC_PASS" ]; then
                NC_PASS="$1"
            elif [ -z "$NC_GROUP" ]; then
                NC_GROUP="$1"
            elif [ -z "$CSV_FILE" ]; then
                CSV_FILE="$1"
            fi
            shift
            ;;
    esac
done

# Validate required parameters and format
[ -z "$NC_URL" ] && error "Nextcloud URL is required"
[ -z "$NC_USER" ] && error "Nextcloud username is required"
[ -z "$NC_PASS" ] && error "Nextcloud password is required"
[ -z "$NC_GROUP" ] && error "Nextcloud group is required"
[ -z "$CSV_FILE" ] && error "CSV file path is required"
[ ! -f "$CSV_FILE" ] && error "CSV file does not exist: $CSV_FILE"

# Validate and show configuration before connecting
verbose "Using configuration:"
verbose "  URL: $NC_URL"
verbose "  User: $NC_USER"
verbose "  Group: $NC_GROUP"
verbose "  CSV File: $CSV_FILE"

# Remove any trailing slashes from URL and ensure it doesn't start with https://
NC_URL="${NC_URL%/}"
NC_URL="${NC_URL#https://}"
NC_URL="${NC_URL#http://}"

[ -z "$NC_URL" ] && error "URL is empty after formatting"
verbose "  Formatted URL: https://$NC_URL"

# Encode credentials for URL
verbose "Encoding credentials..."
ENCODED_USER=$(urlencode "$NC_USER") || error "Failed to encode username"
ENCODED_PASS=$(urlencode "$NC_PASS") || error "Failed to encode password"

# Test connection and get existing users
verbose "Testing connection and retrieving user list..."
FULL_URL="https://${ENCODED_USER}:${ENCODED_PASS}@${NC_URL}/ocs/v1.php/cloud/users"
verbose "  Connecting to: ${FULL_URL//${ENCODED_PASS}/****}"

USERS_XML=$(curl -s -X GET "$FULL_URL" \
    -H "OCS-APIRequest: true" --fail)

if [ $? -ne 0 ]; then
    error "Failed to connect to Nextcloud server. Please check URL and credentials."
fi

# Check if the connection was successful
check_response "$USERS_XML"

# Get all existing users and their emails
declare -A EXISTING_EMAILS
verbose "Retrieving email addresses for existing users..."
while IFS= read -r userid; do
    verbose "  Checking user: $userid"
    encoded_userid=$(urlencode "$userid")
    user_info=$(curl -s -X GET "https://${ENCODED_USER}:${ENCODED_PASS}@${NC_URL}/ocs/v1.php/cloud/users/${encoded_userid}" \
        -H "OCS-APIRequest: true")
    email=$(echo "$user_info" | xmllint --xpath '//email/text()' - 2>/dev/null)
    if [ ! -z "$email" ]; then
        verbose "    Found email: $email"
        EXISTING_EMAILS[$email]=1
    else
        verbose "    No email found"
    fi
done < <(echo "$USERS_XML" | xmllint --xpath '//element/text()' - 2>/dev/null)

verbose "Found ${#EXISTING_EMAILS[@]} unique email addresses"

# Process CSV file
verbose "Processing CSV file..."

# Read header line and create field mapping
IFS=',' read -r -a headers < <(head -n 1 "$CSV_FILE")
declare -A field_positions
for i in "${!headers[@]}"; do
    # Remove quotes and convert spaces to underscores
    clean_header=$(echo "${headers[$i]}" | tr -d '"' | tr ' ' '_')
    field_positions[$clean_header]=$i
done

# Check required fields
required_fields=("FIRST_NAME" "LAST_NAME" "EMAIL_ADDRESS")
for field in "${required_fields[@]}"; do
    [ -z "${field_positions[$field]}" ] && error "Required field $field not found in CSV"
done

# Process data lines
while IFS=',' read -r -a fields; do
    [ "${#fields[@]}" -eq 0 ] && continue  # Skip empty lines
    
    email="${fields[${field_positions[EMAIL_ADDRESS]}]}"
    first_name="${fields[${field_positions[FIRST_NAME]}]}"
    last_name="${fields[${field_positions[LAST_NAME]}]}"
    
    # Skip if email is empty
    if [ -z "$email" ]; then
        verbose "Skipping user with empty email: $first_name $last_name"
        continue
    fi
    
    # Skip if email already exists
    if [ -n "${EXISTING_EMAILS[$email]}" ]; then
        verbose "Skipping user with existing email: $email"
        continue
    fi
    
    userid="$first_name $last_name"
    encoded_userid=$(urlencode "$userid")
    encoded_email=$(urlencode "$email")
    encoded_group=$(urlencode "$NC_GROUP")
    
    if [ "$DO_CREATE" = true ]; then
        verbose "Creating user: $userid (email: $email)"
        response=$(curl -s -X POST "https://${ENCODED_USER}:${ENCODED_PASS}@${NC_URL}/ocs/v1.php/cloud/users" \
            -d "userid=$encoded_userid" \
            -d "email=$encoded_email" \
            -d "groups[]=$encoded_group" \
            -H "OCS-APIRequest: true")
        
        status=$(echo "$response" | xmllint --xpath '//meta/status/text()' - 2>/dev/null)
        if [ "$status" = "ok" ]; then
            verbose "Successfully created user: $userid (email: $email)"
        else
            message=$(echo "$response" | xmllint --xpath '//meta/message/text()' - 2>/dev/null)
            echo "[WARNING] Failed to create user $userid (email: $email): $message"
        fi
    else
        verbose "Would create user: $userid (email: $email) (dry run)"
    fi
    
done < <(tail -n +2 "$CSV_FILE")

verbose "Processing complete" 