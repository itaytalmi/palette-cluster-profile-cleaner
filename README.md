# Spectro Cloud Palette Cluster Profile Cleaning Tool

A Bash script to identify and clean up unused cluster profile versions in Spectro Cloud Palette.

## Prerequisites

- `jq` - JSON processor
- `curl` - HTTP client
- Palette API Key

```bash
# Install jq
brew install jq                    # macOS
sudo apt-get install jq            # Ubuntu/Debian
```

## Installation

```bash
cd helpers/unused-cluster-profile-cleanup/
chmod +x palette-cluster-profile-cleaner.sh
export SPECTROCLOUD_APIKEY='your-api-key'
```

## Usage

### Modes

**analyze** - Analyze and report unused profiles (no changes)  
**cleanup** - Delete unused profiles (with confirmation prompts and backups by default)

### Basic Commands

```bash
# Analyze all profiles
./palette-cluster-profile-cleaner.sh analyze

# Analyze with CSV export
./palette-cluster-profile-cleaner.sh analyze --export-csv

# Cleanup unused profiles (interactive, with backups)
./palette-cluster-profile-cleaner.sh cleanup

# Cleanup with automated confirmation (for scripts/automation)
./palette-cluster-profile-cleaner.sh cleanup --confirm-all
```

### Options

| Option | Description |
|--------|-------------|
| `--api-url <URL>` | Palette API URL (default: https://api.spectrocloud.com) |
| `--project <NAME>` | Filter by project name |
| `--profile <NAME>` | Target specific cluster profile |
| `--export-csv` | Export results to CSV file |
| `--backup` | Enable backup (default in cleanup mode) |
| `--no-backup` | Disable backup |
| `--confirm-all` | Skip all prompts (for automation) |
| `--output-dir <DIR>` | Output directory (default: ./output) |
| `--debug` | Enable verbose logging |
| `--help` | Show help message |

## Examples

### Example 1: Analyze Specific Project

```bash
./palette-cluster-profile-cleaner.sh analyze --project my-project
```

### Example 2: Analyze Specific Profile

```bash
# Tenant-scoped profile
./palette-cluster-profile-cleaner.sh analyze --profile eks-full-prod

# Project-scoped profile
./palette-cluster-profile-cleaner.sh analyze --profile vsphere-addons-dev --project my-project
```

### Example 3: Cleanup with CSV Export (for auditing)

```bash
./palette-cluster-profile-cleaner.sh cleanup --export-csv
```

### Example 4: Automated Cleanup (CI/CD)

```bash
./palette-cluster-profile-cleaner.sh cleanup --confirm-all --export-csv
```

## How It Works

1. Fetches all cluster profiles (tenant-scoped and project-scoped)
2. Checks usage data embedded in each profile
3. **Analyze mode**: Displays results in a table and optionally exports to CSV. Example output:

    ```text
    [INFO] Checking prerequisites...
    [SUCCESS] Prerequisites check passed
    [INFO] Audit logging enabled: ./output/audit_20251105_113625.log

    ========================================================================
    Palette Cluster Profile Cleanup - analyze Mode
    ========================================================================
    API URL: https://api.spectrocloud.com
    Project: All projects (tenant and project-scoped profiles)
    Output directory: ./output
    ========================================================================

    [INFO] Starting analysis of unused cluster profile versions...
    [INFO] Fetching cluster profiles...
    [INFO] Fetching tenant-scoped cluster profiles...
    ...

    [INFO] ========================================
    [INFO] Analysis Results
    [INFO] ========================================

    PROFILE NAME                             VERSION           SCOPE     PROJECT        STATUS   UID                       
    ---------------------------------------- ----------------- --------- -------------- -------- --------------------------
    cp-eks-full-test                         3.0.0             tenant    -              UNUSED   6904c23d721c0a0cd23711e5  
    cp-eks-full-test                         2.0.0             tenant    -              UNUSED   6904c1e49ad0c81ec5c7c3d4  
    tf-aws-profile                           1.0.0             tenant    -              UNUSED   6904ecc8fd3740455375347f  
    mdp-addons                               1.0.0             project   some-project   UNUSED   6822024259485f932aad8cf2  
    VMO-RA-Infra-MaaS-Portworx               1.7.1-pxstorev2   project   some-project   UNUSED   68caf897e0db9f05b234c7ca  
    VMO-RA-Core-PXK                          1.7.1-pwx         project   some-project   UNUSED   68caf905284f6c7306ca49f4  
    VMO-RA-Templates                         1.7.1-pwx         project   some-project   UNUSED   68caf945e0db9f0addd3d553  
    toly-maas-px-full                        1.0.0             project   some-project   UNUSED   68c81b58b9ac72f7c70c92f2  
    vsphere-profile-test-cp                  1.0.1             tenant    -              IN USE   686f64982b8d5c4e884d5e21  
    vsphere-profile-test-cp-120-132          1.0.1             tenant    -              IN USE   686f7679ef72c1c76ae24c71  
    cp-maas-px-full                          1.0.0             tenant    -              IN USE   6846ead4bfeff7cdfaa1cc48  

    [INFO] ========================================
    [INFO] Summary
    [INFO] ========================================
    [INFO] Total profiles checked: 74
    [INFO] Unused profiles found: 62
    [INFO] Profiles skipped (out of scope): 1

    [SUCCESS] Analysis complete!

    [SUCCESS] Operation completed successfully!
    [INFO] Full audit log saved to: ./output/audit_20251105_113625.log
    ```

4. **Cleanup mode**: Shows warnings, prompts for confirmation, backs up profiles, then deletes unused ones. Example output:

    ```text
    ➜  palette-cluster-profile-cleaner git:(main) ✗ ./palette-cluster-profile-cleaner.sh cleanup --project some-project
    [INFO] Checking prerequisites...
    [SUCCESS] Prerequisites check passed
    [INFO] Audit logging enabled: ./output/audit_20251105_114517.log
    [INFO] Looking up project UID for: some-project
    [SUCCESS] Found project 'some-project' with UID: 690b7e890897a6388e01069b

    ========================================================================

            ██     ██  █████  ██████  ███    ██ ██ ███    ██  ██████  
            ██     ██ ██   ██ ██   ██ ████   ██ ██ ████   ██ ██       
            ██  █  ██ ███████ ██████  ██ ██  ██ ██ ██ ██  ██ ██   ███ 
            ██ ███ ██ ██   ██ ██   ██ ██  ██ ██ ██ ██  ██ ██ ██    ██ 
            ███ ███  ██   ██ ██   ██ ██   ████ ██ ██   ████  ██████  

                CLEANUP MODE - PROFILES WILL BE DELETED!

    ========================================================================
    API URL: https://api.spectrocloud.com
    Project: some-project (UID: 690b7e890897a6388e01069b)
    Backup enabled: false
    Confirmation mode: Interactive
    Output directory: ./output
    ========================================================================


    YOU ARE ABOUT TO DELETE UNUSED CLUSTER PROFILES!


    This operation will:
    - Analyze cluster profiles to find unused ones
    - Prompt for confirmation before deleting EACH profile

    Do you want to proceed with cleanup mode? (yes/no): yes

    [INFO] Starting cleanup of unused cluster profile versions...
    [INFO] Fetching cluster profiles...
    ...
    [INFO] Analyzing and cleaning up unused cluster profiles...
    [INFO] Checking: unused-cluster-profile (UID: 690b7eaf721c3bbe1340d037)
    [WARNING] Profile: unused-cluster-profile (v1.0.0, Scope: project, Project: some-project) - UNUSED

    DELETE THIS PROFILE?
        Name: unused-cluster-profile
        Version: 1.0.0
        Scope: project
        Project: some-project
        UID: 690b7eaf721c3bbe1340d037

    Confirm deletion (yes/no): yes

    [WARNING]   Deleting profile...
    {"success": true}
    [SUCCESS]   Deleted successfully

    [INFO] ========================================
    [INFO] Cleanup Results
    [INFO] ========================================

    PROFILE NAME             VERSION   SCOPE     PROJECT        STATUS   ACTION   
    ------------------------ --------- --------- -------------- -------- ---------
    unused-cluster-profile   1.0.0     project   some-project   DELETED  Deleted
    ```

## Output Files

All output is saved to `./output/` (or custom directory):

- `audit_TIMESTAMP.log` - Complete execution log (always created)
- `analyze_TIMESTAMP.csv` - Analysis results (if --export-csv used)
- `cleanup_TIMESTAMP.csv` - Cleanup results (if --export-csv used)
- `backups/profile_UID_vVERSION_TIMESTAMP.json` - Profile backups (if backup enabled)

## Notes

- **Tenant-scoped profiles**: Shared across all projects
- **Project-scoped profiles**: Specific to one project
- **System-scoped profiles**: Always ignored by this script
- When filtering by project, only project-scoped profiles for that project are processed
- When no project specified, all tenant-scoped and all project-scoped profiles are checked
- Cleanup mode enables backups by default for safety

## Troubleshooting

**"SPECTROCLOUD_APIKEY environment variable is not set"**
```bash
export SPECTROCLOUD_APIKEY='your-api-key'
```

**"jq is required but not installed"**
```bash
brew install jq  # macOS
sudo apt-get install jq  # Linux
```

**No profiles found**
- Verify API key is valid
- Check API URL is correct
- Ensure you have permissions to view cluster profiles

## Safety Features

- Read-only analyze mode for testing
- Interactive confirmation prompts in cleanup mode
- Automatic backups enabled by default
- Complete audit logging
- Color-coded status indicators
- System profiles are always ignored

## Quick Start

```bash
# 1. Set API key
export SPECTROCLOUD_APIKEY='your-api-key'

# 2. Analyze (safe, no changes)
./palette-cluster-profile-cleaner.sh analyze

# 3. Review results in the table output

# 4. Cleanup with backups
./palette-cluster-profile-cleaner.sh cleanup
```

That's it! The script will guide you through the rest.
