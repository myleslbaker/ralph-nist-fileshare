# AWS Cost Rules — MANDATORY

## 1. Resource Sizing
- EC2: use `t3.small` for fileshare1 (Nextcloud + MariaDB + PHP)
- EBS: fileshare1 = 60GB gp3 (extra space for user files)
- No RDS — use local MariaDB on the EC2 instance
- NEVER scale up without documenting why

## 2. Forbidden Services (IAM Denied)
- NAT Gateways
- RDS, EKS, SageMaker, ElastiCache, Redshift
- All resources MUST be in us-east-1

## 3. No infracost
- infracost is NOT configured in this project (no API key)
- Apply terraform directly: `terraform apply -auto-approve`
- Skip any scripts that call infracost or estimate-cost.sh

## 4. Tagging Requirements (MANDATORY on every resource)
```hcl
tags = {
  Project     = "nist-fileshare"
  ManagedBy   = "ralph-terraform"
  Environment = "ephemeral"
}
```
Use `default_tags` in the AWS provider block — do NOT remove or override.

## 5. Budget
- Total Budget: $200 for this project
- Expected monthly cost: ~$15-20 (1× t3.small + 60GB EBS + CloudWatch)
- Check AWS Cost Explorer if concerned about spend

## 6. S3 Storage
- Backup bucket: `nist-fileshare-backup-466510536180`
- Use lifecycle rules to transition to Glacier after 30 days
- Enable versioning on the backup bucket

## 7. Cleanup
When project is complete or abandoned: `terraform destroy -auto-approve` in the terraform/ directory
