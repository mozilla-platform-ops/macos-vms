packer {
  required_plugins {
    tart = {
      version = ">= 1.12.0"
      source  = "github.com/cirruslabs/tart"
    }
  }
}

variable "vm_name" {
  type    = string
  default = "sequoia-arm64-base"
}

variable "xcode_xip_url" {
  type    = string
  default = "https://ronin-puppet-package-repo.s3.us-west-2.amazonaws.com/macos/public/common/Xcode_16.4.xip"
}

source "tart-cli" "install-xcode" {
  vm_name      = var.vm_name
  cpu_count    = 8
  memory_gb    = 12
  disk_size_gb = 150
  ssh_password = "admin"
  ssh_username = "admin"
  ssh_timeout  = "300s"
}

build {
  name    = "install-xcode"
  sources = ["source.tart-cli.install-xcode"]

  provisioner "shell" {
    inline = [
      "echo 'Downloading Xcode 16.4...'",
      "curl -L -o /tmp/Xcode_16.4.xip '${var.xcode_xip_url}'",

      "echo 'Expanding Xcode XIP (this takes a few minutes)...'",
      "sudo sh -c 'cd /Applications && xip --expand /tmp/Xcode_16.4.xip'",
      "rm /tmp/Xcode_16.4.xip",

      "echo 'Accepting Xcode license...'",
      "sudo xcodebuild -license accept",

      "echo 'Installing Xcode additional components...'",
      "sudo xcodebuild -runFirstLaunch",

      "echo 'Xcode 16.4 installed.'",
    ]
  }
}
