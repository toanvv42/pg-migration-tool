#!/bin/bash

# PostgreSQL Migration Tool - AWS RDS to GCP Cloud SQL
# Created: 2025-06-19

set -e

# ===== LOAD ENVIRONMENT VARIABLES =====
# Load .env file if it exists
if [ -f ".env" ]; then
    # Export all variables from .env
    set -o allexport
    source .env
    set +o allexport
    
    # Export AWS_REGION for all AWS CLI commands
    export AWS_REGION="${AWS_REGION}"
    
    # Set default values if not provided in .env
    DEBUG=${DEBUG:-false}
    STATE_FILE=${STATE_FILE:-'migration_state.yaml'}
else
    echo "Error: .env file not found. Please create one based on .env.example"
    exit 1
fi

# ===== VALIDATE REQUIRED VARIABLES =====
required_vars=(
    "AWS_PROFILE"
    "AWS_REGION"
    "EC2_FILTER"
    "S3_BUCKET"
    "SOURCE_HOST"
    "TARGET_HOST"
    "KUBERNETES_NAMESPACE"
)

for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        echo "Error: Required environment variable $var is not set in .env file"
        exit 1
    fi
done

# ===== COLORS FOR LOGGING =====
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ===== UTILITY FUNCTIONS =====

log_info() {
    echo -e "${BLUE}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
    if [ "$2" = "exit" ]; then
        exit 1
    fi
}

# ===== YAML STATE MANAGEMENT FUNCTIONS =====

init_state_file() {
    if [ ! -f "$STATE_FILE" ]; then
        log_info "Creating new state file: $STATE_FILE"
        echo "databases: []" > "$STATE_FILE"
    fi
}

get_db_state() {
    local db_name="$1"
    local state=$(yq e ".databases[] | select(.name == \"$db_name\")" "$STATE_FILE" 2>/dev/null)
    if [ -z "$state" ]; then
        echo "not_found"
    else
        echo "$state"
    fi
}

add_db_to_state() {
    local db_name="$1"
    local current_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    local state=$(get_db_state "$db_name")
    if [ "$state" = "not_found" ]; then
        log_info "Adding database $db_name to state file"
        yq e -i ".databases += [{\"name\": \"$db_name\", \"dump\": \"pending\", \"upload\": \"pending\", \"restore\": \"pending\", \"last_updated\": \"$current_time\"}]" "$STATE_FILE"
    fi
}

update_db_state() {
    local db_name="$1"
    local step="$2"
    local status="$3"
    local current_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    log_info "Updating state for $db_name: $step -> $status"
    yq e -i "(.databases[] | select(.name == \"$db_name\").$step) = \"$status\"" "$STATE_FILE"
    yq e -i "(.databases[] | select(.name == \"$db_name\").last_updated) = \"$current_time\"" "$STATE_FILE"
}

# ===== DATABASE SELECTION =====

list_available_databases() {
    if [ "$DEBUG" = true ]; then
        log_info "Retrieving list of available databases..."
    fi
    
    # Capture the output instead of printing directly
    # Filter out debug messages and empty lines, focus on actual database names
    DB_LIST=$(pass ls db/v16 2>/dev/null | grep -v "^\[" | grep -v "^$" | awk '{print $2}' | grep -v "^$" | while read db; do echo "${db}_db"; done)
    echo "$DB_LIST"
}

select_database() {
    if command -v fzf >/dev/null 2>&1; then
        if [ "$DEBUG" = true ]; then
            log_info "Please select a database to migrate using fzf:"
        else
            echo "Please select a database to migrate:"
        fi
        
        # Store the database list to a temporary file
        local db_list_file=$(mktemp)
        list_available_databases > "$db_list_file"
        
        # Use fzf to select from the file
        SELECTED_DB=$(cat "$db_list_file" | fzf --header="Select database to migrate" --height=40% --layout=reverse)
        rm -f "$db_list_file"
    else
        log_warning "fzf is not installed, falling back to manual selection"
        echo "Available databases:"
        
        # Get clean database list
        local db_list=$(list_available_databases)
        
        # Format and display for selection
        local i=1
        echo "$db_list" | while read db; do
            echo "$i) $db"
            i=$((i+1))
        done
        
        echo -n "Enter the number of the database to migrate: "
        read choice
        
        SELECTED_DB=$(echo "$db_list" | sed -n "${choice}p")
    fi
    
    if [ -z "$SELECTED_DB" ]; then
        log_error "No database selected. Exiting." "exit"
    fi
    
    log_success "Selected database: $SELECTED_DB"
    # Strip _db suffix for further processing if needed
    DB_NAME=${SELECTED_DB%_db}
    DB_OWNER="${DB_NAME}_owner"
    return 0
}

# ===== AWS EC2 INSTANCE MANAGEMENT =====

get_ec2_instance_id() {
    log_info "Finding EC2 instance ID for $EC2_FILTER..."
    INSTANCE_ID=$(aws ec2 describe-instances \
      --filters "Name=tag:Name,Values=$EC2_FILTER" \
      --query "Reservations[*].Instances[*].InstanceId" \
      --output text \
      --profile $AWS_PROFILE)
      
    if [ -z "$INSTANCE_ID" ]; then
        log_error "Failed to find EC2 instance. Exiting." "exit"
    fi
    
    log_success "Found EC2 instance ID: $INSTANCE_ID"
    return 0
}

# ===== EC2 TOOLS VERIFICATION =====

verify_ec2_tools() {
    log_info "Verifying required tools on EC2 instance..."
    ssh ubuntu@$INSTANCE_ID << 'EOF'
        set -e
        tools=("pg_dump" "aws" "unzip" "update-ca-certificates")
        missing=()
        
        echo "Checking installed tools..."
        for tool in "${tools[@]}"; do
            if ! command -v $tool &> /dev/null; then
                missing+=($tool)
            fi
        done
        
        if [ ${#missing[@]} -gt 0 ]; then
            echo "Installing missing tools: ${missing[*]}"
            sudo apt-get update
            
            if [[ " ${missing[*]} " =~ " pg_dump " ]]; then
                sudo apt-get install -y postgresql-client
            fi
            
            if [[ " ${missing[*]} " =~ " aws " ]]; then
                curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip"
                unzip /tmp/awscliv2.zip -d /tmp
                sudo /tmp/aws/install
                rm -rf /tmp/aws /tmp/awscliv2.zip
            fi
            
            if [[ " ${missing[*]} " =~ " unzip " ]]; then
                sudo apt-get install -y unzip
            fi
            
            if [[ " ${missing[*]} " =~ " update-ca-certificates " ]]; then
                sudo apt-get install -y ca-certificates
                sudo update-ca-certificates
            fi
        fi
        
        # Ensure AWS CLI configuration
        mkdir -p ~/.aws
        echo "[default]" > ~/.aws/config
        echo "region = us-west-2" >> ~/.aws/config
        
        echo "All required tools are installed."
EOF

    if [ $? -ne 0 ]; then
        log_error "Failed to verify tools on EC2 instance. Exiting." "exit"
    fi
    
    log_success "All required tools are verified on EC2 instance."
    return 0
}

# ===== DATABASE DUMP =====

dump_database() {
    local db_name="$1"
    local db_owner="${db_name}_owner"
    
    log_info "Getting database password using 'pass'..."
    DB_PASSWORD=$(pass db/v16/$db_name)
    
    if [ -z "$DB_PASSWORD" ]; then
        log_error "Failed to get database password for $db_name. Exiting." "exit"
    fi
    
    # Create the database connection string for debugging
    DATABASE_URL="postgresql://${db_owner}:${DB_PASSWORD}@${SOURCE_HOST}/${db_name}_db"
    
    if [ "$DEBUG" = true ]; then
        log_info "Database URL: ${DATABASE_URL//:*@/:****@}"
    fi
    
    log_info "Dumping database $db_name from source..."
    ssh ubuntu@$INSTANCE_ID << EOF
        set -e
        export PGPASSWORD='$DB_PASSWORD'
        
        if [ "$DEBUG" = true ]; then
            echo "Connection details:"
            echo "Host: $SOURCE_HOST"
            echo "User: $db_owner"
            echo "Database: ${db_name}_db"
            echo "Password length: \${#PGPASSWORD}"
        fi
        
        pg_dump -h $SOURCE_HOST -U $db_owner -d ${db_name}_db -F c -Z 9 -f /tmp/${db_name}.dump 2>/tmp/${db_name}.log
        if [ \$? -eq 0 ]; then
            echo "Database dump completed successfully."
        else
            echo "Database dump failed."
            exit 1
        fi
EOF

    if [ $? -ne 0 ]; then
        log_error "Database dump failed. Exiting." "exit"
        update_db_state "$db_name" "dump" "failed"
        return 1
    fi
    
    log_success "Database $db_name dumped successfully."
    update_db_state "$db_name" "dump" "success"
    return 0
}

# ===== S3 UPLOAD =====

upload_to_s3() {
    local db_name="$1"
    
    log_info "Uploading dump to S3 bucket: $S3_BUCKET"
    ssh ubuntu@$INSTANCE_ID << EOF
        set -e
        aws s3 cp /tmp/${db_name}.dump $S3_BUCKET --region $AWS_REGION
        if [ \$? -eq 0 ]; then
            echo "Upload completed successfully."
            rm -f /tmp/${db_name}.dump
            echo "Removed local dump file."
        else
            echo "Upload failed."
            exit 1
        fi
EOF

    if [ $? -ne 0 ]; then
        log_error "Failed to upload dump to S3. Exiting." "exit"
        update_db_state "$db_name" "upload" "failed"
        return 1
    fi
    
    log_success "Database dump uploaded to S3 successfully."
    update_db_state "$db_name" "upload" "success"
    return 0
}

# ===== KUBERNETES RESTORE POD =====

create_restore_pod() {
    log_info "Creating Kubernetes restore pod..."
    
    # Create pod manifest
    cat > restore-pod.yaml << EOT
apiVersion: v1
kind: Pod
metadata:
  name: db-restore-agent
  namespace: $KUBERNETES_NAMESPACE
spec:
  restartPolicy: Never
  containers:
    - name: ubuntu
      image: ubuntu:noble
      command: ["/bin/bash", "-c"]
      args:
        - |
          set -e
          apt-get update
          apt-get install -y curl ca-certificates gnupg lsb-release
          update-ca-certificates
          curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip"
          apt-get install -y unzip
          unzip /tmp/awscliv2.zip -d /tmp
          /tmp/aws/install
          rm -rf /tmp/aws /tmp/awscliv2.zip
          apt-get install -y postgresql-client
          echo "All tools installed. Sleeping..."
          exec sleep infinity
      tty: true
      stdin: true
      resources:
        requests:
          cpu: "200m"
          memory: "512Mi"
          ephemeral-storage: "10Gi"
EOT

    # Apply the manifest directly with kubectl
    log_info "Applying Kubernetes pod manifest..."
    kubectl apply -f restore-pod.yaml

    # Wait for pod to be ready
    log_info "Waiting for pod to be ready..."
    kubectl wait --for=condition=Ready pod/db-restore-agent -n $KUBERNETES_NAMESPACE --timeout=120s

    if [ $? -ne 0 ]; then
        log_error "Failed to create restore pod. Exiting." "exit"
        return 1
    fi
    
    log_success "Restore pod created successfully."
    return 0
}

# ===== DATABASE RESTORE =====

restore_database() {
    local db_name="$1"
    local db_owner="${db_name}_owner"
    
    log_info "Getting AWS credentials using 'pass'..."
    AWS_ACCESS_KEY=$(pass aws/s3-to-gcs/aws_access_key_id)
    AWS_SECRET_KEY=$(pass aws/s3-to-gcs/aws_secret_access_key)
    
    if [ -z "$AWS_ACCESS_KEY" ] || [ -z "$AWS_SECRET_KEY" ]; then
        log_error "Failed to get AWS credentials. Exiting." "exit"
        return 1
    fi
    
    log_info "Getting GCP database password..."
    GCP_DB_PASSWORD_RAW=$(pass db/opusmatch-non-pro/$db_owner)
    GCP_DB_PASSWORD=$(python3 -c "import urllib.parse; print(urllib.parse.unquote(\"$GCP_DB_PASSWORD_RAW\"))")
    
    if [ -z "$GCP_DB_PASSWORD" ]; then
        log_error "Failed to get GCP database password. Exiting." "exit"
        return 1
    fi
    
    log_info "Verifying required tools in restore pod..."
    kubectl exec -it db-restore-agent -n $KUBERNETES_NAMESPACE -- bash -c "
        set -e
        # Check if AWS CLI is installed and working
        if ! command -v aws &> /dev/null; then
            echo 'AWS CLI not found. Waiting for installation to complete...'
            for i in {1..30}; do
                if command -v aws &> /dev/null; then
                    echo 'AWS CLI is now available.'
                    break
                fi
                echo -n '.'
                sleep 2
                if [ \$i -eq 30 ]; then
                    echo 'Timed out waiting for AWS CLI installation.'
                    exit 1
                fi
            done
        fi
        
        # Check if pg_restore is installed and working
        if ! command -v pg_restore &> /dev/null; then
            echo 'pg_restore not found. Waiting for installation to complete...'
            for i in {1..30}; do
                if command -v pg_restore &> /dev/null; then
                    echo 'pg_restore is now available.'
                    break
                fi
                echo -n '.'
                sleep 2
                if [ \$i -eq 30 ]; then
                    echo 'Timed out waiting for pg_restore installation.'
                    exit 1
                fi
            done
        fi
        
        echo 'All required tools are available in the restore pod.'
    "
    
    log_info "Restoring database in GCP..."
    kubectl exec -it db-restore-agent -n $KUBERNETES_NAMESPACE -- bash -c "
        set -e
        export AWS_ACCESS_KEY_ID='$AWS_ACCESS_KEY'
        export AWS_SECRET_ACCESS_KEY='$AWS_SECRET_KEY'
        export AWS_DEFAULT_REGION='$AWS_REGION'
        
        # Download dump from S3
        if [[ ! -f /tmp/${db_name}.dump ]]; then
          aws s3 cp $S3_BUCKET${db_name}.dump /tmp/${db_name}.dump --region $AWS_REGION        
        fi
        # Restore to GCP
        export PGPASSWORD='$GCP_DB_PASSWORD'
        pg_restore --no-owner -h $TARGET_HOST -U $db_owner -d ${db_name}_db -c -F c /tmp/${db_name}.dump

        # Clean up
        rm -f /tmp/${db_name}.dump
    "
    
    if [ $? -ne 0 ]; then
        log_error "Database restore failed. Exiting." "exit"
        update_db_state "$db_name" "restore" "failed"
        return 1
    fi
    
    log_success "Database $db_name restored successfully."
    update_db_state "$db_name" "restore" "success"
    return 0
}

# ===== CLEANUP =====

cleanup() {
    log_info "Cleaning up resources..."
    
    # Ask for confirmation before deleting the pod
    read -p "Do you want to delete the restore pod? This will prevent restoring additional databases. (y/n): " confirm
    if [[ $confirm == [yY] || $confirm == [yY][eE][sS] ]]; then
        kubectl delete pod db-restore-agent -n $KUBERNETES_NAMESPACE
        log_success "Cleanup completed."
    else
        log_warning "Restore pod was not deleted. Remember to delete it manually when finished."
    fi
    
    return 0
}

# ===== MAIN EXECUTION =====

show_help() {
    echo "PostgreSQL Migration Tool - AWS RDS to GCP Cloud SQL"
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --dry-run     Show what would be done without actually performing the migration"
    echo "  --retry       Retry failed or pending steps from previous migration attempts"
    echo "  --debug       Enable debug output for troubleshooting"
    echo "  --help        Display this help and exit"
    echo ""
}

main() {
    # Parse command line arguments
    DRY_RUN=false
    RETRY=false
    DEBUG=false
    
    while [ $# -gt 0 ]; do
        case "$1" in
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --retry)
                RETRY=true
                shift
                ;;
            --debug)
                DEBUG=true
                shift
                ;;
            --help)
                show_help
                exit 0
                ;;
            *)
                log_error "Unknown option: $1" "exit"
                ;;
        esac
    done
    
    # Initialize the state file
    init_state_file
    
    # Select database to migrate
    select_database
    
    # Check if we should retry or if this is a new migration
    if [ "$RETRY" = true ]; then
        log_info "Retry mode enabled, checking previous state for $DB_NAME..."
        DB_STATE=$(get_db_state "$DB_NAME")
        
        if [ "$DB_STATE" = "not_found" ]; then
            log_warning "No previous state found for $DB_NAME, proceeding with new migration."
            add_db_to_state "$DB_NAME"
        fi
    else
        # Add the database to the state file
        add_db_to_state "$DB_NAME"
    fi
    
    # Check if dry run mode is enabled
    if [ "$DRY_RUN" = true ]; then
        log_info "DRY RUN mode enabled, no actual operations will be performed."
        log_info "Would perform the following steps for database $DB_NAME:"
        log_info "1. Get EC2 instance ID"
        log_info "2. Verify required tools on EC2"
        log_info "3. Dump database from AWS RDS"
        log_info "4. Upload dump to S3"
        log_info "5. Create Kubernetes restore pod"
        log_info "6. Restore database to GCP Cloud SQL"
        log_info "7. Clean up resources"
        exit 0
    fi
    
    # Get EC2 instance ID
    get_ec2_instance_id
    
    # Verify EC2 tools
    verify_ec2_tools
    
    # Check dump status and perform if needed
    DUMP_STATUS=$(yq e ".databases[] | select(.name == \"$DB_NAME\").dump" "$STATE_FILE")
    if [ "$DUMP_STATUS" != "success" ]; then
        dump_database "$DB_NAME"
    else
        log_info "Dump step already completed for $DB_NAME"
    fi
    
    # Check upload status and perform if needed
    UPLOAD_STATUS=$(yq e ".databases[] | select(.name == \"$DB_NAME\").upload" "$STATE_FILE")
    if [ "$UPLOAD_STATUS" != "success" ]; then
        upload_to_s3 "$DB_NAME"
    else
        log_info "Upload step already completed for $DB_NAME"
    fi
    
    # Create restore pod in Kubernetes
    create_restore_pod
    
    # Check restore status and perform if needed
    RESTORE_STATUS=$(yq e ".databases[] | select(.name == \"$DB_NAME\").restore" "$STATE_FILE")
    if [ "$RESTORE_STATUS" != "success" ]; then
        restore_database "$DB_NAME"
    else
        log_info "Restore step already completed for $DB_NAME"
    fi
    
    # Cleanup resources
    cleanup
    
    log_success "Migration of $DB_NAME completed successfully!"
    return 0
}

# Execute main function
main "$@"
