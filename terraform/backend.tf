terraform {
  backend "s3" {
    bucket = "m4-ralph-tfstate-test"
    key    = "projects/nist-fileshare/terraform.tfstate"
    region = "us-east-1"
  }
}
