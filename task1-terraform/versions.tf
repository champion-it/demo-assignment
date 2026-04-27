terraform {
  required_version = ">= 1.5.0"

  required_providers {
    huaweicloud = {
      source  = "huaweicloud/huaweicloud"
      version = "~> 1.64"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Recommended: store state in OBS (Huawei object storage) for team use.
  # backend "s3" {
  #   bucket                      = "tfstate-metabase"
  #   key                         = "metabase/terraform.tfstate"
  #   region                      = "ap-southeast-3"
  #   endpoint                    = "https://obs.ap-southeast-3.myhuaweicloud.com"
  #   skip_region_validation      = true
  #   skip_credentials_validation = true
  # }
}

provider "huaweicloud" {
  region     = var.region
  access_key = var.hw_access_key
  secret_key = var.hw_secret_key
}
