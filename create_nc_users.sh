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
Usage: $(basename "$0") [--do] <csv_file>

Create Nextcloud users from a CSV file using configuration from nextcloud_config.conf.

Arguments:
    csv_file        Path to CSV file containing user data

Options:
    --do            Actually create the users (without this flag, runs in dry-run mode)
    -h, --help     Show this help message

The CSV file must contain the following columns:
    - FIRST NAME
    - LAST NAME
    - EMAIL ADDRESS
    - EXTERNAL ID

Configuration must be provided in nextcloud_config.conf with the following variables:
    NC_URL           Nextcloud URL
    NC_USER          Admin username
    NC_PASS          Admin password
    NC_GROUP         Default group
    NC_USERID_SUFFIX Suffix to append to userids

Example:
    $(basename "$0") users.csv          # Dry run
    $(basename "$0") --do users.csv     # Actually create users
EOF
    exit 1
}

# Default values
DO_CREATE=false
CONFIG_FILE="nextcloud_config.conf"
NC_USERID_SUFFIX=""  # Default suffix if not configured

# Show usage if help requested
case "$1" in
    -h|--help)
        show_usage
        ;;
esac

# Load configuration file - it's required now
if [ ! -f "$CONFIG_FILE" ]; then
    error "Configuration file $CONFIG_FILE not found"
fi

verbose "Loading configuration from $CONFIG_FILE"
source "$CONFIG_FILE"

# Parse only --do flag and get CSV path
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
            if [ -z "$CSV_FILE" ]; then
                CSV_FILE="$1"
            else
                error "Unknown argument: $1"
            fi
            shift
            ;;
    esac
done

# Validate required parameters
[ -z "$NC_URL" ] && error "Nextcloud URL is required in config file"
[ -z "$NC_USER" ] && error "Nextcloud username is required in config file"
[ -z "$NC_PASS" ] && error "Nextcloud password is required in config file"
[ -z "$NC_GROUP" ] && error "Nextcloud group is required in config file"
[ -z "$NC_USERID_SUFFIX" ] && error "UserID suffix is required in config file"
[ -z "$CSV_FILE" ] && error "CSV file path is required as argument"
[ ! -f "$CSV_FILE" ] && error "CSV file does not exist: $CSV_FILE"

# Validate and show configuration before connecting
verbose "Using configuration:"
verbose "  URL: $NC_URL"
verbose "  User: $NC_USER"
verbose "  Group: $NC_GROUP"
verbose "  UserID Suffix: $NC_USERID_SUFFIX"
verbose "  CSV File: $CSV_FILE"
verbose "  Create Users: $([ "$DO_CREATE" = true ] && echo "yes" || echo "no (dry run)")"

# Prompt for confirmation
echo
echo "Do you want to continue with these settings? [y/N] "
read -r response
if [[ ! "$response" =~ ^[yY]$ ]]; then
    error "Aborted by user"
fi

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
declare -A EXISTING_USERIDS
verbose "Retrieving email addresses and userids for existing users..."
while IFS= read -r userid; do
    verbose "  Checking user: $userid"
    EXISTING_USERIDS[$userid]=1
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

verbose "Found ${#EXISTING_EMAILS[@]} unique email addresses and ${#EXISTING_USERIDS[@]} existing users"

# Add counter for userid conflicts
skipped_existing_userid=0

# Add counter for external ID conflicts
skipped_existing_external_id=0

# Process CSV file
verbose "Processing CSV file..."

# Statistics counters
declare -A error_reasons
total_processed=0
skipped_no_email=0
skipped_existing_email=0
created_success=0
created_failed=0

# Read header line and create field mapping
IFS=',' read -r -a headers < <(head -n 1 "$CSV_FILE")
declare -A field_positions
for i in "${!headers[@]}"; do
    # Remove quotes and convert spaces to underscores
    clean_header=$(echo "${headers[$i]}" | tr -d '"' | tr ' ' '_')
    field_positions[$clean_header]=$i
done

# Update required fields
required_fields=("FIRST_NAME" "LAST_NAME" "EMAIL_ADDRESS" "EXTERNAL_ID")
for field in "${required_fields[@]}"; do
    [ -z "${field_positions[$field]}" ] && error "Required field $field not found in CSV"
done

# Process data lines
while IFS=',' read -r -a fields; do
    [ "${#fields[@]}" -eq 0 ] && continue  # Skip empty lines
    ((total_processed++))
    
    email="${fields[${field_positions[EMAIL_ADDRESS]}]}"
    first_name="${fields[${field_positions[FIRST_NAME]}]}"
    last_name="${fields[${field_positions[LAST_NAME]}]}"
    external_id="${fields[${field_positions[EXTERNAL_ID]}]}"
    display_name="$first_name $last_name"
    
    # Skip if email is empty
    if [ -z "$email" ]; then
        verbose "Skipping user with empty email: $display_name"
        ((skipped_no_email++))
        continue
    fi
    
    
    # Skip if external ID already exists as userid
    if [ -n "${EXISTING_USERIDS[${external_id}${NC_USERID_SUFFIX}]}" ]; then
        verbose "Skipping user with existing external ID as userid: ${external_id}${NC_USERID_SUFFIX}"
        ((skipped_existing_external_id++))
        continue
    fi

    # Skip if email already exists
    if [ -n "${EXISTING_EMAILS[$email]}" ]; then
        verbose "Skipping user with existing email: $email"
        ((skipped_existing_email++))
        continue
    fi


    # Skip if display name exists as userid
    if [ -n "${EXISTING_USERIDS[$display_name]}" ]; then
        verbose "Skipping user with existing display name as userid: $display_name"
        ((skipped_existing_userid++))
        continue
    fi
    
    # Use external ID as userid with suffix
    userid="${external_id}${NC_USERID_SUFFIX}"
    encoded_userid=$(urlencode "$userid")
    encoded_email=$(urlencode "$email")
    encoded_group=$(urlencode "$NC_GROUP")
    encoded_display_name=$(urlencode "$display_name")
    
    if [ "$DO_CREATE" = true ]; then
        verbose "Creating user: $userid (display name: $display_name, email: $email)"
        response=$(curl -s -X POST "https://${ENCODED_USER}:${ENCODED_PASS}@${NC_URL}/ocs/v1.php/cloud/users" \
            -d "userid=$encoded_userid" \
            -d "email=$encoded_email" \
            -d "groups[]=$encoded_group" \
            -H "OCS-APIRequest: true")
        
        status=$(echo "$response" | xmllint --xpath '//meta/status/text()' - 2>/dev/null)
        if [ "$status" = "ok" ]; then
            verbose "Successfully created user: $userid"
            # Set display name
            verbose "Setting display name for $userid..."
            response=$(curl -s -X PUT "https://${ENCODED_USER}:${ENCODED_PASS}@${NC_URL}/ocs/v1.php/cloud/users/${encoded_userid}" \
                -d "key=displayname" \
                -d "value=$encoded_display_name" \
                -H "OCS-APIRequest: true")
            
            status=$(echo "$response" | xmllint --xpath '//meta/status/text()' - 2>/dev/null)
            if [ "$status" = "ok" ]; then
                verbose "Successfully set display name to: $display_name"
                ((created_success++))
            else
                message=$(echo "$response" | xmllint --xpath '//meta/message/text()' - 2>/dev/null)
                echo "[WARNING] Created user but failed to set display name for $userid: $message"
                ((created_success++))
                ((error_reasons["Failed to set display name: $message"]++))
            fi
        else
            message=$(echo "$response" | xmllint --xpath '//meta/message/text()' - 2>/dev/null)
            echo "[WARNING] Failed to create user $userid (email: $email): $message"
            ((created_failed++))
            ((error_reasons["$message"]++))
        fi
    else
        verbose "Would create user: $userid (display name: $display_name, email: $email) (dry run)"
        ((created_success++))  # Count as success in dry run
    fi
    
done < <(tail -n +2 "$CSV_FILE")

# Print summary
echo
echo "=== Summary ==="
echo "Total records processed: $total_processed"
if [ "$DO_CREATE" = true ]; then
    echo "Users successfully created: $created_success"
else
    echo "Users that would be created: $created_success"
fi
echo "Users skipped (no email): $skipped_no_email"
echo "Users skipped (existing email): $skipped_existing_email"
echo "Users skipped (existing external ID as userid): $skipped_existing_external_id"
echo "Users skipped (existing display name as userid): $skipped_existing_userid"
echo "Failed creation attempts: $created_failed"

if [ ${#error_reasons[@]} -gt 0 ]; then
    echo
    echo "Error breakdown:"
    for reason in "${!error_reasons[@]}"; do
        echo "  - $reason: ${error_reasons[$reason]}"
    done
fi

verbose "Processing complete" 