# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a PostgreSQL migration tool that automates the process of migrating databases from AWS RDS to Google Cloud SQL. The tool is implemented as a Bash script that orchestrates the entire migration workflow including database dumping, S3 transfer, and restoration via Kubernetes pods.

## Key Components

### Main Script: `pg-migration.sh`
The core migration script with the following workflow:
1. **Database Selection**: Interactive selection using `fzf` (with fallback to manual selection)
2. **EC2 Instance Management**: Finds and configures EC2 instances for database operations
3. **Database Dumping**: Uses `pg_dump` on EC2 to create compressed database dumps
4. **S3 Transfer**: Uploads dumps to S3 bucket for transfer between cloud providers
5. **Kubernetes Restoration**: Creates pods in GKE to restore databases to Cloud SQL
6. **State Management**: Tracks migration progress via YAML state file

### State Management: `migration_state.yaml`
YAML file tracking migration progress with statuses (pending/success/failed) for each database:
- `dump`: Database dump from source
- `upload`: S3 upload status
- `restore`: Restoration to target database

### Pod Configuration: `restore-pod.yaml`
Kubernetes pod manifest for the restoration process, automatically generated during execution.

## Configuration

### Environment Variables (`.env`)
Required configuration based on `.env.example`:
```bash
# AWS Configuration
AWS_PROFILE=your-profile
AWS_REGION=your-region

# EC2 Configuration  
EC2_FILTER=your-ec2-filter

# S3 Configuration
S3_BUCKET=s3://your-bucket/

# Database Configuration
SOURCE_HOST=source-db-host
TARGET_HOST=target-db-host

# Kubernetes Configuration
KUBERNETES_NAMESPACE=your-namespace
```

## Commands

### Run Migration
```bash
./pg-migration.sh                 # Interactive migration
./pg-migration.sh --dry-run      # Show planned steps without execution
./pg-migration.sh --retry        # Retry failed/pending steps
./pg-migration.sh --debug        # Enable debug output
./pg-migration.sh --help         # Show help information
```

### Testing
The project uses BATS (Bash Automated Testing System) for testing:
```bash
# Run tests (if test files exist in tests/ directory)
bats tests/
```

Note: The current `tests/` directory contains bats-support and bats-assert libraries but no actual test files yet.

## Security Model

- **Password Management**: Uses `pass` (password store) for secure credential retrieval
- **AWS Credentials**: Retrieved via `pass` for S3 operations
- **Database Passwords**: Retrieved via `pass` for both source and target databases
- **No Hardcoded Secrets**: All sensitive information is externalized

## Architecture Notes

- **State-Based Execution**: Can resume from any failed step using the YAML state file
- **Multi-Cloud Orchestration**: Coordinates between AWS (EC2/S3) and GCP (Cloud SQL/GKE)
- **Interactive Selection**: Uses `fzf` for user-friendly database selection
- **Error Handling**: Comprehensive error handling with colored logging
- **Resource Management**: Includes cleanup procedures for temporary resources

## Development Notes

- Primary language: Bash (requires version 4+)
- Dependencies: `yq`, `fzf`, `pass`, `aws`, `kubectl`, `kustomize`
- The script follows defensive programming practices with `set -e` and comprehensive error checking
- Uses colored output for better user experience
- Modular function design for maintainability