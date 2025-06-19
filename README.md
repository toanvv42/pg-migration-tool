# PostgreSQL Migration Tool

A Bash script for automating the migration of PostgreSQL databases from AWS RDS to Google Cloud SQL.

## Features

- Interactive database selection using `fzf`
- Automated database dump from AWS RDS instances
- Transfer via S3 bucket
- Restore to GCP Cloud SQL using Kubernetes pod
- YAML-based state management for tracking migration progress
- Support for dry-run and retry operations
- Detailed logging

## Prerequisites

- `bash` (version 4+)
- `yq` for YAML processing
- `fzf` for interactive selection (optional but recommended)
- `pass` for secure password management
- `aws` CLI configured with proper profiles
- `kubectl` configured with access to the target Kubernetes cluster
- `kustomize` (used with `--enable-alpha-plugins` flag)

## Configuration

1. Copy the example environment file and update it with your configuration:

   ```bash
   cp .env.example .env
   ```

2. Edit the `.env` file with your specific settings:

   ```bash
   # AWS Configuration
   AWS_PROFILE=your-profile
   AWS_REGION=your-region
   
   # EC2 Configuration
   EC2_FILTER=your-ec2-filter
   
   # S3 Configuration
   S3_BUCKET=your-s3-bucket
   
   # Database Configuration
   SOURCE_HOST=your-source-db-host
   TARGET_HOST=your-target-db-host
   
   # Kubernetes Configuration
   KUBERNETES_NAMESPACE=your-namespace
   
   # Optional: Debug mode (true/false)
   # DEBUG=false
   ```

3. The `.env` file is automatically added to `.gitignore` to prevent committing sensitive information.

## Installation

1. Clone this repository
2. Make the script executable (if not already): `chmod +x pg-migration.sh`

## Usage

### Basic Usage

1. First, ensure you have a `.env` file configured (see Configuration section above)
2. Run the migration script:

   ```bash
   ./pg-migration.sh
   ```

This will:
1. Load configuration from `.env`
2. Prompt you to select a database to migrate
3. Execute the full migration workflow
4. Track progress in the `migration_state.yaml` file

### Options

```bash
./pg-migration.sh --dry-run    # Show what would be done without performing actual migration
./pg-migration.sh --retry      # Retry failed or pending steps from previous migration attempts
./pg-migration.sh --debug      # Enable debug output for connection details and troubleshooting
./pg-migration.sh --help       # Display help information
```

## State Management

The migration process maintains state in `migration_state.yaml` with the following structure:

```yaml
databases:
  - name: database_name
    dump: success|failed|pending
    upload: success|failed|pending
    restore: success|failed|pending
    last_updated: 2025-06-19T11:30:45Z
```

This allows for:
- Tracking migration progress
- Resuming failed migrations
- Skipping completed steps during retries

## Security Notes

- All credentials are retrieved using `pass`
- No passwords are hardcoded or stored in the script
- AWS credentials for S3 access are retrieved securely
