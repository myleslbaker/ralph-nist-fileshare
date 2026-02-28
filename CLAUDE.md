# Ralph Agent Instructions — NIST Secure File Share (Dropbox-style)

You are an autonomous coding agent deploying a NIST 800-171 compliant secure file share service (Dropbox-style using Nextcloud 27+), integrated with the existing NIST.LAB Active Directory and VPN infrastructure.

## CRITICAL: NEVER Modify the Host Server's Network or System Configuration

**Same rule as the parent project. Never touch DNS, networking, or system config on this Ralph host (the EC2 instance running this agent). All infrastructure deploys to SEPARATE EC2 instances.**

---

## CRITICAL: `passes: true` Requires REAL DEPLOYMENT — NOT Syntax Checks

Identical rule as the parent project:
- `terraform apply` must succeed (real AWS resources created)
- Real resource IDs captured
- Live service verified (SSH/SSM to instance and confirm service running, functional test)
- DEPLOYMENT-PROOF block in progress.txt with real IDs

**NEVER set `passes: true` after only syntax checks, plan, or validate.**

---

## Your Task

1. Read `prd.json` in this directory
2. Read `progress.txt` (check Codebase Patterns section first)
3. You are on branch `main` — this is correct
4. Pick the **highest priority** story where `passes: false`
5. Implement that single story
6. Deploy and verify (terraform apply + SSM functional tests)
7. Commit, push to GitHub immediately
8. Update prd.json `passes: true` only after real verification
9. Append DEPLOYMENT-PROOF to progress.txt, commit, push

---

## Integration Context — Parent Project Infrastructure

This project BUILDS ON TOP of the existing NIST.LAB AD/VPN/MFA infrastructure from `ralph-nist-iac-v5`. **Do NOT recreate VPC, subnets, IGW, or base IAM policies.**

### Key SSM Parameters (from parent project — always look these up dynamically):
```bash
DC1_IP=$(aws ssm get-parameter --name /nist/infra/dc1-private-ip --query Parameter.Value --output text)
MFA1_IP=$(aws ssm get-parameter --name /nist/infra/mfa1-private-ip --query Parameter.Value --output text)
VPN_PRIVATE_IP=$(aws ssm get-parameter --name /nist/infra/vpn-private-ip --query Parameter.Value --output text)
VPN_PUBLIC_IP=$(aws ssm get-parameter --name /nist/infra/vpn-public-ip --query Parameter.Value --output text)
RADIUS_BIND_PW=$(aws ssm get-parameter --name /nist/samba/radius-bind-password --query Parameter.Value --output text --with-decryption)
```

### Key Infrastructure Values:
- **AWS Account**: 466510536180, **Region**: us-east-1
- **VPC**: vpc-0029e7ab9f2917e2c (10.0.0.0/16)
- **Private Subnet**: subnet-0cff2938b18b3977a (10.0.64.0/20) — deploy fileshare1 here
- **Public Subnet**: subnet-063f50cee12f4429a (10.0.0.0/20)
- **AD Domain**: NIST.LAB / nist.lab, **DC1 IP**: confirm from SSM /nist/infra/dc1-private-ip
- **VPN Client Subnet**: 10.8.0.0/24
- **KMS Key**: alias/nist-iac-builder
- **Terraform State**: s3://m4-ralph-tfstate-test, key: projects/nist-fileshare/terraform.tfstate
- **S3 TF State Bucket**: m4-ralph-tfstate-test

### Domain Credentials (from parent project Secrets Manager):
- **Domain admin**: NIST\Administrator / Admin1234!
- **vpn-user**: VpnUser1234!NIST
- **nist-admin**: NistAdmin1234!NIST
- **radius-bind service account**: CN=radius-bind,OU=NIST-Users,DC=nist,DC=lab (password from SSM /nist/samba/radius-bind-password)

### SNS Topic for Alerts:
Look up by: `aws sns list-topics | grep nist` — use the nist-security-alerts topic ARN for CloudWatch alarms.

---

## Technology Stack

### File Share:
- **Nextcloud 27+** — web file share (WebDAV, sync clients, sharing)
- **MariaDB 10.x** — Nextcloud database (local on same EC2)
- **PHP 8.1-fpm + Nginx** — web stack
- **Nextcloud server-side encryption (SSE)** — files encrypted at rest on disk
- **End-to-End Encryption (E2EE) app** — client-side encryption for sensitive folders
- **admin_audit app** — audit logging for all file operations
- **groupfolders app** — shared team workspaces
- **files_antivirus app** — ClamAV integration for upload scanning
- All on a single EC2 instance: **nist-fileshare1** (t3.small, 60GB gp3 EBS)

### Desktop Sync:
- **nextcloudcmd** — headless CLI sync client (used for automated verification)
- End users: Nextcloud Desktop app (Windows/macOS/Linux) or WebDAV mount

---

## Terraform Workflow

This project uses its own Terraform state, separate from the parent project.

```bash
cd /home/ubuntu/ralph-workspace/fileshare/terraform

# Always use terraform directly (infracost NOT configured — no API key):
terraform init
terraform plan
terraform apply -auto-approve

# State backend: configured in terraform/backend.tf
# Key: projects/nist-fileshare/terraform.tfstate
```

**Do NOT run infracost or estimate-cost.sh — it is not configured in this project.**

### Terraform Provider Default Tags:
```hcl
provider "aws" {
  region = "us-east-1"
  default_tags {
    tags = {
      Project     = "nist-fileshare"
      ManagedBy   = "ralph-terraform"
      Environment = "ephemeral"
    }
  }
}
```

### Discover Parent Project Resources with Data Sources:
```hcl
data "aws_vpc" "nist" {
  id = "vpc-0029e7ab9f2917e2c"
}

data "aws_subnet" "private" {
  id = "subnet-0cff2938b18b3977a"
}

data "aws_kms_key" "nist" {
  key_id = "alias/nist-iac-builder"
}
```

---

## SSM RunCommand Pattern

Use SSM Run Command (not Ansible) for all server-side configuration:

```bash
# Run a shell command on an instance
ssm_run() {
  local instance_id="$1"
  local command="$2"
  local timeout="${3:-120}"

  cmd_id=$(aws ssm send-command \
    --instance-ids "$instance_id" \
    --document-name "AWS-RunShellScript" \
    --parameters "commands=[\"$command\"]" \
    --query "Command.CommandId" --output text)

  sleep 5
  aws ssm get-command-invocation \
    --command-id "$cmd_id" \
    --instance-id "$instance_id" \
    --query "[StandardOutputContent,StandardErrorContent]" \
    --output text
}

# For multi-line scripts: write to temp file, upload to S3, use presigned URL with Run Command sourceInfo
```

**For large scripts**: use `AWS-RunRemoteScript` document with S3 sourceInfo, or base64-encode the script and pipe through `base64 -d | bash`.

---

## Nextcloud-Specific Notes

### Installation:
```bash
# Download and install Nextcloud
wget https://download.nextcloud.com/server/releases/latest.zip -O /tmp/nextcloud.zip
unzip /tmp/nextcloud.zip -d /var/www/
chown -R www-data:www-data /var/www/nextcloud

# Run occ for initial setup (MUST run as www-data)
sudo -u www-data php /var/www/nextcloud/occ maintenance:install \
  --database "mysql" --database-name "nextcloud" \
  --database-user "ncuser" --database-pass "PASS" \
  --admin-user "ncadmin" --admin-pass "NcAdmin1234!" \
  --data-dir "/var/www/nextcloud/data"
```

### occ commands — always run as www-data:
```bash
sudo -u www-data php /var/www/nextcloud/occ [command]

# Key commands:
occ maintenance:mode --on/--off
occ ldap:set-config s01 ldapHost "10.x.x.x"
occ ldap:test-config s01
occ user:list
occ app:enable server_side_encryption
occ encryption:enable
occ encryption:encrypt-all
occ app:enable end_to_end_encryption
occ app:enable admin_audit
occ app:enable groupfolders
occ app:enable files_antivirus
```

### trusted_domains — MUST configure or Nextcloud rejects requests:
```bash
sudo -u www-data php /var/www/nextcloud/occ config:system:set trusted_domains 0 --value="localhost"
sudo -u www-data php /var/www/nextcloud/occ config:system:set trusted_domains 1 --value="10.0.x.x"
```

### LDAP with Samba AD:
- LDAP host: DC1 private IP (from SSM)
- Base DN: `DC=nist,DC=lab`
- Bind DN: `CN=radius-bind,OU=NIST-Users,DC=nist,DC=lab`
- Bind PW: from SSM `/nist/samba/radius-bind-password`
- User filter: `(&(objectClass=person)(sAMAccountName=*))`
- Login filter: `(&(objectClass=person)(sAMAccountName=%uid))`
- LDAP Group DN: `OU=NIST-Users,DC=nist,DC=lab`
- Group filter: `(objectClass=group)`
- After LDAP config: `occ ldap:test-config s01` must return "The configuration is valid and the connection could be established"
- Force user sync: `occ ldap:show-remnants` then `occ user:list`

### Server-Side Encryption (SSE):
```bash
occ app:enable server_side_encryption
occ encryption:enable
# Users must log in once to trigger key generation, OR:
occ encryption:encrypt-all --yes
```

### Nginx Configuration:
- PHP-FPM socket: `/var/run/php/php8.1-fpm.sock`
- Nextcloud webroot: `/var/www/nextcloud`
- Required headers: `Strict-Transport-Security`, `X-Content-Type-Options`, `X-Frame-Options: SAMEORIGIN`
- WebDAV must work at `/remote.php/dav/`
- Max upload size: set `client_max_body_size 10G;` in nginx for large file support

### nextcloudcmd for testing:
```bash
# Install nextcloud-client (provides nextcloudcmd)
apt-get install -y nextcloud-client  # or build from source if not in repos
# Or use curl/WebDAV directly for testing:
curl -u "user:pass" -T /tmp/testfile.txt "https://SERVER/remote.php/dav/files/user/testfile.txt"
curl -u "user:pass" "https://SERVER/remote.php/dav/files/user/" -k
```

### WebDAV testing (alternative to nextcloudcmd):
```bash
# Upload
curl -k -u "vpn-user:VpnUser1234!NIST" -T /tmp/test.txt \
  "https://FILESHARE_IP/remote.php/dav/files/vpn-user/test.txt"
# List files
curl -k -u "vpn-user:VpnUser1234!NIST" \
  -X PROPFIND "https://FILESHARE_IP/remote.php/dav/files/vpn-user/"
# Download
curl -k -u "vpn-user:VpnUser1234!NIST" \
  "https://FILESHARE_IP/remote.php/dav/files/vpn-user/test.txt" -o /tmp/downloaded.txt
```

### ClamAV Integration:
```bash
occ app:enable files_antivirus
occ config:app:set files_antivirus av_mode --value="daemon"
occ config:app:set files_antivirus av_host --value="127.0.0.1"
occ config:app:set files_antivirus av_port --value="3310"
```

### Performance / Background Jobs:
```bash
# Set background job mode to cron (not AJAX)
occ background:cron
# Add cron job:
echo "*/5 * * * * www-data php -f /var/www/nextcloud/cron.php" >> /etc/cron.d/nextcloud
```

---

## Known Gotchas

### PHP opcache + APCu memory:
- PHP memory_limit must be at least 512M for Nextcloud
- APCu: `apc.enable_cli=1` in php.ini so occ can use it
- opcache.enable=1, opcache.memory_consumption=128

### SSE Encrypt-All timing:
- `occ encryption:encrypt-all` can take a long time on large data sets
- For testing: just verify the command runs successfully with an empty data set

### Nextcloud requires writable data directory:
- `/var/www/nextcloud/data` must be owned by `www-data:www-data`
- NOT inside the webroot in production, but acceptable for this project

### MariaDB character set:
```sql
CREATE DATABASE nextcloud CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
```
- utf8mb4 is required — plain utf8 causes issues with emoji/4-byte chars

### Nextcloud .htaccess not used with Nginx:
- Nginx handles rewrites directly — no Apache mod_rewrite needed
- Use the official Nextcloud nginx config template

### groupfolders admin setup:
```bash
occ app:enable groupfolders
# Create group folder via API or occ (occ groupfolders commands available in app)
```

### File versioning and trash:
- Versioning enabled by default — no extra config needed
- Trash retention: configurable via `occ config:system:set versions_retention_obligation --value="auto"`

### SSM Run Command quoting:
- Use `python3 -c "import json; print(json.dumps({'commands': [script]}))"` to generate Parameters JSON
- For scripts with special chars: base64 encode and decode inline: `echo BASE64 | base64 -d | bash`
- Use single-quoted heredoc `cat << 'EOF'` to avoid shell expansion in scripts

---

## Git Workflow — CRITICAL

**ALWAYS push to GitHub after EVERY commit:**
```bash
git push origin HEAD
```

Work is lost if the EC2 instance terminates before pushing.

---

## Progress Report Format

APPEND to progress.txt (never replace):
```
## [Date/Time] - [Story ID]
- What was implemented
- Files changed
- Validation results

DEPLOYMENT-PROOF:
- terraform apply: SUCCESS (exit 0) OR FAILED (see error below)
- [Resource]: [real ID/ARN]
- Verified: [aws cli or SSM command] → [output confirming live]
- test_requirements results:
  - [requirement 1]: PASS / FAIL

- **Learnings for future iterations:**
  - Patterns discovered
  - Gotchas encountered
---
```

## Stop Condition

After completing a story, check if ALL stories have `passes: true`.
If yes, run the verification pass (confirm resources exist in AWS).
If all verified: `<promise>COMPLETE</promise>`

## Important

- Work on ONE story per iteration
- Commit frequently, PUSH AFTER EVERY COMMIT
- `passes: true` = real deployment verified
- Read Codebase Patterns section in progress.txt before starting
- ALWAYS include DEPLOYMENT-PROOF in progress.txt
- All project files are in `/home/ubuntu/ralph-workspace/fileshare/`
- Terraform directory: `/home/ubuntu/ralph-workspace/fileshare/terraform/`
- GitHub repo: ralph-nist-fileshare (branch: main)
